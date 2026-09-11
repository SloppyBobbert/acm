use axum::{
    extract::{Path, Query},
    Extension, Json,
};
use chrono::NaiveDateTime;
use serde::Serialize;
use sqlx::{FromRow, SqlitePool};

use crate::{
    error::{ServerError, UserError},
    pagination::Pagination,
};

#[derive(Serialize, FromRow)]
pub struct UserSubmission {
    language: shared::models::language::Language,
    id: i64,
    problem_title: String,
    success: bool,
    error: Option<String>,
    runtime: i64,
    code: String,
    time: NaiveDateTime,
}

pub async fn submissions(
    Path(username): Path<String>,
    Query(pagination): Query<Pagination<0, 10>>,
    Extension(pool): Extension<SqlitePool>,
) -> Result<Json<Vec<UserSubmission>>, ServerError> {
    let user_id = sqlx::query!(
        r#"
        SELECT id
        FROM users
        WHERE username = ?
        "#,
        username
    )
    .fetch_one(&pool)
    .await
    .map_err(|_| UserError::NotFound(username))?
    .id;

    let submissions: Vec<UserSubmission> = sqlx::query_as(
        r#"
        SELECT
            submissions.id,
            submissions.language,
            problems.title AS problem_title,
            submissions.success,
            submissions.runtime,
            submissions.error,
            submissions.time,
            submissions.code
        FROM submissions
        JOIN problems ON problems.id = submissions.problem_id
        LEFT JOIN competitions ON competitions.id = problems.competition_id
        WHERE user_id = ?
        AND (
            problems.competition_id IS NULL
            OR competitions.end < datetime('now')
        )
        ORDER BY time DESC
        LIMIT ? OFFSET ?
        "#,
    )
    .bind(user_id)
    .bind(pagination.count)
    .bind(pagination.offset)
    .fetch_all(&pool)
    .await
    .map_err(|_| UserError::InternalError)?;

    Ok(Json(submissions))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn public_submissions_return_persisted_and_legacy_languages() {
        let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("../../migrations").run(&pool).await.unwrap();
        sqlx::query(
            "INSERT INTO users (id,name,username,discord_id) VALUES (1,'test','test','test')",
        )
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query("INSERT INTO problems (id,title,description,runner,reference,template) VALUES (1,'test','','','','')").execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO submissions (problem_id,user_id,success,runtime,code,time) VALUES (1,1,1,1,'legacy','2026-01-01 00:00:00')").execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO submissions (problem_id,user_id,success,runtime,code,language,time) VALUES (1,1,1,1,'rust','rust','2026-01-02 00:00:00')").execute(&pool).await.unwrap();
        let Json(rows) = submissions(
            Path("test".into()),
            Query(Pagination {
                count: 10,
                offset: 0,
            }),
            Extension(pool),
        )
        .await
        .unwrap();
        let rows = serde_json::to_value(rows).unwrap();
        assert_eq!(rows[0]["language"], "rust");
        assert_eq!(rows[1]["language"], "cpp");
    }
}
