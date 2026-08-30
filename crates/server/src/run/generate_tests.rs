use axum::{async_trait, Extension, Json};
use reqwest::Client;
use serde_json::Value;
use shared::models::{forms::GenerateTestsJob, runner::RunnerError, test::Test};
use sqlx::SqlitePool;
use tokio::sync::broadcast::{self, Sender};

use crate::{auth::Claims, error::ServerError, ws::BroadcastMessage};

use super::{add_job, JobMap, JobQueue, JobStatus, Queueable};

pub async fn generate_tests(
    claims: Claims,
    Extension(job_queue): Extension<JobQueue>,
    Extension(job_map): Extension<JobMap>,
    Extension(broadcast): Extension<Sender<BroadcastMessage>>,
    Json(queue_item): Json<GenerateTestsJob>,
) -> Result<Json<JobStatus>, ServerError> {
    claims.validate_officer()?;

    let job = add_job(
        claims.user_id,
        job_queue,
        job_map,
        Box::new(queue_item),
        broadcast,
    )
    .await?;

    Ok(Json(job))
}

#[async_trait]
impl Queueable for GenerateTestsJob {
    async fn run(
        &self,
        ramiel_url: &str,
        _pool: &SqlitePool,
        _broadcast: &broadcast::Sender<BroadcastMessage>,
    ) -> Result<Value, ServerError> {
        let client = Client::new();
        let res = client
            .post(format!("{ramiel_url}/generate-tests/c++"))
            .json(self)
            .send()
            .await
            .map_err(|error| {
                log::error!("error fetching generated tests from ramiel: {error}");
                ServerError::InternalError
            })?;

        let tests: Result<Vec<Test>, RunnerError> = res.json().await.map_err(|error| {
            log::error!("error decoding generated tests from ramiel: {error}");
            ServerError::InternalError
        })?;

        serde_json::to_value(tests?).map_err(|error| {
            log::error!("error serializing generated tests: {error}");
            ServerError::InternalError
        })
    }

    fn info(&self) -> String {
        format!("GenerateTestsJob submitted by user {}", self.user_id)
    }

    fn job_type(&self) -> String {
        "GenerateTestsJob".to_string()
    }

    fn problem_id(&self) -> i64 {
        -1
    }
}

#[cfg(test)]
mod tests {
    use axum::{routing::post, Router};
    use sqlx::SqlitePool;
    use tokio::net::TcpListener;

    use super::*;

    #[tokio::test]
    async fn malformed_runner_response_returns_internal_error() {
        let app = Router::new().route(
            "/generate-tests/c++",
            post(|| async { "not valid runner json" }),
        );
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(
            axum::Server::from_tcp(listener.into_std().unwrap())
                .unwrap()
                .serve(app.into_make_service()),
        );

        let job = GenerateTestsJob {
            reference: "".to_string(),
            user_id: 1,
            inputs: vec![],
        };
        let pool = SqlitePool::connect_lazy("sqlite::memory:").unwrap();
        let (broadcast, _) = broadcast::channel(1);

        assert!(matches!(
            job.run(&format!("http://{address}"), &pool, &broadcast)
                .await,
            Err(ServerError::InternalError)
        ));
    }
}
