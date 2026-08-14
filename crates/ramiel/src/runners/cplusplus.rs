use async_trait::async_trait;
use shared::models::{
    forms::{CustomInputJob, GenerateTestsJob, SubmitJob},
    runner::{CustomInputResponse, Diagnostic, DiagnosticType, RunnerError, RunnerResponse},
    test::Test,
};
use std::{
    collections::HashMap,
    io,
    iter::Peekable,
    path::{Path, PathBuf},
    process::Stdio,
    str::Chars,
    sync::{Arc, Mutex, Weak},
};
use tokio::{
    fs::{self, File},
    io::{AsyncReadExt, AsyncWriteExt},
    process::{Child, Command},
};

use super::{run_command, run_test_timed, timeout_error, Runner, TestResults, WasmRuntime};

const CACHE_VERSION: &str = "clang++-wasi-v1";

#[derive(Clone)]
pub struct CPlusPlus {
    runtime: Arc<WasmRuntime>,
    prefix_locks: PrefixLocks,
}

impl CPlusPlus {
    pub fn new(runtime: Arc<WasmRuntime>) -> Self {
        Self {
            runtime,
            prefix_locks: PrefixLocks::default(),
        }
    }
}

#[derive(Clone, Default)]
struct PrefixLocks(Arc<Mutex<HashMap<PathBuf, Weak<tokio::sync::Mutex<()>>>>>);

impl PrefixLocks {
    async fn acquire(
        &self,
        prefix: PathBuf,
        deadline: tokio::time::Instant,
        timeout_message: &str,
    ) -> Result<tokio::sync::OwnedMutexGuard<()>, RunnerError> {
        if tokio::time::Instant::now() >= deadline {
            return Err(timeout_error(timeout_message));
        }
        let lock = {
            let mut locks = self.0.lock().expect("prefix lock map poisoned");
            locks.retain(|_, lock| lock.strong_count() > 0);
            if let Some(lock) = locks.get(&prefix).and_then(Weak::upgrade) {
                lock
            } else {
                let lock = Arc::new(tokio::sync::Mutex::new(()));
                locks.insert(prefix, Arc::downgrade(&lock));
                lock
            }
        };
        tokio::select! {
            biased;
            guard = lock.lock_owned() => Ok(guard),
            _ = tokio::time::sleep_until(deadline) => Err(timeout_error(timeout_message)),
        }
    }
}

#[async_trait]
impl Runner for CPlusPlus {
    async fn run_tests(
        &self,
        form: SubmitJob,
        deadline: tokio::time::Instant,
        timeout_message: &str,
    ) -> Result<RunnerResponse, RunnerError> {
        let prefix = PathBuf::from(format!(
            "/tmp/acm/submissions/{}/{}",
            form.user_id, form.problem_id
        ));
        let _guard = self
            .prefix_locks
            .acquire(prefix.clone(), deadline, timeout_message)
            .await?;

        let implementation = process_file(&form.implementation);

        let command = compile_problem(&prefix, &implementation, deadline, timeout_message).await?;

        // MAYBE WHEN WE HAVE MORE RAM
        // let tests = join_all(
        //     form.tests
        //         .into_iter()
        //         .map(|test| async { run_test_timed(&command, test).await }),
        // )
        // .await;

        // SAD SOLUTION FOR NOW
        let mut tests = vec![];
        for mut test in form.tests {
            test.adjust_runtime(form.runtime_multiplier);
            let (test, _) = run_test_timed(
                self.runtime.clone(),
                &command,
                test,
                50,
                deadline,
                timeout_message,
            )
            .await?;
            tests.push(test);
        }

        let mut total_runtime = 0;

        let mut test_results = TestResults::new();

        for test in tests {
            total_runtime += test.fuel;
            test_results.insert(test);
        }

        test_results.runtime = total_runtime;

        Ok(test_results.into())
    }

    async fn generate_tests(
        &self,
        form: GenerateTestsJob,
        deadline: tokio::time::Instant,
        timeout_message: &str,
    ) -> Result<Vec<Test>, RunnerError> {
        let prefix = PathBuf::from(format!("/tmp/acm/problem_editor/{}", form.user_id));
        let _guard = self
            .prefix_locks
            .acquire(prefix.clone(), deadline, timeout_message)
            .await?;

        // TODO actually get unique function names from tests
        let reference = process_file(&form.reference);
        let command = compile_problem(&prefix, &reference, deadline, timeout_message).await?;

        let mut outputs = Vec::new();
        let mut i = 0;
        for input in form.inputs.into_iter() {
            let (output, _, fuel) = run_command(
                self.runtime.clone(),
                &command,
                input.clone(),
                None,
                deadline,
                timeout_message,
            )
            .await?;
            outputs.push(Test {
                id: 0,
                index: i,
                max_fuel: Some(fuel as i64),
                input,
                expected_output: output,
            });

            i += 1;
        }

        Ok(outputs)
    }

    async fn run_custom_input(
        &self,
        form: CustomInputJob,
        deadline: tokio::time::Instant,
        timeout_message: &str,
    ) -> Result<CustomInputResponse, RunnerError> {
        let reference_prefix = PathBuf::from(format!(
            "/tmp/acm/custom_input/{}/{}/reference",
            form.user_id, form.problem_id
        ));
        let implementation_prefix = PathBuf::from(format!(
            "/tmp/acm/custom_input/{}/{}/implementation",
            form.user_id, form.problem_id
        ));
        let mut prefixes = vec![reference_prefix.clone(), implementation_prefix.clone()];
        prefixes.sort();
        prefixes.dedup();
        let mut _guards = Vec::with_capacity(prefixes.len());
        for prefix in prefixes {
            _guards.push(
                self.prefix_locks
                    .acquire(prefix, deadline, timeout_message)
                    .await?,
            );
        }

        let reference = process_file(&form.reference);
        let implementation = process_file(&form.implementation);

        // println!("REFERENCE: {reference}");
        // println!("IMPLEMENTATION: {implementation}");

        let reference_command =
            compile_problem(&reference_prefix, &reference, deadline, timeout_message).await?;
        let implementation_command = compile_problem(
            &implementation_prefix,
            &implementation,
            deadline,
            timeout_message,
        )
        .await?;

        let (expected_output, _, fuel) = run_command(
            self.runtime.clone(),
            &reference_command,
            form.input.clone(),
            None,
            deadline,
            timeout_message,
        )
        .await?;

        let mut test = Test {
            id: 0,
            index: 0,
            input: form.input,
            expected_output,
            max_fuel: Some(fuel as i64),
        };

        test.adjust_runtime(form.runtime_multiplier);

        // we add a lot of padding so they can potentially print a lot
        let (test_result, stdout) = run_test_timed(
            self.runtime.clone(),
            &implementation_command,
            test,
            500,
            deadline,
            timeout_message,
        )
        .await?;

        Ok(CustomInputResponse {
            result: test_result,
            output: stdout,
        })
    }
}

fn process_file(file: &str) -> String {
    let bits_cpp = include_str!("default_header.h");

    let mut new_file = String::new();

    // include headers automatically
    new_file.push_str(bits_cpp);
    new_file.push_str(&file);

    new_file
}

async fn compile_problem(
    prefix: &Path,
    implementation: &str,
    deadline: tokio::time::Instant,
    timeout_message: &str,
) -> Result<String, RunnerError> {
    if tokio::time::Instant::now() >= deadline {
        return Err(timeout_error(timeout_message));
    }

    let wasm_filename = prefix.join("out.wasm");
    let implementation_filename = prefix.join("implementation.cpp");
    let marker_filename = prefix.join(".compile-cache-key");
    let cache_key = CACHE_VERSION;

    if cache_matches(
        &implementation_filename,
        &wasm_filename,
        &marker_filename,
        implementation,
        &cache_key,
    )
    .await?
    {
        return Ok(wasm_filename.to_string_lossy().into_owned());
    }

    if tokio::time::Instant::now() >= deadline {
        return Err(timeout_error(timeout_message));
    }
    fs::create_dir_all(prefix).await?;

    remove_file_checked(&marker_filename).await?;
    remove_file_checked(&wasm_filename).await?;

    if tokio::time::Instant::now() >= deadline {
        return Err(timeout_error(timeout_message));
    }
    File::create(&implementation_filename)
        .await?
        .write_all(implementation.as_bytes())
        .await?;

    if tokio::time::Instant::now() >= deadline {
        return Err(timeout_error(timeout_message));
    }

    let mut command = Command::new("/opt/wasi-sdk/bin/clang++");
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .args([
            "-O3",
            "-Wl,--no-entry",
            "-Wl,--demangle",
            "-Wl,--export-all",
            "-mexec-model=reactor",
            "-msimd128",
            "-Wall",
            "-Wextra",
            "-Wpedantic",
            "-Werror=return-type",
            "-fno-caret-diagnostics",
            "-fno-exceptions",
            "-std=c++20",
            implementation_filename.to_str().expect("UTF-8 path"),
            "-o",
            wasm_filename.to_str().expect("UTF-8 path"),
        ]);
    #[cfg(unix)]
    command.process_group(0);
    let mut child = command.spawn()?;
    let pgid = child.id().expect("spawned child must have a pid") as i32;
    let output = match wait_for_child(&mut child, pgid, deadline).await? {
        Some(output) => output,
        None => {
            invalidate_compile_outputs(&marker_filename, &wasm_filename).await;
            return Err(timeout_error(timeout_message));
        }
    };

    if !output.status.success() {
        invalidate_compile_outputs(&marker_filename, &wasm_filename).await;

        return Err(parse_cplusplus_error(
            String::from_utf8_lossy(&output.stderr).to_string(),
        ));
    }

    if let Err(error) = fs::write(&marker_filename, cache_key).await {
        invalidate_compile_outputs(&marker_filename, &wasm_filename).await;
        return Err(error.into());
    }

    Ok(wasm_filename.to_string_lossy().into_owned())
}

async fn cache_matches(
    implementation_path: &Path,
    wasm_path: &Path,
    marker_path: &Path,
    implementation: &str,
    cache_key: &str,
) -> io::Result<bool> {
    if !wasm_path.exists() {
        return Ok(false);
    }
    let source = match fs::read(implementation_path).await {
        Ok(source) => source,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error),
    };
    let marker = match fs::read_to_string(marker_path).await {
        Ok(marker) => marker,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error),
    };
    Ok(source == implementation.as_bytes() && marker == cache_key)
}

struct ChildOutput {
    status: std::process::ExitStatus,
    stderr: Vec<u8>,
}

async fn wait_for_child(
    child: &mut Child,
    pgid: i32,
    deadline: tokio::time::Instant,
) -> std::io::Result<Option<ChildOutput>> {
    let mut stderr = child.stderr.take().expect("stderr must be piped");
    let mut output = Vec::new();

    let completed = {
        let wait_and_drain = async {
            let (status, _) = tokio::try_join!(child.wait(), stderr.read_to_end(&mut output))?;
            Ok::<_, std::io::Error>(status)
        };
        tokio::pin!(wait_and_drain);
        tokio::select! {
            biased;
            result = &mut wait_and_drain => Some(result?),
            _ = tokio::time::sleep_until(deadline) => None,
        }
    };

    if let Some(status) = completed {
        return Ok(Some(ChildOutput {
            status,
            stderr: output,
        }));
    }

    drop(stderr);
    #[cfg(unix)]
    {
        let result = unsafe { libc::kill(-pgid, libc::SIGKILL) };
        if result != 0 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ESRCH) {
                let _ = child.start_kill();
            }
        }
    }
    #[cfg(not(unix))]
    {
        let _ = child.start_kill();
    }
    child.wait().await?;
    Ok(None)
}

async fn remove_file_checked(path: &Path) -> io::Result<()> {
    match fs::remove_file(path).await {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

async fn invalidate_compile_outputs(marker: &Path, wasm: &Path) {
    let _ = fs::remove_file(marker).await;
    let _ = fs::remove_file(wasm).await;
}

fn parse_number(iter: &mut Peekable<Chars>) -> usize {
    let mut num = 0;

    while let Some(c) = iter.next() {
        if let Some(d) = c.to_digit(10) {
            num = num * 10 + d as usize;
        } else {
            break;
        }
    }

    num
}

/// Returns `None` if the diagnostic is not in the "implementation.cpp" file
///
/// Example format (except we don't actually do the brackets thus far):
/// /tmp/acm/submissions/1/41/implementation.cpp:50:12:{50:16-50:17}: error: no viable conversion from 'int' to 'std::string' (aka 'basic_string<char, char_traits<char>, allocator<char>>')
fn diagnostic_from_str(s: &str) -> Result<Option<Diagnostic>, RunnerError> {
    if s.find(".cpp").is_none() || !s.starts_with("/") {
        return Ok(None);
    }

    let mut iter = s.chars().peekable();

    // go until we find the first colon
    while let Some(c) = iter.next() {
        if c == ':' {
            break;
        }
    }

    // this number comes from the length of the "default_header.h" file
    let mut line = parse_number(&mut iter);
    if line < 39 {
        return Ok(None);
    }

    line -= 39;

    let col = parse_number(&mut iter);

    iter.next();

    let mut error_type = String::new();

    while let Some(c) = iter.next() {
        if c == ':' {
            break;
        }

        error_type.push(c);
    }

    iter.next();

    let diagnostic_type = match error_type.as_str() {
        "error" => DiagnosticType::Error,
        "warning" => DiagnosticType::Warning,
        _ => DiagnosticType::Note,
    };

    let message = iter.collect();

    Ok(Some(Diagnostic {
        line,
        col,
        message,
        diagnostic_type,
    }))
}

fn parse_cplusplus_error(err: String) -> RunnerError {
    let mut diagnostics = vec![];

    println!("{err}");

    for line in err.lines() {
        match diagnostic_from_str(&line) {
            Ok(Some(diagnostic)) => diagnostics.push(diagnostic),
            Ok(None) => {}
            Err(e) => {
                return e;
            }
        }
    }

    RunnerError::CompilationError { diagnostics }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    #[tokio::test]
    async fn invalidating_compile_cache_removes_source_and_module() {
        let directory = std::env::temp_dir().join(format!(
            "ramiel-cache-invalidation-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&directory).await.unwrap();
        let implementation = directory.join("implementation.cpp");
        let wasm = directory.join("out.wasm");
        fs::write(&implementation, "int main() {}\n").await.unwrap();
        fs::write(&wasm, b"wasm").await.unwrap();

        invalidate_compile_outputs(&implementation, &wasm).await;

        assert!(fs::metadata(&implementation).await.is_err());
        assert!(fs::metadata(&wasm).await.is_err());
        fs::remove_dir(directory).await.unwrap();
    }

    #[tokio::test]
    async fn compile_failure_after_source_replacement_removes_stale_module() {
        let directory = std::env::temp_dir().join(format!(
            "ramiel-stale-module-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&directory).await.unwrap();
        let implementation = directory.join("implementation.cpp");
        let wasm = directory.join("out.wasm");
        fs::write(&implementation, "old source").await.unwrap();
        fs::write(&wasm, b"stale wasm").await.unwrap();

        let result = compile_problem(
            &directory,
            "new source",
            tokio::time::Instant::now() + Duration::from_secs(1),
            "timed out",
        )
        .await;

        assert!(result.is_err());
        assert!(fs::metadata(&wasm).await.is_err());
        fs::remove_dir_all(directory).await.unwrap();
    }

    #[tokio::test]
    async fn cache_marker_must_match_source_key() {
        let directory = std::env::temp_dir().join(format!(
            "ramiel-cache-marker-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&directory).await.unwrap();
        let source = directory.join("implementation.cpp");
        let wasm = directory.join("out.wasm");
        let marker = directory.join(".compile-cache-key");
        let implementation = "processed source";
        let key = CACHE_VERSION;
        fs::write(&source, implementation).await.unwrap();
        fs::write(&wasm, b"wasm").await.unwrap();

        assert!(
            !cache_matches(&source, &wasm, &marker, implementation, &key)
                .await
                .unwrap()
        );
        fs::write(&marker, "wrong key").await.unwrap();
        assert!(
            !cache_matches(&source, &wasm, &marker, implementation, &key)
                .await
                .unwrap()
        );
        fs::write(&marker, &key).await.unwrap();
        assert!(cache_matches(&source, &wasm, &marker, implementation, &key)
            .await
            .unwrap());
        fs::remove_dir_all(directory).await.unwrap();
    }

    #[tokio::test]
    async fn prefix_lock_deadline_returns_timeout_error() {
        let locks = PrefixLocks::default();
        let prefix = PathBuf::from("/tmp/ramiel-prefix-lock-timeout");
        let guard = locks
            .acquire(
                prefix.clone(),
                tokio::time::Instant::now() + Duration::from_secs(1),
                "timed out",
            )
            .await
            .unwrap();
        let error = locks
            .acquire(prefix, tokio::time::Instant::now(), "timed out")
            .await
            .unwrap_err();
        assert!(matches!(error, RunnerError::TimeoutError { .. }));
        drop(guard);
    }

    #[tokio::test]
    async fn failed_output_removal_leaves_existing_source_unchanged() {
        let directory = std::env::temp_dir().join(format!(
            "ramiel-output-removal-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(directory.join("out.wasm"))
            .await
            .unwrap();
        let source = directory.join("implementation.cpp");
        fs::write(&source, "old source").await.unwrap();

        let result = compile_problem(
            &directory,
            "new source",
            tokio::time::Instant::now() + Duration::from_secs(1),
            "timed out",
        )
        .await;

        assert!(result.is_err());
        assert_eq!(fs::read_to_string(&source).await.unwrap(), "old source");
        fs::remove_dir_all(directory).await.unwrap();
    }

    #[tokio::test]
    async fn different_prefix_locks_do_not_serialize() {
        let locks = PrefixLocks::default();
        let guard = locks
            .acquire(
                PathBuf::from("/tmp/ramiel-prefix-a"),
                tokio::time::Instant::now() + Duration::from_secs(1),
                "timed out",
            )
            .await
            .unwrap();
        let other = locks.acquire(
            PathBuf::from("/tmp/ramiel-prefix-b"),
            tokio::time::Instant::now() + Duration::from_secs(1),
            "timed out",
        );
        assert!(tokio::time::timeout(Duration::from_secs(1), other)
            .await
            .unwrap()
            .is_ok());
        drop(guard);
    }

    #[tokio::test]
    async fn same_prefix_lock_is_held_until_consumption_finishes() {
        let locks = PrefixLocks::default();
        let prefix = PathBuf::from("/tmp/ramiel-prefix-serialized");
        let (a_ready_tx, a_ready_rx) = tokio::sync::oneshot::channel();
        let (release_a_tx, release_a_rx) = tokio::sync::oneshot::channel();
        let (b_started_tx, b_started_rx) = tokio::sync::oneshot::channel();
        let (b_acquired_tx, mut b_acquired_rx) = tokio::sync::oneshot::channel();

        let locks_a = locks.clone();
        let prefix_a = prefix.clone();
        let a = tokio::spawn(async move {
            let _guard = locks_a
                .acquire(
                    prefix_a,
                    tokio::time::Instant::now() + Duration::from_secs(2),
                    "timed out",
                )
                .await
                .unwrap();
            a_ready_tx.send(()).unwrap();
            release_a_rx.await.unwrap();
        });

        tokio::time::timeout(Duration::from_secs(1), a_ready_rx)
            .await
            .expect("first task did not acquire its prefix lock")
            .unwrap();
        let locks_b = locks.clone();
        let b = tokio::spawn(async move {
            b_started_tx.send(()).unwrap();
            let _guard = locks_b
                .acquire(
                    prefix,
                    tokio::time::Instant::now() + Duration::from_secs(2),
                    "timed out",
                )
                .await
                .unwrap();
            b_acquired_tx.send(()).unwrap();
        });

        tokio::time::timeout(Duration::from_secs(1), b_started_rx)
            .await
            .expect("second task did not start")
            .unwrap();
        tokio::task::yield_now().await;
        assert!(b_acquired_rx.try_recv().is_err());

        release_a_tx.send(()).unwrap();
        tokio::time::timeout(Duration::from_secs(1), &mut b_acquired_rx)
            .await
            .expect("second task did not acquire after release")
            .unwrap();
        tokio::time::timeout(Duration::from_secs(1), a)
            .await
            .expect("first task did not finish")
            .unwrap();
        tokio::time::timeout(Duration::from_secs(1), b)
            .await
            .expect("second task did not finish")
            .unwrap();
    }

    #[tokio::test]
    async fn subprocess_helper_collects_stderr_after_normal_completion() {
        let mut command = Command::new("sh");
        command.args(["-c", "printf diagnostic >&2"]);
        command.stderr(Stdio::piped()).kill_on_drop(true);
        #[cfg(unix)]
        command.process_group(0);
        let mut child = command.spawn().unwrap();
        let pgid = child.id().unwrap() as i32;

        let output = wait_for_child(
            &mut child,
            pgid,
            tokio::time::Instant::now() + Duration::from_secs(1),
        )
        .await
        .unwrap()
        .unwrap();

        assert!(output.status.success());
        assert_eq!(output.stderr, b"diagnostic");
    }

    #[tokio::test]
    async fn subprocess_helper_reaps_timed_out_child_before_returning() {
        let marker_path = std::env::temp_dir().join(format!(
            "ramiel-timeout-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let descendant_pid_path = format!("{}.child-pid", marker_path.display());
        let script = format!(
            "(printf ready > '{marker}'; while :; do :; done) & child=$!; printf %s $child > '{child_pid}'; while :; do :; done",
            marker = marker_path.display(), child_pid = descendant_pid_path,
        );
        let mut command = Command::new("sh");
        command.args(["-c", &script]);
        command.stderr(Stdio::piped()).kill_on_drop(true);
        #[cfg(unix)]
        command.process_group(0);
        let mut child = command.spawn().unwrap();
        let pgid = child.id().unwrap() as i32;

        let descendant_pid: i32 = tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if tokio::fs::metadata(&marker_path).await.is_ok() {
                    if let Ok(pid) = tokio::fs::read_to_string(&descendant_pid_path).await {
                        if let Ok(pid) = pid.trim().parse::<i32>() {
                            return pid;
                        }
                    }
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("child process did not create readiness files");
        assert!(tokio::time::timeout(
            Duration::from_secs(2),
            wait_for_child(&mut child, pgid, tokio::time::Instant::now())
        )
        .await
        .unwrap()
        .unwrap()
        .is_none());
        assert!(child.try_wait().unwrap().is_some());
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if unsafe { libc::kill(descendant_pid, 0) } == -1 {
                    match std::io::Error::last_os_error().raw_os_error() {
                        Some(libc::ESRCH) => return,
                        error => panic!("unexpected descendant kill error: {error:?}"),
                    }
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("descendant was not reaped");
        tokio::fs::remove_file(marker_path).await.unwrap();
        tokio::fs::remove_file(descendant_pid_path).await.unwrap();
    }

    #[tokio::test]
    async fn subprocess_helper_prefers_completed_child_over_expired_deadline() {
        let mut command = Command::new("sh");
        command.args(["-c", "exit 0"]);
        command.stderr(Stdio::piped()).kill_on_drop(true);
        #[cfg(unix)]
        command.process_group(0);
        let mut child = command.spawn().unwrap();
        let pgid = child.id().unwrap() as i32;
        child.wait().await.unwrap();

        let output = wait_for_child(&mut child, pgid, tokio::time::Instant::now())
            .await
            .unwrap()
            .unwrap();

        assert!(output.status.success());
    }
}
