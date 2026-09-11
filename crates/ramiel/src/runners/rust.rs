use std::{
    path::{Path, PathBuf},
    process::Stdio,
    sync::Arc,
};

use async_trait::async_trait;
use shared::models::{
    forms::{CustomInputJob, GenerateTestsJob, SubmitJob},
    language::{Language, RustSignature},
    runner::{CustomInputResponse, Diagnostic, DiagnosticType, RunnerError, RunnerResponse},
    test::Test,
};
use tokio::fs;

use super::{
    cplusplus::{self, PrefixLocks},
    run_command, run_test_timed, timeout_error, Runner, TestResults, WasmRuntime,
};

#[derive(Clone)]
pub struct Rust {
    runtime: Arc<WasmRuntime>,
    locks: PrefixLocks,
}

impl Rust {
    pub fn new(runtime: Arc<WasmRuntime>) -> Self {
        Self {
            runtime,
            locks: PrefixLocks::default(),
        }
    }
}

#[async_trait]
impl Runner for Rust {
    async fn run_tests(
        &self,
        form: SubmitJob,
        deadline: tokio::time::Instant,
        timeout_message: &str,
    ) -> Result<RunnerResponse, RunnerError> {
        let signature = RustSignature::from_calls(form.tests.iter().map(|test| &test.input))?;
        let prefix = PathBuf::from(format!(
            "/tmp/acm/rust/submissions/{}/{}",
            form.user_id, form.problem_id
        ));
        let _guard = self
            .locks
            .acquire(prefix.clone(), deadline, timeout_message)
            .await?;
        let command = compile(
            &prefix,
            &form.implementation,
            &signature,
            deadline,
            timeout_message,
        )
        .await?;
        let mut results = TestResults::new();
        for mut test in form.tests {
            test.adjust_runtime(form.runtime_multiplier);
            test.max_fuel = Language::Rust.fuel_limit(test.max_fuel);
            let (result, _) = run_test_timed(
                self.runtime.clone(),
                &command,
                test,
                50,
                Language::Rust,
                deadline,
                timeout_message,
            )
            .await?;
            results.runtime += result.fuel;
            results.insert(result);
        }
        Ok(results.into())
    }

    async fn generate_tests(
        &self,
        _form: GenerateTestsJob,
        _deadline: tokio::time::Instant,
        _timeout_message: &str,
    ) -> Result<Vec<Test>, RunnerError> {
        Err(RunnerError::UnsupportedSignature {
            message: "Test generation uses C++ references, not Rust.".into(),
        })
    }

    async fn run_custom_input(
        &self,
        form: CustomInputJob,
        deadline: tokio::time::Instant,
        timeout_message: &str,
    ) -> Result<CustomInputResponse, RunnerError> {
        let signature = RustSignature::from_calls([&form.input])?;
        let prefix = PathBuf::from(format!(
            "/tmp/acm/rust/custom/{}/{}",
            form.user_id, form.problem_id
        ));
        let _guard = self
            .locks
            .acquire(prefix.clone(), deadline, timeout_message)
            .await?;
        let reference = cplusplus::compile_problem(
            &prefix.join("reference"),
            &cplusplus::process_file(&form.reference),
            deadline,
            timeout_message,
        )
        .await?;
        let command = compile(
            &prefix.join("implementation"),
            &form.implementation,
            &signature,
            deadline,
            timeout_message,
        )
        .await?;
        let (expected_output, _, fuel) = run_command(
            self.runtime.clone(),
            &reference,
            form.input.clone(),
            None,
            Language::Cpp,
            deadline,
            timeout_message,
        )
        .await?;
        let mut test = Test {
            id: 0,
            index: 0,
            max_fuel: Some(fuel as i64),
            input: form.input,
            expected_output,
        };
        test.adjust_runtime(form.runtime_multiplier);
        test.max_fuel = Language::Rust.fuel_limit(test.max_fuel);
        let (result, output) = run_test_timed(
            self.runtime.clone(),
            &command,
            test,
            500,
            Language::Rust,
            deadline,
            timeout_message,
        )
        .await?;
        Ok(CustomInputResponse { result, output })
    }
}

async fn compile(
    prefix: &Path,
    implementation: &str,
    signature: &RustSignature,
    deadline: tokio::time::Instant,
    timeout_message: &str,
) -> Result<String, RunnerError> {
    if tokio::time::Instant::now() >= deadline {
        return Err(timeout_error(timeout_message));
    }
    fs::create_dir_all(prefix).await?;
    let output = prefix.join("out.wasm");
    // Compile every Rust submission. No stale modules or cross-language cache keys.
    cplusplus::remove_file_checked(&output).await?;
    fs::write(prefix.join("implementation.rs"), implementation).await?;
    fs::write(prefix.join("wrapper.rs"), signature.wrapper()).await?;
    if tokio::time::Instant::now() >= deadline {
        return Err(timeout_error(timeout_message));
    }
    // Use native filesystem isolation; never invoke Cargo or inherit application secrets.
    let mut command = super::compiler::command("/opt/submission-rust/bin/rustc");
    command
        .current_dir(prefix)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .args([
            "--edition=2021",
            "--crate-name=acm_submission",
            "--crate-type=cdylib",
            "--target=wasm32-wasip1",
            "-Copt-level=3",
            "-Cpanic=abort",
            "--error-format=json",
            "wrapper.rs",
            "-o",
            "out.wasm",
        ]);
    #[cfg(unix)]
    command.process_group(0);
    let mut child = command.spawn()?;
    let pgid = child.id().ok_or_else(|| RunnerError::InternalServerError {
        message: "Rust compiler has no process ID".into(),
    })? as i32;
    let result = cplusplus::wait_for_child(&mut child, pgid, deadline).await;
    match result {
        Ok(Some(result)) if result.status.success() => Ok(output.to_string_lossy().into_owned()),
        other => {
            cplusplus::remove_file_checked(&output).await?;
            match other {
                Ok(Some(result)) if result.status.code() == Some(125) => {
                    Err(super::compiler::isolation_error())
                }
                Ok(Some(result)) => Err(diagnostics(&result.stderr, result.stderr_truncated)),
                Ok(None) => Err(timeout_error(timeout_message)),
                Err(error) => Err(error),
            }
        }
    }
}

fn diagnostics(stderr: &[u8], truncated: bool) -> RunnerError {
    let mut diagnostics = Vec::new();
    for line in String::from_utf8_lossy(stderr).lines() {
        let Ok(value) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        let Some(message) = value["message"].as_str() else {
            continue;
        };
        let span = value["spans"].as_array().and_then(|spans| {
            spans.iter().find(|span| {
                span["is_primary"] == true
                    && span["file_name"].as_str().is_some_and(|name| {
                        Path::new(name)
                            .file_name()
                            .is_some_and(|name| name == "implementation.rs")
                    })
            })
        });
        diagnostics.push(Diagnostic {
            line: span
                .and_then(|span| span["line_start"].as_u64())
                .unwrap_or(0) as usize,
            col: span
                .and_then(|span| span["column_start"].as_u64())
                .unwrap_or(0) as usize,
            diagnostic_type: match value["level"].as_str() {
                Some("warning") => DiagnosticType::Warning,
                Some("error" | "failure-note") => DiagnosticType::Error,
                _ => DiagnosticType::Note,
            },
            message: if span.is_some() {
                message.into()
            } else {
                format!("Compiler or generated wrapper: {message}")
            },
        });
    }
    if truncated {
        diagnostics.push(Diagnostic {
            line: 0,
            col: 0,
            diagnostic_type: DiagnosticType::Note,
            message:
                "Compiler diagnostics exceeded the 1 MiB limit. Additional output was omitted."
                    .into(),
        });
    }
    if diagnostics.is_empty() {
        diagnostics.push(Diagnostic {
            line: 0,
            col: 0,
            diagnostic_type: DiagnosticType::Error,
            message: "Rust compilation failed without a structured diagnostic.".into(),
        });
    }
    RunnerError::CompilationError { diagnostics }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rust_diagnostics_keep_source_coordinates_and_have_a_fallback() {
        let error = diagnostics(br#"{"message":"expected i32","level":"error","spans":[{"file_name":"implementation.rs","is_primary":true,"line_start":3,"column_start":8}]}"#, false);
        let RunnerError::CompilationError {
            diagnostics: values,
        } = error
        else {
            panic!()
        };
        assert_eq!(values[0].line, 3);
        assert_eq!(values[0].col, 8);
        assert_eq!(values[0].message, "expected i32");
        let RunnerError::CompilationError {
            diagnostics: values,
        } = diagnostics(b"linker failed", false)
        else {
            panic!()
        };
        assert!(!values.is_empty());
        let RunnerError::CompilationError { diagnostics: values } = diagnostics(br#"{"message":"missing function","level":"error","spans":[{"file_name":"wrapper.rs","is_primary":true,"line_start":3,"column_start":8}]}"#, true) else { panic!() };
        assert_eq!((values[0].line, values[0].col), (0, 0));
        assert!(values[0].message.contains("wrapper"));
        assert!(values.last().unwrap().message.contains("omitted"));
    }
}
