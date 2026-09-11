use axum::{extract::Query, Extension, Json};
use chrono::{NaiveDateTime, Utc};
use serde::Deserialize;
use sqlx::SqlitePool;

use super::Submission;

#[derive(Deserialize)]
pub struct NewCompletionsForm {
    since: Option<NaiveDateTime>,
}

pub async fn new_completions(
    Extension(pool): Extension<SqlitePool>,
    Query(query): Query<NewCompletionsForm>,
) -> Json<Vec<Submission>> {
    let since = query.since.unwrap_or_else(|| Utc::now().naive_local());

    let submissions: Vec<Submission> = sqlx::query_as(
        r#"
        SELECT * FROM (
            SELECT submissions.*,
                ROW_NUMBER() OVER (
                    PARTITION BY user_id, problem_id ORDER BY time, id
                ) AS completion_rank
            FROM submissions
            WHERE success = true AND DATETIME(time) > DATETIME(?, 'localtime')
        )
        WHERE completion_rank = 1
        ORDER BY time, id
        "#,
    )
    .bind(since)
    .fetch_all(&pool)
    .await
    .unwrap_or_default();

    Json(submissions)
}

#[cfg(test)]
mod tests {
    use super::*;
    use shared::models::language::Language;

    #[tokio::test]
    async fn completions_keep_one_deterministic_complete_submission_per_group() {
        let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("../../migrations").run(&pool).await.unwrap();
        sqlx::query("INSERT INTO users (id,name,username,discord_id) VALUES (1,'one','one','one'),(2,'two','two','two')").execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO problems (id,title,description,runner,reference,template) VALUES (1,'test','','','','')").execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO submissions (id,problem_id,user_id,success,runtime,code,language,time) VALUES (1,1,1,1,1,'old','cpp','2025-01-01'),(2,1,1,1,12,'rust-first','rust','2026-01-02 00:00:00'),(3,1,1,1,13,'cpp-tie','cpp','2026-01-02 00:00:00'),(4,1,2,0,14,'failed','rust','2026-01-02 00:00:00'),(5,1,2,1,15,'cpp-first','cpp','2026-01-03 00:00:00'),(6,1,2,1,16,'rust-later','rust','2026-01-04 00:00:00')").execute(&pool).await.unwrap();
        let Json(rows) = new_completions(
            Extension(pool),
            Query(NewCompletionsForm {
                since: Some(
                    NaiveDateTime::parse_from_str("2026-01-01 00:00:00", "%Y-%m-%d %H:%M:%S")
                        .unwrap(),
                ),
            }),
        )
        .await;
        assert_eq!(rows.len(), 2);
        assert_eq!(
            (
                rows[0].id,
                rows[0].language,
                rows[0].runtime,
                rows[0].code.as_str()
            ),
            (2, Language::Rust, 12, "rust-first")
        );
        assert_eq!(
            (
                rows[1].id,
                rows[1].language,
                rows[1].runtime,
                rows[1].code.as_str()
            ),
            (5, Language::Cpp, 15, "cpp-first")
        );
        assert!(rows
            .iter()
            .all(|row| row.success && row.complexity.is_none()));
    }
}
