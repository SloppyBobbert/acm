use std::{
    collections::HashMap,
    sync::{atomic::Ordering, Arc},
};

use axum::{
    async_trait,
    extract::Path,
    routing::{get, post},
    Extension, Json, Router,
};
use futures::{future::BoxFuture, stream::FuturesUnordered, StreamExt};

use serde::Serialize;
use serde_json::Value;
use shared::models::runner::RunnerError;
use sqlx::SqlitePool;
use tokio::{
    sync::{
        broadcast::{self, Sender},
        mpsc, RwLock,
    },
    task::JoinError,
    time::{sleep, Duration},
};

use crate::{
    auth::Claims,
    error::{AuthError, ServerError},
    ws::BroadcastMessage,
    JOB_COUNTER, PROCESSING_JOB,
};

mod custom;
mod generate_tests;
mod submit;

pub type JobQueueItem = Box<dyn Queueable>;
pub type JobQueue = mpsc::UnboundedSender<(u64, JobQueueItem)>;
pub type JobMap = Arc<RwLock<HashMap<u64, JobStatus>>>;

#[derive(Serialize, Debug, Clone)]
pub struct JobStatus {
    id: u64,

    user_id: i64,

    queue_position: u64,
    job_type: String,
    problem_id: i64,

    response: Option<Value>,
    error: Option<String>,
}

#[async_trait]
pub trait Queueable: Send + Sync {
    // Executes the job
    async fn run(
        &self,
        ramiel_url: &str,
        pool: &SqlitePool,
        broadcast: &broadcast::Sender<BroadcastMessage>,
    ) -> Result<Value, ServerError>;

    // Returns some basic info about the job -- for logging purposes only
    fn info(&self) -> String;
    fn job_type(&self) -> String;
    fn problem_id(&self) -> i64;
}

// Adds a job to the job queue
async fn add_job(
    user_id: i64,
    job_queue: JobQueue,
    job_map: JobMap,
    queue_item: JobQueueItem,
    broadcast: Sender<BroadcastMessage>,
) -> Result<JobStatus, ServerError> {
    let job_id = JOB_COUNTER.fetch_add(1, Ordering::SeqCst);

    log::info!("Adding job {job_id}: {}", queue_item.info());

    let job_status = JobStatus {
        id: job_id,
        user_id,

        queue_position: job_id - PROCESSING_JOB.load(Ordering::SeqCst),
        job_type: queue_item.job_type(),
        problem_id: queue_item.problem_id(),
        response: None,
        error: None,
    };

    broadcast
        .send(BroadcastMessage::NewJob(job_status.clone()))
        .ok();

    job_map.write().await.insert(job_id, job_status.clone());

    job_queue
        .send((job_id, queue_item))
        .map_err(|_| ServerError::InternalError)?;

    Ok(job_status)
}

pub async fn check_job(
    Path(id): Path<u64>,
    Extension(job_map): Extension<JobMap>,
    claims: Claims,
) -> Result<Json<JobStatus>, ServerError> {
    claims.validate_logged_in()?;

    if let Some(job) = job_map.read().await.get(&id) {
        if job.user_id == claims.user_id {
            let processing_job = PROCESSING_JOB.load(Ordering::SeqCst);
            let mut job = job.clone();
            if job.id >= processing_job {
                job.queue_position = job.id - processing_job;
            }
            Ok(Json(job))
        } else {
            Err(AuthError::Unauthorized.into())
        }
    } else {
        Err(ServerError::NotFound)
    }
}

async fn process_job(
    id: u64,
    queue_item: JobQueueItem,
    queued_jobs: JobMap,
    ramiel_url: String,
    pool: SqlitePool,
    broadcast: broadcast::Sender<BroadcastMessage>,
) {
    PROCESSING_JOB.store(id, Ordering::SeqCst);

    log::info!("Processing job {id}: {}", queue_item.info());

    let res = queue_item.run(&ramiel_url, &pool, &broadcast).await;

    finish_job(id, res, queued_jobs, broadcast).await;
}

async fn finish_job(
    id: u64,
    res: Result<Value, ServerError>,
    queued_jobs: JobMap,
    broadcast: broadcast::Sender<BroadcastMessage>,
) {
    let mut job_map_writer = queued_jobs.write().await;
    let Some(job) = job_map_writer.get_mut(&id) else {
        log::warn!("Job {id} disappeared from job map before it finished");
        return;
    };

    log::info!("{res:?}");

    match res {
        Ok(res) => {
            job.response = Some(res);
        }
        Err(ServerError::Runner(RunnerError::CompilationError { diagnostics })) => {
            job.error = Some(match serde_json::to_string(&diagnostics) {
                Ok(diagnostics) => diagnostics,
                Err(error) => {
                    log::error!("error serializing compiler diagnostics for job {id}: {error}");
                    ServerError::InternalError.to_string()
                }
            })
        }
        Err(e) => job.error = Some(e.to_string()),
    }

    let job = job.clone();
    drop(job_map_writer);

    broadcast.send(BroadcastMessage::FinishedJob(job)).ok();

    // Set timeout to remove the job from the job map to prevent it from growing out of control
    tokio::spawn(async move {
        sleep(Duration::from_secs(10)).await;

        queued_jobs.write().await.remove(&id);
        log::info!("Job {id} purged from job map");
    });
}

type TaskCompletion = (u64, Result<(), JoinError>);

fn start_task(
    id: u64,
    queue_item: JobQueueItem,
    queued_jobs: JobMap,
    ramiel_url: String,
    pool: SqlitePool,
    broadcast: broadcast::Sender<BroadcastMessage>,
) -> BoxFuture<'static, TaskCompletion> {
    let task = tokio::spawn(async move {
        process_job(id, queue_item, queued_jobs, ramiel_url, pool, broadcast).await;
    });

    Box::pin(async move { (id, task.await) })
}

async fn observe_task(
    (id, result): TaskCompletion,
    queued_jobs: JobMap,
    broadcast: broadcast::Sender<BroadcastMessage>,
) {
    if let Err(error) = result {
        log::error!("job task {id} failed: {error}");
        finish_job(id, Err(ServerError::InternalError), queued_jobs, broadcast).await;
    }
}

pub async fn job_worker(
    mut rx: mpsc::UnboundedReceiver<(u64, JobQueueItem)>,
    queued_jobs: JobMap,
    ramiel_url: String,
    pool: SqlitePool,
    broadcast: broadcast::Sender<BroadcastMessage>,
    parallel_job_count: u8,
) {
    log::info!("Started job worker");

    let max_parallel_jobs = usize::from(parallel_job_count.max(1));
    let mut tasks = FuturesUnordered::new();
    let mut receiver_open = true;

    while receiver_open || !tasks.is_empty() {
        if !receiver_open || tasks.len() >= max_parallel_jobs {
            if let Some(completion) = tasks.next().await {
                observe_task(completion, queued_jobs.clone(), broadcast.clone()).await;
            }
            continue;
        }

        if tasks.is_empty() {
            match rx.recv().await {
                Some((id, queue_item)) => tasks.push(start_task(
                    id,
                    queue_item,
                    queued_jobs.clone(),
                    ramiel_url.clone(),
                    pool.clone(),
                    broadcast.clone(),
                )),
                None => receiver_open = false,
            }
        } else {
            tokio::select! {
                Some(completion) = tasks.next() => {
                    observe_task(completion, queued_jobs.clone(), broadcast.clone()).await;
                }
                job = rx.recv() => match job {
                    Some((id, queue_item)) => tasks.push(start_task(
                        id,
                        queue_item,
                        queued_jobs.clone(),
                        ramiel_url.clone(),
                        pool.clone(),
                        broadcast.clone(),
                    )),
                    None => receiver_open = false,
                },
            }
        }
    }
}

pub fn routes() -> Router {
    Router::new()
        .route("/custom", post(custom::custom))
        .route("/generate-tests", post(generate_tests::generate_tests))
        .route("/submit", post(submit::submit))
        .route("/check/:id", get(check_job))
}

#[cfg(test)]
mod tests {
    use serde_json::json;
    use tokio::{sync::Notify, time::timeout};

    use super::*;

    struct PanickingJob;

    #[async_trait]
    impl Queueable for PanickingJob {
        async fn run(
            &self,
            _ramiel_url: &str,
            _pool: &SqlitePool,
            _broadcast: &broadcast::Sender<BroadcastMessage>,
        ) -> Result<Value, ServerError> {
            panic!("simulated worker failure");
        }

        fn info(&self) -> String {
            "panicking test job".to_string()
        }

        fn job_type(&self) -> String {
            "test".to_string()
        }

        fn problem_id(&self) -> i64 {
            -1
        }
    }

    struct SucceedingJob;

    #[async_trait]
    impl Queueable for SucceedingJob {
        async fn run(
            &self,
            _ramiel_url: &str,
            _pool: &SqlitePool,
            _broadcast: &broadcast::Sender<BroadcastMessage>,
        ) -> Result<Value, ServerError> {
            Ok(json!("completed"))
        }

        fn info(&self) -> String {
            "succeeding test job".to_string()
        }

        fn job_type(&self) -> String {
            "test".to_string()
        }

        fn problem_id(&self) -> i64 {
            -1
        }
    }

    struct BlockingJob {
        started: Arc<Notify>,
        release: Arc<Notify>,
    }

    #[async_trait]
    impl Queueable for BlockingJob {
        async fn run(
            &self,
            _ramiel_url: &str,
            _pool: &SqlitePool,
            _broadcast: &broadcast::Sender<BroadcastMessage>,
        ) -> Result<Value, ServerError> {
            self.started.notify_one();
            self.release.notified().await;
            Ok(json!("completed"))
        }

        fn info(&self) -> String {
            "blocking test job".to_string()
        }

        fn job_type(&self) -> String {
            "test".to_string()
        }

        fn problem_id(&self) -> i64 {
            -1
        }
    }

    #[tokio::test]
    async fn worker_observes_panicked_job_while_receiver_stays_open() {
        let (tx, rx) = mpsc::unbounded_channel();
        let queued_jobs = Arc::new(RwLock::new(HashMap::new()));
        queued_jobs.write().await.insert(
            1,
            JobStatus {
                id: 1,
                user_id: 1,
                queue_position: 0,
                job_type: "test".to_string(),
                problem_id: -1,
                response: None,
                error: None,
            },
        );
        let (broadcast, mut messages) = broadcast::channel(1);
        let pool = SqlitePool::connect_lazy("sqlite::memory:").unwrap();
        let worker = tokio::spawn(job_worker(
            rx,
            queued_jobs.clone(),
            "http://127.0.0.1:1".to_string(),
            pool,
            broadcast,
            1,
        ));

        tx.send((1, Box::new(PanickingJob) as JobQueueItem))
            .unwrap();

        assert!(matches!(
            timeout(Duration::from_secs(1), messages.recv())
                .await
                .unwrap()
                .unwrap(),
            BroadcastMessage::FinishedJob(status) if status.id == 1
        ));
        let job = queued_jobs.read().await.get(&1).cloned().unwrap();
        assert_eq!(job.error.as_deref(), Some("Internal server error."));

        worker.abort();
        let _ = worker.await;
        drop(tx);
    }

    #[tokio::test]
    async fn panicked_job_records_failure_and_worker_continues() {
        let (tx, rx) = mpsc::unbounded_channel();
        let queued_jobs = Arc::new(RwLock::new(HashMap::new()));
        queued_jobs.write().await.insert(
            1,
            JobStatus {
                id: 1,
                user_id: 1,
                queue_position: 0,
                job_type: "test".to_string(),
                problem_id: -1,
                response: None,
                error: None,
            },
        );
        queued_jobs.write().await.insert(
            2,
            JobStatus {
                id: 2,
                user_id: 1,
                queue_position: 1,
                job_type: "test".to_string(),
                problem_id: -1,
                response: None,
                error: None,
            },
        );
        let (broadcast, mut messages) = broadcast::channel(2);
        let pool = SqlitePool::connect_lazy("sqlite::memory:").unwrap();

        tx.send((1, Box::new(PanickingJob) as JobQueueItem))
            .unwrap();
        tx.send((2, Box::new(SucceedingJob) as JobQueueItem))
            .unwrap();
        drop(tx);

        job_worker(
            rx,
            queued_jobs.clone(),
            "http://127.0.0.1:1".to_string(),
            pool,
            broadcast,
            1,
        )
        .await;

        let job = queued_jobs.read().await.get(&1).cloned().unwrap();
        assert_eq!(job.error.as_deref(), Some("Internal server error."));
        assert!(job.response.is_none());
        let succeeding_job = queued_jobs.read().await.get(&2).cloned().unwrap();
        assert_eq!(succeeding_job.response, Some(json!("completed")));
        assert!(matches!(
            timeout(Duration::from_secs(1), messages.recv())
                .await
                .unwrap()
                .unwrap(),
            BroadcastMessage::FinishedJob(status) if status.id == 1
        ));
    }

    #[tokio::test]
    async fn worker_drains_trailing_task_before_receiver_close_returns() {
        let (tx, rx) = mpsc::unbounded_channel();
        let queued_jobs = Arc::new(RwLock::new(HashMap::new()));
        queued_jobs.write().await.insert(
            1,
            JobStatus {
                id: 1,
                user_id: 1,
                queue_position: 0,
                job_type: "test".to_string(),
                problem_id: -1,
                response: None,
                error: None,
            },
        );
        let (broadcast, _) = broadcast::channel(1);
        let started = Arc::new(Notify::new());
        let release = Arc::new(Notify::new());
        let pool = SqlitePool::connect_lazy("sqlite::memory:").unwrap();

        tx.send((
            1,
            Box::new(BlockingJob {
                started: started.clone(),
                release: release.clone(),
            }) as JobQueueItem,
        ))
        .unwrap();
        drop(tx);

        let mut worker = tokio::spawn(job_worker(
            rx,
            queued_jobs.clone(),
            "http://127.0.0.1:1".to_string(),
            pool,
            broadcast,
            1,
        ));
        timeout(Duration::from_secs(1), started.notified())
            .await
            .expect("trailing job should start");
        assert!(timeout(Duration::from_millis(50), &mut worker)
            .await
            .is_err());

        release.notify_one();
        worker.await.unwrap();

        let job = queued_jobs.read().await.get(&1).cloned().unwrap();
        assert_eq!(job.response, Some(json!("completed")));
        assert!(job.error.is_none());
    }
}
