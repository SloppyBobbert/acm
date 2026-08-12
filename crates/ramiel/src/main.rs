use std::time::Duration;

use shared::models::{
    forms::{CustomInputJob, GenerateTestsJob, SubmitJob},
    runner::{CustomInputResponse, RunnerError, RunnerResponse},
    test::Test,
};

use actix_web::{get, middleware::Logger, post, web, web::Json, App, HttpResponse, HttpServer};

mod runners;

use clap::Parser;
use runners::{CPlusPlus, Runner};

const RUN_TIMEOUT_MESSAGE: &str = "The tests took too long to run. (process killed)";

#[get("/healthz")]
async fn healthz() -> HttpResponse {
    HttpResponse::Ok().finish()
}

#[post("/run/c++")]
async fn cplusplus_run(form: Json<SubmitJob>) -> Json<Result<RunnerResponse, RunnerError>> {
    Json(
        CPlusPlus
            .run_tests(
                form.into_inner(),
                tokio::time::Instant::now() + Duration::from_secs(360),
                RUN_TIMEOUT_MESSAGE,
            )
            .await,
    )
}

#[post("/generate-tests/c++")]
async fn cplusplus_generate_tests(
    form: Json<GenerateTestsJob>,
) -> Json<Result<Vec<Test>, RunnerError>> {
    Json(
        CPlusPlus
            .generate_tests(
                form.into_inner(),
                tokio::time::Instant::now() + Duration::from_secs(120),
                RUN_TIMEOUT_MESSAGE,
            )
            .await,
    )
}

#[post("/custom-input/c++")]
async fn cplusplus_custom_input(
    form: Json<CustomInputJob>,
) -> Json<Result<CustomInputResponse, RunnerError>> {
    Json(
        CPlusPlus
            .run_custom_input(
                form.into_inner(),
                tokio::time::Instant::now() + Duration::from_secs(60),
                RUN_TIMEOUT_MESSAGE,
            )
            .await,
    )
}

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Args {
    #[arg(short, env, long, default_value_t = 8082)]
    port: u16,

    #[arg(long, env, default_value = "127.0.0.1")]
    hostname: String,
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    env_logger::init_from_env(env_logger::Env::new().default_filter_or("warn"));
    let args = Args::parse();

    let json_cfg = web::JsonConfig::default()
        // 3mb limit
        .limit(100_000_000);

    HttpServer::new(move || {
        App::new()
            .wrap(Logger::default())
            .app_data(json_cfg.clone())
            .service(healthz)
            .service(cplusplus_run)
            .service(cplusplus_generate_tests)
            .service(cplusplus_custom_input)
    })
    .bind(&format!("{}:{}", args.hostname, args.port))?
    .run()
    .await
}
