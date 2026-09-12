use axum::{Extension, Json};
use chrono::NaiveDateTime;
use serde::{Deserialize, Serialize};
use shared::models::test::Test;
use sqlx::SqlitePool;
use tokio::sync::broadcast::Sender;

use super::Problem;
use crate::{auth::Claims, error::ServerError, ws::BroadcastMessage};

#[derive(Deserialize)]
pub struct NewForm {
    title: String,
    description: String,
    reference: String,
    template: String,
    tests: Vec<Test>,
    activity_id: Option<i64>,
    publish_time: Option<NaiveDateTime>,
    competition_id: Option<i64>,
    runtime_multiplier: Option<f64>,
}

#[derive(Serialize)]
pub struct NewBody {
    id: i64,
}

pub async fn new(
    Extension(pool): Extension<SqlitePool>,
    Extension(broadcast): Extension<Sender<BroadcastMessage>>,
    claims: Claims,
    Json(form): Json<NewForm>,
) -> Result<Json<NewBody>, ServerError> {
    claims.validate_officer()?;

    let mut tx = pool.begin().await.map_err(|_| ServerError::InternalError)?;

    let visible = form.publish_time.is_none();

    let problem: Problem = sqlx::query_as(
        r#"
        INSERT INTO problems (
            title,
            description,
            runner,
            reference,
            template,
            activity_id,
            visible,
            publish_time,
            runtime_multiplier,
            competition_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        RETURNING
            id,
            title,
            description,
            runner,
            template,
            competition_id,
            runtime_multiplier,
            visible,
            difficulty
        "#,
    )
    .bind(form.title)
    .bind(form.description)
    .bind("")
    .bind(form.reference)
    .bind(form.template)
    .bind(form.activity_id)
    .bind(visible)
    .bind(form.publish_time)
    .bind(form.runtime_multiplier)
    .bind(form.competition_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(|e| {
        log::error!("{e}");
        ServerError::InternalError
    })?;

    for test in &form.tests {
        let input_string = serde_json::to_string(&test.input).unwrap();
        let expected_output_string = serde_json::to_string(&test.expected_output).unwrap();

        sqlx::query!(
            r#"
            INSERT INTO tests (
                problem_id,
                test_number,
                input,
                expected_output,
                max_runtime
            )
            VALUES (?, ?, ?, ?, ?)
            "#,
            problem.id,
            test.index,
            input_string,
            expected_output_string,
            test.max_fuel
        )
        .execute(&mut *tx)
        .await
        .map_err(|e| {
            log::error!("{e}");
            ServerError::InternalError
        })?;
    }

    // We only immediately broadcast that there's a new problem if its set to publish immediately
    if form.publish_time.is_none() {
        broadcast
            .send(BroadcastMessage::NewProblem(problem.clone()))
            .ok();
    }

    tx.commit().await.map_err(|e| {
        log::error!("{e}");
        ServerError::InternalError
    })?;

    Ok(Json(NewBody { id: problem.id }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::Auth;

    // Test-only claims and an in-memory database. No login or runner acceptance.
    #[tokio::test]
    async fn local_samples_use_existing_creation_and_test_paths() {
        let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("../../migrations").run(&pool).await.unwrap();
        let (broadcast, _) = tokio::sync::broadcast::channel(8);
        for json in [
            include_str!("../../../../docs/examples/local-demo/add.json"),
            include_str!("../../../../docs/examples/local-demo/larger.json"),
        ] {
            for auth in [Auth::LoggedOut, Auth::Member] {
                assert!(new(
                    Extension(pool.clone()),
                    Extension(broadcast.clone()),
                    Claims {
                        user_id: -1,
                        auth,
                        exp: 0
                    },
                    Json(serde_json::from_str(json).unwrap()),
                )
                .await
                .is_err());
            }
            let form: NewForm = serde_json::from_str(json).unwrap();
            let expected = form.tests.clone();
            let created = new(
                Extension(pool.clone()),
                Extension(broadcast.clone()),
                Claims {
                    user_id: 1,
                    auth: Auth::Officer,
                    exp: 0,
                },
                Json(form),
            )
            .await
            .unwrap()
            .0;
            assert!(crate::run::rust_signature(&pool, created.id, None)
                .await
                .is_ok());
            for expected in expected {
                let actual = super::super::tests::problem_test(
                    Extension(pool.clone()),
                    axum::extract::Path((created.id, expected.index)),
                )
                .await
                .unwrap()
                .0
                .unwrap();
                assert_eq!(actual.input, expected.input);
                assert_eq!(actual.expected_output, expected.expected_output);
                assert_eq!(actual.max_fuel, expected.max_fuel);
            }
        }
        let (count,): (i64,) = sqlx::query_as("SELECT count(*) FROM problems")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(count, 2);
    }
}
