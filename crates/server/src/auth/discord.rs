use std::{
    collections::HashMap,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use axum::{
    extract::Extension,
    response::{IntoResponse, Redirect, Response},
    Json,
};
use axum_extra::extract::cookie::{Cookie, CookieJar, SameSite};
use rand::{rngs::OsRng, RngCore};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use sqlx::SqlitePool;
use subtle::ConstantTimeEq;
use url::Url;

use crate::error::{AuthError, ServerError};

use super::{AuthState, Claims, User};

const SESSION_DURATION_SECONDS: i64 = 60 * 60 * 24 * 7;
const OAUTH_STATE_DURATION: Duration = Duration::from_secs(300);
const MAX_OAUTH_STATES: usize = 10_000;

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

fn oauth_state_cookie(state: String, secure: bool) -> Cookie<'static> {
    let mut cookie = Cookie::new("discord_oauth_state", state);
    cookie.set_http_only(true);
    cookie.set_path("/auth/discord");
    cookie.set_max_age(time::Duration::seconds(300));
    cookie.set_secure(secure);
    cookie.set_same_site(if secure {
        SameSite::None
    } else {
        SameSite::Lax
    });
    cookie
}

fn remove_oauth_state_cookie(secure: bool) -> Cookie<'static> {
    let mut cookie = oauth_state_cookie(String::new(), secure);
    cookie.set_max_age(time::Duration::ZERO);
    cookie
}

fn state_hash(state: &str) -> [u8; 32] {
    Sha256::digest(state.as_bytes()).into()
}

fn consume_state(auth_state: &AuthState, state: &str) -> bool {
    let now = std::time::Instant::now();
    let mut states = auth_state
        .oauth_states
        .lock()
        .expect("oauth state lock poisoned");
    states.retain(|_, expiry| *expiry > now);
    states.remove(&state_hash(state)).is_some()
}

#[derive(Deserialize)]
pub struct LoginForm {
    code: String,
    state: String,
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

pub async fn start(
    Extension(auth_state): Extension<AuthState>,
    Extension(cookie_secure): Extension<bool>,
    jar: CookieJar,
) -> Result<(CookieJar, Redirect), ServerError> {
    let mut bytes = [0_u8; 32];
    OsRng.fill_bytes(&mut bytes);
    let state = base64_url(&bytes);
    let now = std::time::Instant::now();
    {
        let mut states = auth_state
            .oauth_states
            .lock()
            .expect("oauth state lock poisoned");
        states.retain(|_, expiry| *expiry > now);
        if states.len() >= MAX_OAUTH_STATES {
            return Err(ServerError::InternalError);
        }
        states.insert(state_hash(&state), now + OAUTH_STATE_DURATION);
    }

    let mut url = Url::parse("https://discord.com/api/oauth2/authorize")
        .expect("Discord authorization URL is valid");
    url.query_pairs_mut()
        .append_pair("client_id", &auth_state.discord_client_id)
        .append_pair("redirect_uri", &auth_state.discord_redirect_uri)
        .append_pair("response_type", "code")
        .append_pair("scope", "identify")
        .append_pair("state", &state);
    Ok((
        jar.add(oauth_state_cookie(state, cookie_secure)),
        Redirect::temporary(url.as_str()),
    ))
}

fn base64_url(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut encoded = String::with_capacity(43);
    for chunk in bytes.chunks(3) {
        let value = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        encoded.push(ALPHABET[((value >> 18) & 63) as usize] as char);
        encoded.push(ALPHABET[((value >> 12) & 63) as usize] as char);
        if chunk.len() > 1 {
            encoded.push(ALPHABET[((value >> 6) & 63) as usize] as char);
        }
        if chunk.len() > 2 {
            encoded.push(ALPHABET[(value & 63) as usize] as char);
        }
    }
    encoded
}

async fn get_user(discord_id: &str, pool: &SqlitePool) -> Option<User> {
    sqlx::query_as::<_, User>(
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
    )
    .bind(discord_id)
    .fetch_optional(pool)
    .await
    .map_err(|e| log::warn!("Failed to fetch user: {e:?}"))
    .ok()
    .flatten()
}

pub async fn login(
    Extension(pool): Extension<SqlitePool>,
    Extension(cookie_secure): Extension<bool>,
    Extension(auth_state): Extension<AuthState>,
    jar: CookieJar,
    form: Result<Json<LoginForm>, axum::extract::rejection::JsonRejection>,
) -> Response {
    let result = async {
        let Json(LoginForm { code, state }) = form.map_err(|_| AuthError::InvalidToken)?;
        let cookie_state = jar
            .get("discord_oauth_state")
            .ok_or(AuthError::InvalidToken)?;
        if cookie_state
            .value()
            .as_bytes()
            .ct_eq(state.as_bytes())
            .unwrap_u8()
            != 1
            || !consume_state(&auth_state, &state)
        {
            return Err(AuthError::InvalidToken.into());
        }
        login_after_state(&pool, &auth_state, code, cookie_secure).await
    }
    .await;
    login_response(jar, cookie_secure, result)
}

fn login_response(
    jar: CookieJar,
    cookie_secure: bool,
    result: Result<CookieJar, ServerError>,
) -> Response {
    (
        jar.add(remove_oauth_state_cookie(cookie_secure)),
        result.into_response(),
    )
        .into_response()
}

async fn login_after_state(
    pool: &SqlitePool,
    auth_state: &AuthState,
    code: String,
    cookie_secure: bool,
) -> Result<CookieJar, ServerError> {
    let client = reqwest::Client::new();
    let mut params = HashMap::new();
    params.insert("client_secret", auth_state.discord_client_secret.clone());
    params.insert("client_id", auth_state.discord_client_id.clone());
    params.insert("grant_type", "authorization_code".to_string());
    params.insert("code", code);
    params.insert("redirect_uri", auth_state.discord_redirect_uri.clone());
    let TokenResponse {
        access_token,
        token_type,
    } = client
        .post("https://discord.com/api/oauth2/token")
        .form(&params)
        .send()
        .await
        .map_err(|_| AuthError::InvalidToken)?
        .json()
        .await
        .map_err(|_| ServerError::InternalError)?;
    let discord_user: DiscordUser = client
        .get("https://discord.com/api/users/@me")
        .header("Authorization", format!("{token_type} {access_token}"))
        .send()
        .await
        .map_err(|_| AuthError::InvalidToken)?
        .json()
        .await
        .map_err(|_| ServerError::InternalError)?;
    let user = match get_user(&discord_user.id, pool).await {
        Some(user) => user,
        None => {
            let username: String = discord_user
                .username
                .chars()
                .filter(|c| !c.is_whitespace())
                .collect();
            sqlx::query(
                r#"
                INSERT INTO users (
                    name,
                    username,
                    discord_id
                )
                VALUES (?, ?, ?)
                "#,
            )
            .bind(&username)
            .bind(&username)
            .bind(&discord_user.id)
            .execute(pool)
            .await
            .ok();
            match get_user(&discord_user.id, pool).await {
                Some(user) => user,
                None => {
                    let suffixed_username = format!("{}_{}", username, discord_user.discriminator);
                    sqlx::query(
                        r#"
                        INSERT INTO users (
                            name,
                            username,
                            discord_id
                        )
                        VALUES (?, ?, ?)
                        "#,
                    )
                    .bind(&username)
                    .bind(&suffixed_username)
                    .bind(&discord_user.id)
                    .execute(pool)
                    .await
                    .ok();
                    get_user(&discord_user.id, pool)
                        .await
                        .ok_or(ServerError::InternalError)?
                }
            }
        }
    };
    let issued_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| ServerError::InternalError)?
        .as_secs() as usize;
    let token = auth_state.encode_token(Claims {
        user_id: user.id,
        exp: session_expiration(issued_at),
        auth: user.auth,
    })?;
    Ok(CookieJar::new().add(session_cookie(token, cookie_secure)))
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
    fn logout_cookie_matches_session_scope() {
        let cookie = logout_cookie(true);
        assert_eq!(cookie.path(), Some("/"));
        assert_eq!(cookie.max_age().unwrap().whole_seconds(), 0);
        assert!(cookie.secure().unwrap());
    }

    #[test]
    fn oauth_cookie_attributes() {
        let c = oauth_state_cookie("state".into(), true);
        assert!(c.http_only().unwrap());
        assert_eq!(c.path(), Some("/auth/discord"));
        assert_eq!(c.max_age().unwrap().whole_seconds(), 300);
        assert_eq!(c.same_site(), Some(SameSite::None));
        assert!(c.secure().unwrap());
    }

    #[test]
    fn removal_cookie_matches_state_cookie_scope() {
        for (secure, same_site) in [(true, SameSite::None), (false, SameSite::Lax)] {
            let cookie = remove_oauth_state_cookie(secure);
            assert_eq!(cookie.path(), Some("/auth/discord"));
            assert_eq!(cookie.same_site(), Some(same_site));
            assert_eq!(cookie.secure(), Some(secure));
            assert_eq!(cookie.max_age().unwrap().whole_seconds(), 0);
        }
    }
    #[test]
    fn insecure_oauth_cookie_is_lax() {
        assert_eq!(
            oauth_state_cookie("state".into(), false).same_site(),
            Some(SameSite::Lax)
        );
    }
    #[test]
    fn state_is_consumed_once() {
        let auth = AuthState::new(
            "id".into(),
            "secret".into(),
            "http://localhost/auth/discord".into(),
            "jwt".into(),
        );
        auth.oauth_states.lock().unwrap().insert(
            state_hash("state"),
            std::time::Instant::now() + OAUTH_STATE_DURATION,
        );
        assert!(consume_state(&auth, "state"));
        assert!(!consume_state(&auth, "state"));
    }
    #[test]
    fn expired_state_is_rejected() {
        let auth = AuthState::new(
            "id".into(),
            "secret".into(),
            "http://localhost/auth/discord".into(),
            "jwt".into(),
        );
        auth.oauth_states.lock().unwrap().insert(
            state_hash("state"),
            std::time::Instant::now() - Duration::from_secs(1),
        );
        assert!(!consume_state(&auth, "state"));
    }

    #[tokio::test]
    async fn start_redirect_uses_server_configuration_and_stores_only_a_hash() {
        let auth = AuthState::new(
            "client id".into(),
            "secret".into(),
            "http://localhost/auth/discord".into(),
            "jwt".into(),
        );
        let (jar, redirect) = start(Extension(auth.clone()), Extension(false), CookieJar::new())
            .await
            .unwrap();
        let response = redirect.into_response();
        let url = Url::parse(
            response
                .headers()
                .get("location")
                .unwrap()
                .to_str()
                .unwrap(),
        )
        .unwrap();
        let state = url.query_pairs().find(|(key, _)| key == "state").unwrap().1;
        assert_eq!(
            url.query_pairs()
                .find(|(key, _)| key == "client_id")
                .unwrap()
                .1,
            "client id"
        );
        assert_eq!(state.len(), 43);
        assert_eq!(jar.get("discord_oauth_state").unwrap().value(), state);
        assert!(auth
            .oauth_states
            .lock()
            .unwrap()
            .contains_key(&state_hash(&state)));
    }

    #[tokio::test]
    async fn start_rejects_a_full_state_store() {
        let auth = AuthState::new(
            "id".into(),
            "secret".into(),
            "http://localhost/auth/discord".into(),
            "jwt".into(),
        );
        let expiry = std::time::Instant::now() + OAUTH_STATE_DURATION;
        {
            let mut states = auth.oauth_states.lock().unwrap();
            for index in 0..MAX_OAUTH_STATES {
                let mut hash = [0; 32];
                hash[..8].copy_from_slice(&(index as u64).to_le_bytes());
                states.insert(hash, expiry);
            }
        }

        assert!(matches!(
            start(Extension(auth), Extension(false), CookieJar::new()).await,
            Err(ServerError::InternalError)
        ));
    }

    #[test]
    fn login_response_sets_token_and_removes_oauth_state() {
        let response = login_response(
            CookieJar::new(),
            false,
            Ok(CookieJar::new().add(session_cookie("token-value".into(), false))),
        );
        let cookies: Vec<_> = response
            .headers()
            .get_all("set-cookie")
            .iter()
            .map(|value| value.to_str().unwrap())
            .collect();
        assert!(cookies
            .iter()
            .any(|cookie| cookie.starts_with("token=token-value")));
        assert!(cookies.iter().any(
            |cookie| cookie.starts_with("discord_oauth_state=") && cookie.contains("Max-Age=0")
        ));
    }

    #[test]
    fn login_error_response_removes_oauth_state_without_a_token() {
        let response = login_response(CookieJar::new(), true, Err(AuthError::InvalidToken.into()));
        let cookies: Vec<_> = response
            .headers()
            .get_all("set-cookie")
            .iter()
            .map(|value| value.to_str().unwrap())
            .collect();
        assert!(!cookies.iter().any(|cookie| cookie.starts_with("token=")));
        assert_eq!(cookies.len(), 1);
        assert!(cookies[0].starts_with("discord_oauth_state="));
        assert!(cookies[0].contains("Max-Age=0"));
    }
}
