use std::{
    collections::{HashMap, VecDeque},
    net::{IpAddr, SocketAddr},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use axum::{
    extract::{ConnectInfo, Extension},
    http::{
        header::{CACHE_CONTROL, RETRY_AFTER},
        HeaderMap, HeaderValue, StatusCode,
    },
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
const STATE_CAPACITY: usize = 2_048;
const CLIENT_CAPACITY: usize = 4_096;
const CLIENT_INACTIVITY: Duration = Duration::from_secs(600);
const SCALE: u64 = 30_000;

struct TokenBucket {
    tokens: u64,
    capacity: u64,
    rate_per_second: u64,
    updated_at: std::time::Instant,
    fraction: u128,
}

impl TokenBucket {
    fn new(now: std::time::Instant, capacity: u64, rate_per_second: u64) -> Self {
        Self {
            tokens: capacity,
            capacity,
            rate_per_second,
            updated_at: now,
            fraction: 0,
        }
    }

    fn refill(&mut self, now: std::time::Instant) {
        let elapsed = now
            .checked_duration_since(self.updated_at)
            .unwrap_or_default();
        let total = elapsed.as_nanos() * u128::from(self.rate_per_second) + self.fraction;
        let added = (total / 1_000_000_000) as u64;
        self.fraction = total % 1_000_000_000;
        self.tokens = self.tokens.saturating_add(added).min(self.capacity);
        self.updated_at = self.updated_at.max(now);
        if self.tokens == self.capacity {
            self.fraction = 0;
        }
    }

    fn retry_after(&self) -> Option<u64> {
        (self.tokens < SCALE).then(|| (SCALE - self.tokens).div_ceil(self.rate_per_second))
    }

    fn debit(&mut self) {
        debug_assert!(self.tokens >= SCALE);
        self.tokens -= SCALE;
    }
}

struct ClientBucket {
    bucket: TokenBucket,
    expires_at: std::time::Instant,
}

pub struct OAuthStartGuard {
    last_now: std::time::Instant,
    global: TokenBucket,
    clients: HashMap<IpAddr, ClientBucket>,
    client_expiries: VecDeque<(std::time::Instant, IpAddr)>,
    states: HashMap<[u8; 32], std::time::Instant>,
    state_expiries: VecDeque<(std::time::Instant, [u8; 32])>,
}

impl OAuthStartGuard {
    pub fn new(now: std::time::Instant) -> Self {
        Self {
            last_now: now,
            global: TokenBucket::new(now, 50 * SCALE, 5 * SCALE),
            clients: HashMap::new(),
            client_expiries: VecDeque::new(),
            states: HashMap::new(),
            state_expiries: VecDeque::new(),
        }
    }

    fn monotonic_now(&mut self, now: std::time::Instant) -> std::time::Instant {
        self.last_now = self.last_now.max(now);
        self.last_now
    }

    fn prune(&mut self, now: std::time::Instant) {
        while let Some((expiry, hash)) = self.state_expiries.front().copied() {
            if expiry > now {
                break;
            }
            self.state_expiries.pop_front();
            if self.states.get(&hash) == Some(&expiry) {
                self.states.remove(&hash);
            }
        }
        while let Some((expiry, client)) = self.client_expiries.front().copied() {
            if expiry > now {
                break;
            }
            self.client_expiries.pop_front();
            if self.clients.get(&client).map(|bucket| bucket.expires_at) == Some(expiry) {
                self.clients.remove(&client);
            }
        }
    }

    fn admit(
        &mut self,
        now: std::time::Instant,
        client: IpAddr,
        hash: [u8; 32],
    ) -> Result<(), u64> {
        let now = self.monotonic_now(now);
        self.prune(now);
        self.global.refill(now);
        if let Some(retry_after) = self.global.retry_after() {
            return Err(retry_after);
        }

        let existing_client = self.clients.contains_key(&client);
        if existing_client {
            let bucket = &mut self.clients.get_mut(&client).expect("client exists").bucket;
            bucket.refill(now);
            if let Some(retry_after) = bucket.retry_after() {
                return Err(retry_after);
            }
        }
        if !self.clients.contains_key(&client) && self.clients.len() >= CLIENT_CAPACITY {
            return Err(600);
        }
        if self.states.len() >= STATE_CAPACITY {
            return Err(1);
        }

        self.global.debit();
        let expires_at = now + CLIENT_INACTIVITY;
        if existing_client {
            let bucket = self.clients.get_mut(&client).expect("client exists");
            bucket.bucket.debit();
            bucket.expires_at = expires_at;
        } else {
            let mut bucket = TokenBucket::new(now, 5 * SCALE, SCALE / 30);
            bucket.debit();
            self.clients
                .insert(client, ClientBucket { bucket, expires_at });
        }
        self.client_expiries.push_back((expires_at, client));
        let expiry = now + OAUTH_STATE_DURATION;
        self.states.insert(hash, expiry);
        self.state_expiries.push_back((expiry, hash));
        Ok(())
    }

    fn consume(&mut self, now: std::time::Instant, hash: [u8; 32]) -> bool {
        let now = self.monotonic_now(now);
        self.prune(now);
        self.states.remove(&hash).is_some()
    }
}

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
    let mut guard = auth_state
        .oauth_start_guard
        .lock()
        .expect("oauth state lock poisoned");
    guard.consume(std::time::Instant::now(), state_hash(state))
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
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    jar: CookieJar,
) -> Response {
    let client = match client_ip(peer.ip(), auth_state.trusted_proxy_ip, &headers) {
        Ok(client) => client,
        Err(()) => return StatusCode::BAD_REQUEST.into_response(),
    };
    let mut bytes = [0_u8; 32];
    OsRng.fill_bytes(&mut bytes);
    let state = base64_url(&bytes);
    let mut guard = auth_state
        .oauth_start_guard
        .lock()
        .expect("oauth state lock poisoned");
    let admission = guard.admit(std::time::Instant::now(), client, state_hash(&state));
    drop(guard);
    if let Err(retry_after) = admission {
        return rate_limited(retry_after);
    }

    let mut url = Url::parse("https://discord.com/api/oauth2/authorize")
        .expect("Discord authorization URL is valid");
    url.query_pairs_mut()
        .append_pair("client_id", &auth_state.discord_client_id)
        .append_pair("redirect_uri", &auth_state.discord_redirect_uri)
        .append_pair("response_type", "code")
        .append_pair("scope", "identify")
        .append_pair("state", &state);
    let mut response = (
        jar.add(oauth_state_cookie(state, cookie_secure)),
        Redirect::temporary(url.as_str()),
    )
        .into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response
}

fn rate_limited(retry_after: u64) -> Response {
    let mut response = StatusCode::TOO_MANY_REQUESTS.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response.headers_mut().insert(
        RETRY_AFTER,
        HeaderValue::from_str(&retry_after.to_string()).expect("retry-after is valid"),
    );
    response
}

fn normalize_ip(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(ip) => ip
            .to_ipv4_mapped()
            .map(IpAddr::V4)
            .unwrap_or(IpAddr::V6(ip)),
        IpAddr::V4(ip) => IpAddr::V4(ip),
    }
}

fn client_ip(
    peer: IpAddr,
    trusted_proxy: Option<IpAddr>,
    headers: &HeaderMap,
) -> Result<IpAddr, ()> {
    let peer = normalize_ip(peer);
    if trusted_proxy.map(normalize_ip) != Some(peer) {
        return Ok(peer);
    }
    let mut values = headers.get_all("x-forwarded-for").iter();
    let value = values.next().ok_or(())?;
    if values.next().is_some() {
        return Err(());
    }
    let value = value.to_str().map_err(|_| ())?;
    if value.contains(',') {
        return Err(());
    }
    value.parse().map(normalize_ip).map_err(|_| ())
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
    use axum::{body::Body, http::Request, routing::get, Router};
    use tower::ServiceExt;

    fn client(index: u16) -> IpAddr {
        IpAddr::V4(std::net::Ipv4Addr::new(
            10,
            0,
            (index >> 8) as u8,
            index as u8,
        ))
    }

    fn hash(index: u64) -> [u8; 32] {
        let mut hash = [0; 32];
        hash[..8].copy_from_slice(&index.to_le_bytes());
        hash
    }

    #[test]
    fn global_bucket_has_exact_burst_and_refill() {
        let now = std::time::Instant::now();
        let mut guard = OAuthStartGuard::new(now);
        for index in 0..50 {
            assert!(guard.admit(now, client(index), hash(index.into())).is_ok());
        }
        assert_eq!(guard.admit(now, client(51), hash(51)).unwrap_err(), 1);
        assert!(guard
            .admit(now + Duration::from_millis(200), client(51), hash(52))
            .is_ok());
    }

    #[test]
    fn reversed_timestamps_do_not_regress_buckets_or_expiry_queues() {
        let now = std::time::Instant::now();
        let later = now + Duration::from_secs(10);
        let mut bucket = TokenBucket::new(now, 2 * SCALE, SCALE);
        bucket.debit();
        bucket.refill(later);
        bucket.debit();
        let tokens = bucket.tokens;
        bucket.refill(now);
        assert_eq!(bucket.updated_at, later);
        assert_eq!(bucket.tokens, tokens);

        let mut guard = OAuthStartGuard::new(now);
        assert!(guard.admit(later, client(1), hash(1)).is_ok());
        assert!(guard.admit(now, client(2), hash(2)).is_ok());
        assert!(guard.last_now == later);
        assert!(guard
            .state_expiries
            .iter()
            .zip(guard.state_expiries.iter().skip(1))
            .all(|(first, second)| first.0 <= second.0));
        guard.prune(later + OAUTH_STATE_DURATION);
        assert!(guard.states.is_empty());
    }

    #[test]
    fn per_client_bucket_rejects_without_inserting_and_refills() {
        let now = std::time::Instant::now();
        let mut guard = OAuthStartGuard::new(now);
        for index in 0..5 {
            assert!(guard.admit(now, client(1), hash(index)).is_ok());
        }
        assert_eq!(guard.admit(now, client(1), hash(6)).unwrap_err(), 30);
        assert_eq!(guard.states.len(), 5);
        assert!(guard
            .admit(now + Duration::from_secs(30), client(1), hash(7))
            .is_ok());
    }

    #[test]
    fn per_client_rejection_does_not_debit_global_or_mutate_bookkeeping() {
        let now = std::time::Instant::now();
        let mut guard = OAuthStartGuard::new(now);
        for index in 0..5 {
            guard.admit(now, client(1), hash(index)).unwrap();
        }
        let global_tokens = guard.global.tokens;
        let states = guard.states.len();
        let state_expiries = guard.state_expiries.len();
        let client_expiries = guard.client_expiries.len();
        let expiry = guard.clients[&client(1)].expires_at;
        for index in 5..1_005 {
            assert_eq!(guard.admit(now, client(1), hash(index)).unwrap_err(), 30);
        }
        assert_eq!(guard.global.tokens, global_tokens);
        assert_eq!(guard.states.len(), states);
        assert_eq!(guard.state_expiries.len(), state_expiries);
        assert_eq!(guard.client_expiries.len(), client_expiries);
        assert_eq!(guard.clients[&client(1)].expires_at, expiry);
        assert!(guard.admit(now, client(2), hash(1_005)).is_ok());
    }

    #[test]
    fn global_rejection_does_not_create_client_bookkeeping() {
        let now = std::time::Instant::now();
        let mut guard = OAuthStartGuard::new(now);
        guard.global.tokens = 0;
        for index in 0..10 {
            assert!(guard.admit(now, client(index), hash(index.into())).is_err());
        }
        assert!(guard.clients.is_empty());
        assert!(guard.client_expiries.is_empty());
        assert!(guard.states.is_empty());
        assert!(guard.state_expiries.is_empty());
    }

    #[test]
    fn client_expiry_queue_handles_stale_generations_in_fifo_order() {
        let now = std::time::Instant::now();
        let mut guard = OAuthStartGuard::new(now);
        let a = client(1);
        let b = client(2);
        guard.admit(now, a, hash(1)).unwrap();
        guard
            .admit(now + Duration::from_secs(10), b, hash(2))
            .unwrap();
        guard
            .admit(now + Duration::from_secs(20), a, hash(3))
            .unwrap();
        assert_eq!(guard.client_expiries.len(), 3);
        assert!(guard
            .client_expiries
            .iter()
            .zip(guard.client_expiries.iter().skip(1))
            .all(|(first, second)| first.0 <= second.0));
        guard.prune(now + CLIENT_INACTIVITY);
        assert!(guard.clients.contains_key(&a));
        assert!(guard.clients.contains_key(&b));
        guard.prune(now + CLIENT_INACTIVITY + Duration::from_secs(10));
        assert!(guard.clients.contains_key(&a));
        assert!(!guard.clients.contains_key(&b));
        guard.prune(now + CLIENT_INACTIVITY + Duration::from_secs(20));
        assert!(!guard.clients.contains_key(&a));
    }

    #[test]
    fn different_clients_remain_subject_to_global_limit() {
        let now = std::time::Instant::now();
        let mut guard = OAuthStartGuard::new(now);
        for index in 0..50 {
            assert!(guard.admit(now, client(index), hash(index.into())).is_ok());
        }
        assert!(guard.admit(now, client(100), hash(100)).is_err());
        assert_eq!(guard.states.len(), 50);
    }

    #[test]
    fn expiry_queues_prune_states_and_clients_without_scanning() {
        let now = std::time::Instant::now();
        let mut guard = OAuthStartGuard::new(now);
        assert!(guard.admit(now, client(1), hash(1)).is_ok());
        assert!(!guard.consume(now + OAUTH_STATE_DURATION, hash(1)));
        assert!(guard.states.is_empty());
        assert!(guard
            .admit(now + CLIENT_INACTIVITY, client(2), hash(2))
            .is_ok());
        assert!(!guard.clients.contains_key(&client(1)));
    }

    #[test]
    fn state_count_stays_below_capacity_over_five_minutes() {
        let now = std::time::Instant::now();
        let mut guard = OAuthStartGuard::new(now);
        let mut index = 0_u64;
        for second in 0..300 {
            let at = now + Duration::from_secs(second);
            for _ in 0..5 {
                assert!(guard
                    .admit(
                        at,
                        IpAddr::V6(std::net::Ipv6Addr::from(index as u128)),
                        hash(index)
                    )
                    .is_ok());
                index += 1;
            }
            assert!(guard.states.len() < STATE_CAPACITY);
        }
    }

    #[test]
    fn trusted_proxy_rules_and_ip_normalization_are_strict() {
        let trusted: IpAddr = "192.0.2.1".parse().unwrap();
        let peer: IpAddr = "192.0.2.2".parse().unwrap();
        let mut headers = HeaderMap::new();
        headers.insert("x-forwarded-for", "203.0.113.1".parse().unwrap());
        assert_eq!(client_ip(peer, Some(trusted), &headers).unwrap(), peer);
        assert_eq!(
            client_ip(trusted, Some(trusted), &headers).unwrap(),
            "203.0.113.1".parse::<IpAddr>().unwrap()
        );
        headers.append("x-forwarded-for", "203.0.113.2".parse().unwrap());
        assert!(client_ip(trusted, Some(trusted), &headers).is_err());
        let mut comma = HeaderMap::new();
        comma.insert(
            "x-forwarded-for",
            "203.0.113.1, 203.0.113.2".parse().unwrap(),
        );
        assert!(client_ip(trusted, Some(trusted), &comma).is_err());
        let mut malformed = HeaderMap::new();
        malformed.insert("x-forwarded-for", "not-an-ip".parse().unwrap());
        assert!(client_ip(trusted, Some(trusted), &malformed).is_err());
        assert_eq!(normalize_ip("::ffff:192.0.2.1".parse().unwrap()), trusted);
    }

    #[test]
    fn rate_limit_response_has_no_cookie_and_no_store_headers() {
        let response = rate_limited(7);
        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(response.headers()[CACHE_CONTROL], "no-store");
        assert_eq!(response.headers()[RETRY_AFTER], "7");
        assert!(response
            .headers()
            .get_all("set-cookie")
            .iter()
            .next()
            .is_none());
    }

    #[test]
    fn concurrent_starts_are_atomically_limited() {
        let now = std::time::Instant::now();
        let guard = std::sync::Arc::new(std::sync::Mutex::new(OAuthStartGuard::new(now)));
        let mut workers = Vec::new();
        for index in 0..100_u16 {
            let guard = guard.clone();
            workers.push(std::thread::spawn(move || {
                guard
                    .lock()
                    .unwrap()
                    .admit(now, client(index), hash(index.into()))
                    .is_ok()
            }));
        }
        assert_eq!(
            workers
                .into_iter()
                .filter_map(|worker| worker.join().ok())
                .filter(|allowed| *allowed)
                .count(),
            50
        );
    }

    fn start_router(auth: AuthState) -> Router {
        Router::new()
            .route("/auth/discord/start", get(start))
            .layer(Extension(false))
            .layer(Extension(auth))
    }

    #[tokio::test]
    async fn start_endpoint_rate_limit_has_complete_contract() {
        let auth = AuthState::new(
            "id".into(),
            "secret".into(),
            "http://localhost/auth/discord".into(),
            "jwt".into(),
            None,
        );
        {
            let mut guard = auth.oauth_start_guard.lock().unwrap();
            guard.global.tokens = 0;
            guard.global.updated_at = std::time::Instant::now();
            guard.last_now = guard.global.updated_at;
        }
        let mut request = Request::builder()
            .uri("/auth/discord/start")
            .body(Body::empty())
            .unwrap();
        request
            .extensions_mut()
            .insert(ConnectInfo("127.0.0.1:4000".parse::<SocketAddr>().unwrap()));
        let response = start_router(auth).oneshot(request).await.unwrap();
        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        assert!(response.headers()[RETRY_AFTER]
            .to_str()
            .unwrap()
            .parse::<u64>()
            .is_ok());
        assert_eq!(response.headers()[CACHE_CONTROL], "no-store");
        assert!(response
            .headers()
            .get_all("set-cookie")
            .iter()
            .next()
            .is_none());
        assert!(response.headers().get("location").is_none());
    }

    #[tokio::test]
    async fn trusted_proxy_header_failures_are_rejected_by_the_endpoint() {
        let auth = AuthState::new(
            "id".into(),
            "secret".into(),
            "http://localhost/auth/discord".into(),
            "jwt".into(),
            Some("192.0.2.1".parse().unwrap()),
        );
        for headers in [vec!["not-an-ip"], vec!["203.0.113.1", "203.0.113.2"]] {
            let mut builder = Request::builder().uri("/auth/discord/start");
            for header in headers {
                builder = builder.header("x-forwarded-for", header);
            }
            let mut request = builder.body(Body::empty()).unwrap();
            request
                .extensions_mut()
                .insert(ConnectInfo("192.0.2.1:4000".parse::<SocketAddr>().unwrap()));
            let response = start_router(auth.clone()).oneshot(request).await.unwrap();
            assert_eq!(response.status(), StatusCode::BAD_REQUEST);
            assert!(response
                .headers()
                .get_all("set-cookie")
                .iter()
                .next()
                .is_none());
            assert!(response.headers().get("location").is_none());
        }
    }

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
            None,
        );
        let now = std::time::Instant::now();
        let expiry = now + OAUTH_STATE_DURATION;
        let hash = state_hash("state");
        let mut guard = auth.oauth_start_guard.lock().unwrap();
        guard.states.insert(hash, expiry);
        guard.state_expiries.push_back((expiry, hash));
        drop(guard);
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
            None,
        );
        let expiry = std::time::Instant::now() - Duration::from_secs(1);
        let hash = state_hash("state");
        let mut guard = auth.oauth_start_guard.lock().unwrap();
        guard.states.insert(hash, expiry);
        guard.state_expiries.push_back((expiry, hash));
        drop(guard);
        assert!(!consume_state(&auth, "state"));
    }

    #[tokio::test]
    async fn start_redirect_uses_server_configuration_and_stores_only_a_hash() {
        let auth = AuthState::new(
            "client id".into(),
            "secret".into(),
            "http://localhost/auth/discord".into(),
            "jwt".into(),
            None,
        );
        let response = start(
            Extension(auth.clone()),
            Extension(false),
            ConnectInfo("127.0.0.1:4000".parse().unwrap()),
            HeaderMap::new(),
            CookieJar::new(),
        )
        .await;
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
        assert!(auth
            .oauth_start_guard
            .lock()
            .unwrap()
            .states
            .contains_key(&state_hash(&state)));
    }

    #[tokio::test]
    async fn start_rejects_a_full_state_store() {
        let auth = AuthState::new(
            "id".into(),
            "secret".into(),
            "http://localhost/auth/discord".into(),
            "jwt".into(),
            None,
        );
        let expiry = std::time::Instant::now() + OAUTH_STATE_DURATION;
        {
            let mut guard = auth.oauth_start_guard.lock().unwrap();
            for index in 0..STATE_CAPACITY {
                let mut hash = [0; 32];
                hash[..8].copy_from_slice(&(index as u64).to_le_bytes());
                guard.states.insert(hash, expiry);
                guard.state_expiries.push_back((expiry, hash));
            }
        }

        let response = start(
            Extension(auth),
            Extension(false),
            ConnectInfo("127.0.0.1:4000".parse().unwrap()),
            HeaderMap::new(),
            CookieJar::new(),
        )
        .await;
        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(response.headers()[CACHE_CONTROL], "no-store");
        assert!(response
            .headers()
            .get_all("set-cookie")
            .iter()
            .next()
            .is_none());
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
