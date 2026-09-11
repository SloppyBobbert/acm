// These tests mock Ramiel HTTP responses; they do not compile user code.
use super::*;
use shared::models::{
    forms::{CustomInputJob, SubmitJob},
    language::Language,
    runner::RunnerResponse,
};
use wasm_memory::{
    ContainerVariant, ContainerVariantType, FunctionType, FunctionValue, WasmFunctionCall,
};

fn input() -> WasmFunctionCall {
    WasmFunctionCall::new(
        "add",
        vec![FunctionValue::Int(ContainerVariant::Single(1))],
        FunctionType::Int(ContainerVariantType::Single),
    )
}

#[tokio::test]
async fn migration_and_submission_routes_keep_legacy_defaults() {
    let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
    sqlx::migrate!("../../migrations").run(&pool).await.unwrap();
    sqlx::query("INSERT INTO users (id,name,username,discord_id) VALUES (1,'test','test','test')")
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO problems (id,title,description,runner,reference,template) VALUES (1,'test','','','','')").execute(&pool).await.unwrap();
    sqlx::query(
        "INSERT INTO submissions (problem_id,user_id,success,runtime,code) VALUES (1,1,0,0,'old')",
    )
    .execute(&pool)
    .await
    .unwrap();
    let old: crate::submissions::Submission =
        sqlx::query_as("SELECT * FROM submissions WHERE code='old'")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(old.language, Language::Cpp);

    let app = axum::Router::new()
        .route(
            "/run/rust",
            axum::routing::post(|| async { Json(Ok::<_, RunnerError>(RunnerResponse::default())) }),
        )
        .route(
            "/run/c++",
            axum::routing::post(|| async {
                Json(Err::<RunnerResponse, _>(RunnerError::CompilationError {
                    diagnostics: vec![],
                }))
            }),
        )
        .route(
            "/custom-input/rust",
            axum::routing::post(|| async {
                Json(Ok::<_, RunnerError>(serde_json::json!({"custom": "rust"})))
            }),
        );
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(
        axum::Server::from_tcp(listener)
            .unwrap()
            .serve(app.into_make_service()),
    );
    let (broadcast, _) = broadcast::channel(8);
    let legacy =
        serde_json::json!({"problem_id":1,"user_id":1,"implementation":"old-client","tests":[]});
    let mut job: SubmitJob = serde_json::from_value(legacy.clone()).unwrap();
    assert_eq!(job.language, Language::Cpp);
    let result = job.run(&url, &pool, &broadcast).await.unwrap();
    assert_eq!(result["language"], "cpp");
    assert_eq!(result["error"], "[]");
    job.language = Language::Rust;
    job.implementation = "fn add(a: i32) -> i32 { a }".into();
    let result = job.run(&url, &pool, &broadcast).await.unwrap();
    assert_eq!(result["language"], "rust");
    let stored: crate::submissions::Submission =
        sqlx::query_as("SELECT * FROM submissions WHERE id=?")
            .bind(result["id"].as_i64().unwrap())
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(stored.language, Language::Rust);
    assert_eq!(stored.code, job.implementation);
    let mut custom: CustomInputJob = serde_json::from_value(serde_json::json!({"problem_id":1,"user_id":1,"implementation":"","reference":"","input":input()})).unwrap();
    assert_eq!(custom.language, Language::Cpp);
    custom.language = Language::Rust;
    assert_eq!(
        custom.run(&url, &pool, &broadcast).await.unwrap()["custom"],
        "rust"
    );
    let form: super::submit::SubmitForm = serde_json::from_value(legacy.clone()).unwrap();
    assert_eq!(form.language, Language::Cpp);
    let mut invalid = legacy;
    invalid["language"] = "python".into();
    assert!(serde_json::from_value::<super::submit::SubmitForm>(invalid).is_err());
    server.abort();
}

#[tokio::test]
async fn custom_signature_must_match_stored_tests() {
    let pool = SqlitePool::connect("sqlite::memory:").await.unwrap();
    sqlx::query("CREATE TABLE tests (problem_id INTEGER, test_number INTEGER, input TEXT)")
        .execute(&pool)
        .await
        .unwrap();
    assert!(rust_signature(&pool, 1, Some(&input())).await.is_err());
    sqlx::query("INSERT INTO tests VALUES (1,0,?)")
        .bind(serde_json::to_string(&input()).unwrap())
        .execute(&pool)
        .await
        .unwrap();
    assert!(rust_signature(&pool, 1, Some(&input())).await.is_ok());
    let mut different = input();
    different.name = "another".into();
    assert!(rust_signature(&pool, 1, Some(&different)).await.is_err());
    different = input();
    different.arguments[0] = FunctionValue::Int(ContainerVariant::List(vec![1]));
    assert!(rust_signature(&pool, 1, Some(&different)).await.is_err());
}
