use std::{
    collections::HashMap,
    env,
    time::{SystemTime, UNIX_EPOCH},
};

use axum::{Extension, Json};
use axum_extra::extract::cookie::{Cookie, CookieJar, SameSite};
use serde::Deserialize;
use sqlx::SqlitePool;

use crate::error::{AuthError, ServerError};

use super::{Auth, Claims, User, KEYS};

const SESSION_DURATION_SECONDS: i64 = 60 * 60 * 24 * 7;

fn session_expiration(issued_at: usize) -> usize {
    issued_at + SESSION_DURATION_SECONDS as usize
}

fn session_cookie(token: String, secure: bool) -> Cookie<'static> {
    let mut cookie = Cookie::parse(format!("token={token}; Max-Age={SESSION_DURATION_SECONDS}"))
        .expect("JWT is a valid cookie value");
    cookie.set_http_only(true);
    cookie.set_same_site(SameSite::Lax);
    cookie.set_path("/");
    cookie.set_secure(secure);
    cookie
}

fn logout_cookie(secure: bool) -> Cookie<'static> {
    let mut cookie = Cookie::parse("token=; Max-Age=0").expect("static cookie is valid");
    cookie.set_http_only(true);
    cookie.set_same_site(SameSite::Lax);
    cookie.set_path("/");
    cookie.set_secure(secure);
    cookie
}

#[derive(Deserialize)]
pub struct LoginForm {
    code: String,
    redirect_uri: String,
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    token_type: String,
}

#[derive(Deserialize)]
struct DiscordUser {
    username: String,
    discriminator: String,
    id: String,
}

async fn get_user(discord_id: &str, pool: &SqlitePool) -> Option<User> {
    let user = sqlx::query_as!(
        User,
        r#"
        SELECT
            id,
            name,
            username,
            discord_id,
            auth as "auth: Auth"
        FROM
            users
        WHERE discord_id = ?
        "#,
        discord_id
    )
    .fetch_optional(pool)
    .await
    .map_err(|e| {
        log::warn!("Failed to fetch user: {e:?}");
    })
    .ok()
    .flatten();

    user
}

pub async fn login(
    Extension(pool): Extension<SqlitePool>,
    Extension(cookie_secure): Extension<bool>,
    jar: CookieJar,
    Json(LoginForm { code, redirect_uri }): Json<LoginForm>,
) -> Result<CookieJar, ServerError> {
    let client = reqwest::Client::new();

    let mut params = HashMap::new();
    params.insert("client_secret", env::var("DISCORD_SECRET").unwrap());
    params.insert("client_id", "984742374112624690".to_string());
    params.insert("grant_type", "authorization_code".to_string());
    params.insert("code", code);
    params.insert("redirect_uri", redirect_uri);

    let TokenResponse {
        access_token,
        token_type,
    } = client
        .post("https://discord.com/api/oauth2/token")
        .form(&params)
        .send()
        .await
        .map_err(|e| {
            log::error!("{}", e);
            AuthError::InvalidToken
        })?
        .json()
        .await
        .map_err(|e| {
            log::error!("{}", e);
            ServerError::InternalError
        })?;

    let discord_user: DiscordUser = client
        .get("https://discord.com/api/users/@me")
        .header("Authorization", format!("{token_type} {access_token}"))
        .send()
        .await
        .map_err(|e| {
            log::error!("{e}");
            AuthError::InvalidToken
        })?
        .json()
        .await
        .map_err(|_| ServerError::InternalError)?;

    let user = get_user(&discord_user.id, &pool).await;

    let user = match user {
        Some(user) => user,
        // If the user does not exist
        None => {
            let sanitized_username: String = discord_user
                .username
                .chars()
                .filter(|c| !c.is_whitespace())
                .collect();

            // Try with base username, if that fails, include the descriminator.
            sqlx::query!(
                r#"
                INSERT INTO users (
                    name,
                    username,
                    discord_id
                )
                VALUES (?, ?, ?)
                "#,
                sanitized_username,
                sanitized_username,
                discord_user.id
            )
            .execute(&pool)
            .await
            .ok();

            let user = get_user(&discord_user.id, &pool).await;

            match user {
                Some(user) => user,
                None => {
                    let username = format!("{}_{}", sanitized_username, discord_user.discriminator);

                    log::info!("selected username: {username:?}");

                    sqlx::query!(
                        r#"
                        INSERT INTO users (
                            name,
                            username,
                            discord_id
                        )
                        VALUES (?, ?, ?)
                        "#,
                        sanitized_username,
                        username,
                        discord_user.id
                    )
                    .execute(&pool)
                    .await
                    .ok();

                    let user = get_user(&discord_user.id, &pool).await;

                    user.unwrap()
                }
            }
        }
    };

    let issued_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| ServerError::InternalError)?
        .as_secs() as usize;
    let claims = Claims {
        user_id: user.id,
        exp: session_expiration(issued_at),
        auth: user.auth,
    };

    let token = KEYS.encode_token(claims)?;

    Ok(jar.add(session_cookie(token, cookie_secure)))
}

pub async fn logout(Extension(cookie_secure): Extension<bool>, jar: CookieJar) -> CookieJar {
    jar.remove(logout_cookie(cookie_secure))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_expiration_is_seven_days_after_issue_time() {
        assert_eq!(session_expiration(1_000), 605_800);
    }

    #[test]
    fn secure_session_cookie_has_required_attributes() {
        let cookie = session_cookie("token-value".to_string(), true);

        assert!(cookie.http_only().unwrap());
        assert_eq!(cookie.same_site(), Some(SameSite::Lax));
        assert_eq!(cookie.path(), Some("/"));
        assert_eq!(cookie.max_age().unwrap().whole_seconds(), 604_800);
        assert!(cookie.secure().unwrap());
    }

    #[test]
    fn insecure_session_cookie_omits_secure_attribute() {
        let cookie = session_cookie("token-value".to_string(), false);

        assert_eq!(cookie.secure(), Some(false));
        assert!(!cookie.to_string().contains("Secure"));
    }

    #[test]
    fn logout_cookie_matches_session_scope() {
        let cookie = logout_cookie(true);

        assert_eq!(cookie.path(), Some("/"));
        assert_eq!(cookie.same_site(), Some(SameSite::Lax));
        assert_eq!(cookie.max_age().unwrap().whole_seconds(), 0);
        assert!(cookie.secure().unwrap());
    }
}
