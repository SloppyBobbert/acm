use actix_web::rt::task;
use async_trait::async_trait;
use shared::models::{
    forms::{CustomInputJob, GenerateTestsJob, SubmitJob},
    runner::{CustomInputResponse, RunnerError, RunnerResponse},
    test::{Test, TestResult},
};
use std::{
    collections::BTreeSet,
    io::{self, Read},
    path::Path,
    sync::Arc,
    time::Duration,
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

pub const EPOCH_PERIOD: Duration = Duration::from_millis(10);
const MAX_WASM_MODULE_BYTES: u64 = 64 * 1024 * 1024;

#[derive(Clone)]
pub struct WasmRuntime {
    engine: Engine,
    epoch_period: Duration,
}

impl WasmRuntime {
    pub fn new(cache_path: &Path) -> anyhow::Result<Arc<Self>> {
        let mut config = Config::default();
        config.consume_fuel(true);
        config.epoch_interruption(true);
        config.cache(Some(Cache::from_file(Some(cache_path))?));
        let engine = Engine::new(&config)?;
        let weak = engine.weak();
        std::thread::Builder::new()
            .name("wasmtime-epoch-ticker".into())
            .spawn(move || {
                while let Some(engine) = weak.upgrade() {
                    std::thread::sleep(EPOCH_PERIOD);
                    engine.increment_epoch();
                }
            })?;
        let runtime = Arc::new(Self {
            engine,
            epoch_period: EPOCH_PERIOD,
        });
        Ok(runtime)
    }
}

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

impl From<TestResults> for RunnerResponse {
    fn from(results: TestResults) -> Self {
        let mut tests = Vec::with_capacity(results.failed_tests.len() + results.passed_tests.len());
        let passed = results.failed_tests.is_empty();
        tests.extend(results.failed_tests);
        tests.extend(results.passed_tests);

        Self {
            tests,
            runtime: results.runtime,
            passed,
        }
    }
}

struct MyState {
    limits: StoreLimits,
    wasi: WasiP1Ctx,
}

/// Runs a command with a specified input, returning a RuntimeError if the process returns an
/// error, otherwise returns the output and the duration
///
/// Padding dictates how much extra fuel should be allotted before we force stop their function.
/// e.g. A padding value of 10 means it can be 10x slower before we force stop it
async fn run_test_timed(
    runtime: Arc<WasmRuntime>,
    command: &str,
    test: Test,
    padding: i64,
    deadline: tokio::time::Instant,
    timeout_message: &str,
) -> Result<(TestResult, String), RunnerError> {
    let max_runtime = test
        .max_fuel
        .map(|x| x.saturating_mul(padding).clamp(0, MAX_FUEL));

    match run_command(
        runtime,
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

            if fuel > clamp_fuel(test_result.max_fuel) {
                test_result.success = false;
                test_result.error = Some("Fuel limit exceeded".to_string())
            }

            Ok((test_result, output))
        }
        Err(RunnerError::RuntimeError { message }) => Ok((
            test.make_result_error(message, clamp_fuel(max_runtime)),
            String::new(),
        )),
        Err(e) => Err(e),
    }
}

const MAX_MEMORY: usize = 1 << 29; // 512MB
const MAX_FUEL: i64 = 1 << 48;

fn clamp_fuel(fuel: Option<i64>) -> u64 {
    fuel.unwrap_or(MAX_FUEL).clamp(0, MAX_FUEL) as u64
}

fn restore_fuel_after_bonus(fuel_before: u64, fuel_after: u64, requested_bonus: u64) -> u64 {
    let granted_bonus = u64::MAX.saturating_sub(fuel_before).min(requested_bonus);
    let fuel_with_bonus = fuel_before.saturating_add(granted_bonus);
    let consumed = fuel_with_bonus.saturating_sub(fuel_after);
    fuel_after.saturating_sub(granted_bonus.saturating_sub(consumed))
}

fn epoch_ticks_until(
    deadline: tokio::time::Instant,
    now: tokio::time::Instant,
    period: Duration,
) -> u64 {
    if deadline <= now {
        return 1;
    }
    let remaining = deadline.duration_since(now);
    let period_ns = period.as_nanos().max(1);
    let ticks = (remaining.as_nanos().saturating_add(period_ns - 1) / period_ns).saturating_add(1);
    ticks.min(u64::MAX as u128) as u64
}

fn read_bounded(mut reader: impl Read, limit: u64) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    reader
        .by_ref()
        .take(limit.saturating_add(1))
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "compiled module exceeds size limit",
        ));
    }
    Ok(bytes)
}

fn is_interrupt(error: &anyhow::Error) -> bool {
    error.downcast_ref::<wasmtime::Trap>() == Some(&wasmtime::Trap::Interrupt)
}

fn map_interrupt(
    error: anyhow::Error,
    timeout_message: &str,
    otherwise: impl FnOnce(anyhow::Error) -> RunnerError,
) -> RunnerError {
    if is_interrupt(&error) {
        timeout_error(timeout_message)
    } else {
        otherwise(error)
    }
}

pub(crate) async fn run_command(
    runtime: Arc<WasmRuntime>,
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
    let blocking_timeout_message = timeout_message.clone();
    let blocking_engine = runtime.engine.clone();
    let epoch_period = runtime.epoch_period;
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
        store.set_epoch_deadline(epoch_ticks_until(
            deadline,
            tokio::time::Instant::now(),
            epoch_period,
        ));
        store.epoch_deadline_trap();
        store.set_fuel(clamp_fuel(fuel)).map_err(|e| {
            log::error!("failed to set initial fuel: {e}");
            RunnerError::InternalServerError {
                message: "Failed to configure wasm fuel".to_string(),
            }
        })?;
        store.limiter(|state| &mut state.limits);

        // Instantiate our module with the imports we've created, and run it.
        if tokio::time::Instant::now() >= deadline {
            return Err(timeout_error(&blocking_timeout_message));
        }
        let file = std::fs::File::open(&command).map_err(|e| RunnerError::InternalServerError {
            message: e.to_string(),
        })?;
        let bytes = read_bounded(file, MAX_WASM_MODULE_BYTES).map_err(|e| {
            RunnerError::InternalServerError {
                message: e.to_string(),
            }
        })?;
        let module = Module::from_binary(&blocking_engine, &bytes).map_err(|e| {
            log::error!("opening: {e}");
            RunnerError::InternalServerError {
                message: "Failed to open file".to_string(),
            }
        })?;

        const FUEL_DEFAULT: u64 = 100_000_000_000;
        let fuel_before_initialize = store.get_fuel().map_err(|e| {
            log::error!("failed to get fuel before initialization: {e}");
            RunnerError::InternalServerError {
                message: "Failed to read wasm fuel".to_string(),
            }
        })?;
        let initialization_bonus = u64::MAX
            .saturating_sub(fuel_before_initialize)
            .min(FUEL_DEFAULT);
        store
            .set_fuel(fuel_before_initialize.saturating_add(initialization_bonus))
            .map_err(|e| {
                log::error!("failed to set initialization fuel: {e}");
                RunnerError::InternalServerError {
                    message: "Failed to configure wasm fuel".to_string(),
                }
            })?;

        linker.module(&mut store, "", &module).map_err(|e| {
            map_interrupt(e.into(), &blocking_timeout_message, |e| {
                RunnerError::InternalServerError {
                    message: format!("Failed to initialize module:\n{}", e.root_cause()),
                }
            })
        })?;

        let instance = linker.instantiate(&mut store, &module).map_err(|e| {
            map_interrupt(e.into(), &blocking_timeout_message, |e| {
                log::error!("{e:?}");
                RunnerError::InternalServerError {
                    message: format!("Failed to create instance:\n{}", e.root_cause()),
                }
            })
        })?;

        let fuel_after_initialize = store.get_fuel().map_err(|e| {
            log::error!("failed to get fuel after initialization: {e}");
            RunnerError::InternalServerError {
                message: "Failed to read wasm fuel".to_string(),
            }
        })?;
        store
            .set_fuel(restore_fuel_after_bonus(
                fuel_before_initialize,
                fuel_after_initialize,
                initialization_bonus,
            ))
            .map_err(|e| {
                log::error!("failed to restore fuel after initialization: {e}");
                RunnerError::InternalServerError {
                    message: "Failed to configure wasm fuel".to_string(),
                }
            })?;

        let result = input.call(&mut store, &instance);

        drop(store);

        let bytes = stdout.contents();
        let output = String::from_utf8_lossy(&bytes).to_string();

        match result {
            Ok((res, fuel)) => Ok((res, output, fuel)),
            Err(e) => Err(map_interrupt(e, &blocking_timeout_message, |e| {
                RunnerError::RuntimeError {
                    message: e.root_cause().to_string(),
                }
            })),
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
            let _ = handle.await;
            Err(timeout_error(&timeout_message))
        }
    }
}

pub(crate) fn timeout_error(message: &str) -> RunnerError {
    RunnerError::TimeoutError {
        message: message.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn shared_engine_respects_each_store_epoch_deadline() {
        let mut config = Config::default();
        config.epoch_interruption(true);
        let engine = Engine::new(&config).unwrap();
        let module = Module::new(&engine, "(module (func (export \"loop\") (loop br 0)))").unwrap();
        let (ready_a_tx, ready_a_rx) = tokio::sync::oneshot::channel();
        let (ready_b_tx, ready_b_rx) = tokio::sync::oneshot::channel();

        let spawn_loop = |deadline, ready_tx: tokio::sync::oneshot::Sender<()>| {
            let engine = engine.clone();
            let module = module.clone();
            task::spawn_blocking(move || {
                let mut store = Store::new(&engine, ());
                store.set_epoch_deadline(deadline);
                store.epoch_deadline_trap();
                let instance = wasmtime::Instance::new(&mut store, &module, &[]).unwrap();
                let loop_fn = instance
                    .get_typed_func::<(), ()>(&mut store, "loop")
                    .unwrap();
                ready_tx.send(()).unwrap();
                loop_fn.call(&mut store, ())
            })
        };

        let a = spawn_loop(1, ready_a_tx);
        let mut b = spawn_loop(3, ready_b_tx);
        tokio::time::timeout(Duration::from_secs(2), async {
            ready_a_rx.await.unwrap();
            ready_b_rx.await.unwrap();
        })
        .await
        .expect("loop tasks did not become ready");

        engine.increment_epoch();
        let a_result = tokio::time::timeout(Duration::from_secs(2), a)
            .await
            .expect("first store did not trap")
            .unwrap();
        assert_eq!(
            a_result.unwrap_err().downcast_ref::<wasmtime::Trap>(),
            Some(&wasmtime::Trap::Interrupt)
        );
        assert!(tokio::time::timeout(Duration::from_millis(50), &mut b)
            .await
            .is_err());

        engine.increment_epoch();
        engine.increment_epoch();
        let b_result = tokio::time::timeout(Duration::from_secs(2), b)
            .await
            .expect("second store did not trap")
            .unwrap();
        assert_eq!(
            b_result.unwrap_err().downcast_ref::<wasmtime::Trap>(),
            Some(&wasmtime::Trap::Interrupt)
        );
    }
    #[test]
    fn epoch_ticks_include_phase_safety_tick() {
        let now = tokio::time::Instant::now();
        assert_eq!(epoch_ticks_until(now, now, EPOCH_PERIOD), 1);
        assert_eq!(epoch_ticks_until(now + EPOCH_PERIOD, now, EPOCH_PERIOD), 2);
        assert_eq!(
            epoch_ticks_until(
                now + EPOCH_PERIOD * 2 + Duration::from_millis(1),
                now,
                EPOCH_PERIOD
            ),
            4
        );
    }

    #[test]
    fn bounded_reader_rejects_bytes_over_limit() {
        assert_eq!(read_bounded(&b"12345678"[..], 8).unwrap(), b"12345678");
        assert_eq!(
            read_bounded(&b"123456789"[..], 8).unwrap_err().kind(),
            std::io::ErrorKind::InvalidData
        );
    }

    #[test]
    fn fuel_values_are_clamped_before_conversion() {
        assert_eq!(clamp_fuel(Some(-1)), 0);
        assert_eq!(clamp_fuel(Some(MAX_FUEL + 1)), MAX_FUEL as u64);
        assert_eq!(clamp_fuel(None), MAX_FUEL as u64);
    }

    #[test]
    fn restoring_bonus_preserves_fuel_at_overflow_boundary() {
        assert_eq!(
            restore_fuel_after_bonus(u64::MAX - 5, u64::MAX - 2, 100),
            u64::MAX - 5
        );
    }

    #[test]
    fn interrupt_traps_are_timeout_errors() {
        assert!(is_interrupt(&wasmtime::Trap::Interrupt.into()));
    }
}
