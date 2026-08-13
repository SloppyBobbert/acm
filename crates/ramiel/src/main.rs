use std::{path::PathBuf, time::Duration};

use shared::models::{
    forms::{CustomInputJob, GenerateTestsJob, SubmitJob},
    runner::{CustomInputResponse, RunnerError, RunnerResponse},
    test::Test,
};

use actix_web::{get, middleware::Logger, post, web, web::Json, App, HttpResponse, HttpServer};

mod runners;

use clap::Parser;
use runners::{CPlusPlus, Runner, WasmRuntime};

const RUN_TIMEOUT_MESSAGE: &str = "The tests took too long to run. (process killed)";

#[get("/healthz")]
async fn healthz() -> HttpResponse {
    HttpResponse::Ok().finish()
}

#[post("/run/c++")]
async fn cplusplus_run(
    runner: web::Data<CPlusPlus>,
    form: Json<SubmitJob>,
) -> Json<Result<RunnerResponse, RunnerError>> {
    Json(
        runner
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
    runner: web::Data<CPlusPlus>,
    form: Json<GenerateTestsJob>,
) -> Json<Result<Vec<Test>, RunnerError>> {
    Json(
        runner
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
    runner: web::Data<CPlusPlus>,
    form: Json<CustomInputJob>,
) -> Json<Result<CustomInputResponse, RunnerError>> {
    Json(
        runner
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

    #[arg(
        long,
        env = "WASMTIME_CACHE_CONFIG",
        default_value = "./wasmtime-cache.toml"
    )]
    wasmtime_cache_config: PathBuf,
}

fn main() -> std::io::Result<()> {
    env_logger::init_from_env(env_logger::Env::new().default_filter_or("warn"));
    let args = Args::parse();
    let runtime = WasmRuntime::new(&args.wasmtime_cache_config).map_err(std::io::Error::other)?;
    let runner = CPlusPlus::new(runtime);

    actix_web::rt::System::new().block_on(run_server(args, runner))
}

async fn run_server(args: Args, runner: CPlusPlus) -> std::io::Result<()> {
    let json_cfg = web::JsonConfig::default()
        // 3mb limit
        .limit(100_000_000);

    HttpServer::new(move || {
        App::new()
            .wrap(Logger::default())
            .app_data(json_cfg.clone())
            .app_data(web::Data::new(runner.clone()))
            .service(healthz)
            .service(cplusplus_run)
            .service(cplusplus_generate_tests)
            .service(cplusplus_custom_input)
    })
    .bind(&format!("{}:{}", args.hostname, args.port))?
    .run()
    .await
}
