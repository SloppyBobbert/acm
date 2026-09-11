use axum::{extract::Path, Extension, Json};
use serde::Serialize;
use shared::models::test::TestResult;
use sqlx::{FromRow, SqlitePool};

use crate::{auth::Claims, error::ServerError};

#[derive(FromRow, Serialize)]
pub struct TestResultNoInput {
    id: i64,
    index: i64,
    success: bool,
    hidden: bool,
}

pub async fn recent_tests(
    claims: Claims,
    Extension(pool): Extension<SqlitePool>,
    Path(problem_id): Path<i64>,
) -> Result<Json<Vec<TestResultNoInput>>, ServerError> {
    claims.validate_logged_in()?;

    let tests: Vec<TestResultNoInput> = sqlx::query_as(
        r#"
        SELECT
            test_results.id as id,
            tests.test_number as [index],
            tests.hidden as hidden,
            test_results.success as success
        FROM
            test_results INNER JOIN tests
            ON test_results.test_id = tests.id
        WHERE
            test_results.submission_id = (
                SELECT id
                FROM submissions
                WHERE user_id = ?
                AND problem_id = ?
                ORDER BY time DESC
                LIMIT 1
            )
        ORDER BY
            tests.test_number ASC, test_results.success
        "#,
    )
    .bind(claims.user_id)
    .bind(problem_id)
    .fetch_all(&pool)
    .await
    .map_err(|e| {
        log::error!("{e:?}");

        ServerError::NotFound
    })?;

    Ok(Json(tests))
}

#[derive(FromRow)]
struct RecentTest {
    #[sqlx(flatten)]
    test: TestResult,
    language: shared::models::language::Language,
    runtime_multiplier: Option<f64>,
}

pub async fn recent_tests_test(
    claims: Claims,
    Extension(pool): Extension<SqlitePool>,
    Path((problem_id, test_number)): Path<(i64, i64)>,
) -> Result<Json<TestResult>, ServerError> {
    claims.validate_logged_in()?;

    // Read result and language in one database snapshot, not two latest lookups.
    let RecentTest {
        mut test,
        language,
        runtime_multiplier,
    } = sqlx::query_as::<_, RecentTest>(
        r#"
        SELECT
            test_results.id as id,
            test_results.success as success,
            test_results.output as output,
            test_results.runtime as runtime,
            test_results.error as error,
            tests.max_runtime as max_runtime,
            tests.input as input,
            tests.expected_output as expected_output,
            tests.test_number as test_number,
            tests.hidden as hidden,
            submissions.language as language,
            problems.runtime_multiplier as runtime_multiplier
        FROM
            test_results INNER JOIN tests
            ON test_results.test_id = tests.id
            INNER JOIN submissions ON submissions.id = test_results.submission_id
            INNER JOIN problems ON problems.id = submissions.problem_id
        WHERE
            test_results.submission_id = (
                SELECT id
                FROM submissions
                WHERE user_id = ?
                AND problem_id = ?
                ORDER BY time DESC
                LIMIT 1
            )
        AND
            test_number = ?
        ORDER BY
            tests.test_number ASC, test_results.success"#,
    )
    .bind(claims.user_id)
    .bind(problem_id)
    .bind(test_number)
    .fetch_one(&pool)
    .await
    .map_err(|e| {
        log::error!("{e}");
        ServerError::NotFound
    })?;

    test.adjust_runtime(runtime_multiplier);
    test.max_fuel = language.fuel_limit(test.max_fuel);

    Ok(Json(test))
}

#[cfg(test)]
mod regression_tests {
    use super::*;
    use crate::auth::Auth;

    #[tokio::test]
    async fn result_and_budget_belong_to_the_same_submission() {
        let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
        sqlx::migrate!("../../migrations").run(&pool).await.unwrap();
        sqlx::query(
            "INSERT INTO users (id,name,username,discord_id) VALUES (1,'test','test','test')",
        )
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query("INSERT INTO problems (id,title,description,runner,reference,template,runtime_multiplier) VALUES (1,'test','','','','',2)").execute(&pool).await.unwrap();
        let input =
            r#"{"name":"add","arguments":[{"Int":{"Single":1}}],"return_type":{"Int":"Single"}}"#;
        let output = r#"{"Int":{"Single":1}}"#;
        sqlx::query("INSERT INTO tests (id,problem_id,test_number,input,expected_output,max_runtime) VALUES (1,1,0,?,?,10)")
            .bind(input).bind(output).execute(&pool).await.unwrap();
        let mut previous = None;
        for (id, language, budget) in [(1i64, "cpp", 20), (2, "rust", 100_000), (3, "cpp", 20)] {
            sqlx::query("INSERT INTO submissions (id,problem_id,user_id,success,runtime,code,language,time) VALUES (?,1,1,1,1,'test',?,?)")
                .bind(id).bind(language).bind(format!("2026-01-0{id} 00:00:00"))
                .execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO test_results (id,submission_id,test_id,runtime,output,success) VALUES (?,?,1,1,?,1)")
                .bind(id).bind(id).bind(output).execute(&pool).await.unwrap();
            let Json(result) = recent_tests_test(
                Claims {
                    user_id: 1,
                    auth: Auth::Member,
                    exp: 0,
                },
                Extension(pool.clone()),
                Path((1, 0)),
            )
            .await
            .unwrap();
            assert_eq!(result.id, id);
            assert_eq!(result.max_fuel, Some(budget));
            if let Some((old_result, old_budget)) = previous {
                let old_result: TestResult = old_result;
                assert_eq!(old_result.max_fuel, Some(old_budget));
                assert_ne!(old_result.id, result.id);
            }
            previous = Some((result, budget));
        }
    }
}
