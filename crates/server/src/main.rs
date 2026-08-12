use std::{
    collections::HashMap,
    net::SocketAddr,
    process::exit,
    sync::{atomic::AtomicU64, Arc},
    time::Duration,
};
use tokio::sync::{broadcast, mpsc, RwLock};

use axum::{
    http::{self, header::CONTENT_TYPE, HeaderValue, Method},
    routing::get,
    Extension, Router, Server,
};
use clap::Parser;
use sqlx::SqlitePool;
use tower_http::cors::{AllowOrigin, CorsLayer};

use crate::{
    problems::{Difficulty, Problem},
    run::{job_worker, JobQueueItem, JobStatus},
    ws::BroadcastMessage,
};

mod auth;
mod competitions;
mod error;
mod leaderboard;
mod meetings;
mod pagination;
mod problems;
mod run;
mod submissions;
mod user;
mod ws;

pub const MAX_TEST_LENGTH: usize = 500;

pub static JOB_COUNTER: AtomicU64 = AtomicU64::new(0);
pub static PROCESSING_JOB: AtomicU64 = AtomicU64::new(0);

async fn healthz() {}

fn frontend_origin(value: &str) -> Result<HeaderValue, String> {
    let origin = value
        .parse::<HeaderValue>()
        .map_err(|_| "FRONTEND_ORIGIN must be a valid HTTP origin".to_string())?;
    let uri = value
        .parse::<http::Uri>()
        .map_err(|_| "FRONTEND_ORIGIN must be a valid HTTP origin".to_string())?;

    if !matches!(uri.scheme_str(), Some("http" | "https"))
        || uri.authority().is_none()
        || uri.path() != "/"
        || uri.query().is_some()
    {
        return Err(
            "FRONTEND_ORIGIN must be an http(s) origin without a path or query".to_string(),
        );
    }

    Ok(origin)
}

fn cors_layer(frontend_origin: HeaderValue) -> CorsLayer {
    CorsLayer::new()
        .allow_origin(AllowOrigin::exact(frontend_origin))
        .allow_credentials(true)
        .allow_methods([
            Method::GET,
            Method::POST,
            Method::PUT,
            Method::PATCH,
            Method::DELETE,
            Method::OPTIONS,
        ])
        .allow_headers([CONTENT_TYPE])
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::Body,
        http::{Request, StatusCode},
    };
    use tower::ServiceExt;

    #[test]
    fn accepts_http_or_https_frontend_origins() {
        assert_eq!(
            frontend_origin("http://127.0.0.1:3000").unwrap(),
            "http://127.0.0.1:3000"
        );
        assert_eq!(
            frontend_origin("https://acm.example.com").unwrap(),
            "https://acm.example.com"
        );
    }

    #[test]
    fn rejects_non_origin_frontend_values() {
        assert!(frontend_origin("not an origin").is_err());
        assert!(frontend_origin("https://acm.example.com/path").is_err());
        assert!(frontend_origin("ftp://acm.example.com").is_err());
    }

    #[tokio::test]
    async fn cors_allows_only_the_configured_origin() {
        let app = Router::new()
            .route("/", get(|| async { StatusCode::NO_CONTENT }))
            .layer(cors_layer(
                frontend_origin("https://acm.example.com").unwrap(),
            ));

        let accepted = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::OPTIONS)
                    .uri("/")
                    .header("Origin", "https://acm.example.com")
                    .header("Access-Control-Request-Method", "POST")
                    .header("Access-Control-Request-Headers", "content-type")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(accepted.status(), StatusCode::OK);
        assert_eq!(
            accepted
                .headers()
                .get("access-control-allow-origin")
                .unwrap(),
            "https://acm.example.com"
        );

        let rejected = app
            .oneshot(
                Request::builder()
                    .method(Method::OPTIONS)
                    .uri("/")
                    .header("Origin", "https://untrusted.example.com")
                    .header("Access-Control-Request-Method", "POST")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_ne!(
            rejected
                .headers()
                .get("access-control-allow-origin")
                .unwrap(),
            "https://untrusted.example.com"
        );
    }
}

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Args {
    #[arg(short, env, long, default_value_t = 8081)]
    port: u16,

    #[arg(long, env, default_value = "127.0.0.1")]
    hostname: String,

    #[arg(long, env, default_value = "./db.sqlite")]
    database_url: String,

    #[arg(long, env, default_value = "http://127.0.0.1:8082")]
    ramiel_url: String,

    #[arg(long, env, default_value = "1")]
    parallel_job_count: u8,

    #[arg(env)]
    jwt_secret: String,

    #[arg(env)]
    discord_secret: String,

    #[arg(env)]
    frontend_origin: String,

    #[arg(env, value_parser = clap::value_parser!(bool))]
    cookie_secure: bool,
}

#[tokio::main]
async fn main() {
    let args = Args::parse();
    let frontend_origin = frontend_origin(&args.frontend_origin).unwrap_or_else(|error| {
        eprintln!("Invalid FRONTEND_ORIGIN: {error}");
        exit(2);
    });

    tracing_subscriber::fmt()
        .with_env_filter("info,tower_http=debug,sqlx=warn")
        .init();

    // A broadcast channel to update new submissions in real time.
    let (broadcast, _) = broadcast::channel::<BroadcastMessage>(16);

    // A multi-producer, single-consumer channel for long-running jobs
    let (job_queue, rx) = mpsc::unbounded_channel::<(u64, JobQueueItem)>();

    let queued_jobs = Arc::new(RwLock::new(HashMap::<u64, JobStatus>::new()));

    tracing::info!("Connecting to database at \"{}\"", args.database_url);
    let pool = match SqlitePool::connect(&args.database_url).await {
        Ok(conn) => conn,
        Err(e) => {
            tracing::error!("error {e}");
            exit(1);
        }
    };

    if let Err(e) = sqlx::migrate!("../../migrations").run(&pool).await {
        log::error!("Migration error: {e:?}");
        exit(1);
    }

    // Spawn job queue thread
    {
        log::info!("Spawning worker thread");

        let ramiel_url = args.ramiel_url.clone();
        let queued_jobs = queued_jobs.clone();
        let broadcast = broadcast.clone();
        let pool = pool.clone();
        tokio::spawn(async move {
            job_worker(
                rx,
                queued_jobs,
                ramiel_url,
                pool,
                broadcast,
                args.parallel_job_count,
            )
            .await;
        });
    }

    // Spawn problem publish notification thread
    {
        let pool = pool.clone();
        let broadcast = broadcast.clone();
        tokio::spawn(async move {
            loop {
                // log::info!("Checking for problems to be made visible");

                let rows = sqlx::query_as!(
                    Problem,
                    r#"
                    SELECT
                        id,
                        title,
                        description,
                        runner,
                        template,
                        runtime_multiplier,
                        competition_id,
                        visible,
                        difficulty as "difficulty: Difficulty"
                    FROM
                        problems
                    WHERE
                        visible = false AND publish_time < datetime('now')
                "#
                )
                .fetch_all(&pool)
                .await
                .unwrap();

                for problem in rows {
                    sqlx::query!(
                        r#"
                    UPDATE
                        problems
                    SET
                        visible = true
                    WHERE
                        id = ?
                    "#,
                        problem.id
                    )
                    .execute(&pool)
                    .await
                    .unwrap();

                    broadcast.send(BroadcastMessage::NewProblem(problem)).ok();
                }

                tokio::time::sleep(Duration::new(30, 0)).await;
            }
        });
    }

    let addr = SocketAddr::new(args.hostname.parse().unwrap(), args.port);
    tracing::info!("Started server on {addr}");

    let app = Router::new()
        .route("/healthz", get(healthz))
        .nest("/auth", auth::routes())
        .nest("/competitions", competitions::routes())
        .nest("/leaderboard", leaderboard::routes())
        .nest("/meetings", meetings::routes())
        .nest("/problems", problems::routes())
        .nest("/run", run::routes())
        .nest("/submissions", submissions::routes())
        .nest("/user", user::routes())
        .route("/ws", get(ws::handler))
        .layer(Extension(args.ramiel_url))
        .layer(Extension(queued_jobs))
        .layer(Extension(pool))
        .layer(Extension(broadcast))
        .layer(Extension(job_queue))
        .layer(Extension(args.cookie_secure))
        .layer(cors_layer(frontend_origin));

    Server::bind(&addr)
        .serve(app.into_make_service())
        .await
        .unwrap();
}
