use actix_web::rt::task;
use async_trait::async_trait;
use shared::models::{
    forms::{CustomInputJob, GenerateTestsJob, SubmitJob},
    runner::{CustomInputResponse, RunnerError, RunnerResponse},
    test::{Test, TestResult},
};
use std::{
    collections::BTreeSet,
    path::Path,
    sync::{
        atomic::{AtomicU8, Ordering},
        Arc,
    },
};
use wasm_memory::{FunctionValue, WasmFunctionCall};

use wasmtime::{Cache, Config, Engine, Linker, Module, Store, StoreLimits, StoreLimitsBuilder};
use wasmtime_wasi::{
    p1::{add_to_linker_sync, WasiP1Ctx},
    p2::pipe::MemoryOutputPipe,
    WasiCtxBuilder,
};

mod cplusplus;

pub use cplusplus::CPlusPlus;

#[async_trait]
pub trait Runner {
    async fn run_tests(
        &self,
        form: SubmitJob,
        deadline: tokio::time::Instant,
        timeout_message: &str,
    ) -> Result<RunnerResponse, RunnerError>;
    async fn generate_tests(
        &self,
        form: GenerateTestsJob,
        deadline: tokio::time::Instant,
        timeout_message: &str,
    ) -> Result<Vec<Test>, RunnerError>;
    async fn run_custom_input(
        &self,
        form: CustomInputJob,
        deadline: tokio::time::Instant,
        timeout_message: &str,
    ) -> Result<CustomInputResponse, RunnerError>;
}

struct TestResults {
    failed_tests: BTreeSet<TestResult>,
    passed_tests: BTreeSet<TestResult>,

    runtime: i64,
}

impl TestResults {
    fn new() -> Self {
        Self {
            failed_tests: BTreeSet::new(),
            passed_tests: BTreeSet::new(),
            runtime: 0,
        }
    }

    fn insert(&mut self, test: TestResult) {
        if test.success {
            self.passed_tests.insert(test);
        } else {
            self.failed_tests.insert(test);
        }
    }
}

impl Into<RunnerResponse> for TestResults {
    fn into(self) -> RunnerResponse {
        let mut tests = Vec::with_capacity(self.failed_tests.len() + self.passed_tests.len());
        let passed = self.failed_tests.is_empty();
        tests.extend(self.failed_tests);
        tests.extend(self.passed_tests);

        RunnerResponse {
            tests,
            runtime: self.runtime,
            passed,
        }
    }
}

struct MyState {
    limits: StoreLimits,
    wasi: WasiP1Ctx,
}

struct EpochCancellation {
    state: AtomicU8,
}

impl EpochCancellation {
    const REQUESTED: u8 = 0b01;
    const ARMED: u8 = 0b10;

    fn new() -> Self {
        Self {
            state: AtomicU8::new(0),
        }
    }

    fn mark(&self, bit: u8, counterpart: u8) -> bool {
        self.state.fetch_or(bit, Ordering::AcqRel) == counterpart
    }

    fn request(&self, engine: &Engine) -> bool {
        let increment = self.mark(Self::REQUESTED, Self::ARMED);
        if increment {
            engine.increment_epoch();
        }
        increment
    }

    fn arm(&self, engine: &Engine) -> bool {
        let increment = self.mark(Self::ARMED, Self::REQUESTED);
        if increment {
            engine.increment_epoch();
        }
        increment
    }
}

/// Runs a command with a specified input, returning a RuntimeError if the process returns an
/// error, otherwise returns the output and the duration
///
/// Padding dictates how much extra fuel should be allotted before we force stop their function.
/// e.g. A padding value of 10 means it can be 10x slower before we force stop it
async fn run_test_timed(
    command: &str,
    test: Test,
    padding: i64,
    deadline: tokio::time::Instant,
    timeout_message: &str,
) -> Result<(TestResult, String), RunnerError> {
    let max_runtime = test.max_fuel.map(|x| x * padding);

    match run_command(
        command,
        test.input.clone(),
        max_runtime,
        deadline,
        timeout_message,
    )
    .await
    {
        Ok((result, output, fuel)) => {
            let mut test_result = test.make_result(result, fuel);

            if fuel > test_result.max_fuel.unwrap_or(MAX_FUEL) as u64 {
                test_result.success = false;
                test_result.error = Some("Fuel limit exceeded".to_string())
            }

            Ok((test_result, output))
        }
        Err(RunnerError::RuntimeError { message }) => Ok((
            test.make_result_error(message, max_runtime.unwrap_or(MAX_FUEL) as u64),
            String::new(),
        )),
        Err(e) => Err(e),
    }
}

const MAX_MEMORY: usize = 1 << 29; // 512MB
const MAX_FUEL: i64 = 1 << 48;

async fn run_command(
    command: &str,
    input: WasmFunctionCall,
    fuel: Option<i64>,
    deadline: tokio::time::Instant,
    timeout_message: &str,
) -> Result<(FunctionValue, String, u64), RunnerError> {
    if tokio::time::Instant::now() >= deadline {
        return Err(timeout_error(timeout_message));
    }
    let command = command.to_string();
    let timeout_message = timeout_message.to_string();
    let mut config = Config::default();
    config.consume_fuel(true);
    config.epoch_interruption(true);
    let cache = Cache::from_file(Some(Path::new("./wasmtime-cache.toml")))
        .expect("Failed to load cache configuration");
    config.cache(Some(cache));
    let engine = Engine::new(&config).expect("Failed to create engine");
    let cancellation = Arc::new(EpochCancellation::new());
    let blocking_cancellation = cancellation.clone();
    let blocking_engine = engine.clone();
    let handle = task::spawn_blocking(move || {
        let mut linker = Linker::new(&blocking_engine);
        add_to_linker_sync(&mut linker, |state: &mut MyState| &mut state.wasi).map_err(|e| {
            log::error!("add_to_linker: {e}");
            RunnerError::InternalServerError {
                message: "Failed to add wasi runtime to linker".to_string(),
            }
        })?;

        let stdout = MemoryOutputPipe::new(MAX_MEMORY);

        let mut store = Store::new(
            &blocking_engine,
            MyState {
                wasi: WasiCtxBuilder::new().stdout(stdout.clone()).build_p1(),
                limits: StoreLimitsBuilder::new()
                    .memory_size(MAX_MEMORY)
                    .instances(2)
                    .build(),
            },
        );
        store.set_epoch_deadline(1);
        blocking_cancellation.arm(&blocking_engine);

        store
            .set_fuel(fuel.unwrap_or(MAX_FUEL) as u64)
            .expect("Failed to set fuel");
        store.limiter(|state| &mut state.limits);

        // Instantiate our module with the imports we've created, and run it.
        let module = Module::from_file(&blocking_engine, command).map_err(|e| {
            log::error!("opening: {e}");
            RunnerError::InternalServerError {
                message: "Failed to open file".to_string(),
            }
        })?;

        const FUEL_DEFAULT: u64 = 100_000_000_000;
        let fuel_before_initialize = store.get_fuel().expect("Failed to get fuel");
        store
            .set_fuel(fuel_before_initialize + FUEL_DEFAULT)
            .expect("Failed to set fuel");

        linker
            .module(&mut store, "", &module)
            .map_err(|e| RunnerError::InternalServerError {
                message: format!("Failed to initialize module:\n{}", e.root_cause()),
            })?;

        let instance = linker.instantiate(&mut store, &module).map_err(|e| {
            log::error!("{e:?}");
            RunnerError::InternalServerError {
                message: format!("Failed to create instance:\n{}", e.root_cause()),
            }
        })?;

        let fuel_after_initialize = store.get_fuel().expect("Failed to get fuel");
        let consumed_for_initialize = fuel_before_initialize + FUEL_DEFAULT - fuel_after_initialize;
        let leftover_initialize_fuel = FUEL_DEFAULT - consumed_for_initialize;
        store
            .set_fuel(fuel_after_initialize - leftover_initialize_fuel)
            .expect("Failed setting fuel");

        let result = input.call(&mut store, &instance);

        drop(store);

        let bytes = stdout.contents();
        let output = String::from_utf8_lossy(&bytes).to_string();

        match result {
            Ok((res, fuel)) => Ok((res, output, fuel)),
            Err(e) => Err(RunnerError::RuntimeError {
                message: e.root_cause().to_string(),
            }),
        }
    });

    tokio::pin!(handle);
    tokio::select! {
        biased;
        result = &mut handle => result.map_err(|e| {
        log::error!("caught error: {e}");
        RunnerError::InternalServerError {
            message: "Failed to create thread".to_string(),
        }
    })?,
        _ = tokio::time::sleep_until(deadline) => {
            cancellation.request(&engine);
            let _ = handle.await;
            Err(timeout_error(&timeout_message))
        }
    }
}

fn timeout_error(message: &str) -> RunnerError {
    RunnerError::TimeoutError {
        message: message.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wasmtime::Instance;

    #[tokio::test]
    async fn epoch_interrupts_an_infinite_loop_before_join_returns() {
        let mut config = Config::default();
        config.epoch_interruption(true);
        let engine = Engine::new(&config).unwrap();
        let module = Module::new(&engine, "(module (func (export \"loop\") (loop br 0)))").unwrap();
        let interruption_engine = engine.clone();
        let (started_tx, started_rx) = std::sync::mpsc::channel();

        let handle = task::spawn_blocking(move || {
            let mut store = Store::new(&engine, ());
            store.set_epoch_deadline(1);
            let instance = Instance::new(&mut store, &module, &[]).unwrap();
            let loop_fn = instance
                .get_typed_func::<(), ()>(&mut store, "loop")
                .unwrap();
            started_tx.send(()).unwrap();
            let result: wasmtime::Result<()> = loop_fn.call(&mut store, ());
            result
        });

        while started_rx.try_recv().is_err() {
            tokio::task::yield_now().await;
        }
        interruption_engine.increment_epoch();
        assert!(handle.await.unwrap().is_err());
    }

    #[tokio::test]
    async fn cancellation_requested_before_epoch_deadline_is_armed_interrupts_guest() {
        let mut config = Config::default();
        config.epoch_interruption(true);
        let engine = Engine::new(&config).unwrap();
        let module = Module::new(&engine, "(module (func (export \"loop\") (loop br 0)))").unwrap();
        let cancellation = Arc::new(EpochCancellation::new());
        cancellation.request(&engine);
        let blocking_cancellation = cancellation.clone();

        let handle = task::spawn_blocking(move || {
            let mut store = Store::new(&engine, ());
            store.set_epoch_deadline(1);
            blocking_cancellation.arm(&engine);
            let instance = Instance::new(&mut store, &module, &[]).unwrap();
            let loop_fn = instance
                .get_typed_func::<(), ()>(&mut store, "loop")
                .unwrap();
            let result: wasmtime::Result<()> = loop_fn.call(&mut store, ());
            result
        });

        assert!(handle.await.unwrap().is_err());
    }

    #[test]
    fn cancellation_request_then_arm_increments_once() {
        let cancellation = EpochCancellation::new();
        assert!(!cancellation.mark(EpochCancellation::REQUESTED, EpochCancellation::ARMED));
        assert!(cancellation.mark(EpochCancellation::ARMED, EpochCancellation::REQUESTED));
    }

    #[test]
    fn cancellation_arm_then_request_increments_once() {
        let cancellation = EpochCancellation::new();
        assert!(!cancellation.mark(EpochCancellation::ARMED, EpochCancellation::REQUESTED));
        assert!(cancellation.mark(EpochCancellation::REQUESTED, EpochCancellation::ARMED));
    }

    #[test]
    fn repeated_request_then_first_arm_increments_once() {
        let cancellation = EpochCancellation::new();
        assert!(!cancellation.mark(EpochCancellation::REQUESTED, EpochCancellation::ARMED));
        assert!(!cancellation.mark(EpochCancellation::REQUESTED, EpochCancellation::ARMED));
        assert!(cancellation.mark(EpochCancellation::ARMED, EpochCancellation::REQUESTED));
    }

    #[test]
    fn repeated_arm_then_first_request_increments_once() {
        let cancellation = EpochCancellation::new();
        assert!(!cancellation.mark(EpochCancellation::ARMED, EpochCancellation::REQUESTED));
        assert!(!cancellation.mark(EpochCancellation::ARMED, EpochCancellation::REQUESTED));
        assert!(cancellation.mark(EpochCancellation::REQUESTED, EpochCancellation::ARMED));
    }

    #[test]
    fn cancellation_marks_after_both_bits_are_set_do_not_increment() {
        let cancellation = EpochCancellation::new();
        assert!(!cancellation.mark(EpochCancellation::REQUESTED, EpochCancellation::ARMED));
        assert!(cancellation.mark(EpochCancellation::ARMED, EpochCancellation::REQUESTED));
        assert!(!cancellation.mark(EpochCancellation::REQUESTED, EpochCancellation::ARMED));
        assert!(!cancellation.mark(EpochCancellation::ARMED, EpochCancellation::REQUESTED));
    }
}
