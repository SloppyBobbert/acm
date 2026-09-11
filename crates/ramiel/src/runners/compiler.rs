use shared::models::runner::RunnerError;
use std::{io, process::Stdio};
use tokio::process::Command;

const SANDBOX: &str = "/usr/local/libexec/acm-compiler-sandbox";

/// Refuse startup unless the native helper proves kernel filesystem enforcement.
pub fn initialize() -> io::Result<()> {
    let output = std::process::Command::new(SANDBOX)
        .arg("--check")
        .env_clear()
        .stdin(Stdio::null())
        .output()
        .map_err(|error| {
            io::Error::new(
                error.kind(),
                format!("Cannot start compiler filesystem isolation: {error}"),
            )
        })?;
    if !output.status.success() {
        return Err(io::Error::other("Compiler filesystem isolation is unavailable. Native Linux amd64 with Landlock ABI 3 or newer is required. Unrestricted compilation is disabled."));
    }
    Ok(())
}

pub(super) fn isolation_error() -> RunnerError {
    RunnerError::InternalServerError {
        message: "Compiler filesystem isolation could not be enforced. Compilation is disabled."
            .into(),
    }
}

pub(super) fn command(compiler: &str) -> Command {
    let mut command = Command::new(SANDBOX);
    command.arg(compiler).env_clear();
    command
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn compilation_without_a_valid_isolated_directory_fails_closed() {
        for compiler in [
            "/opt/wasi-sdk/bin/clang++",
            "/opt/submission-rust/bin/rustc",
        ] {
            // Either the helper is absent on this test host, or it rejects '/'.
            // Neither case may fall back to the compiler without isolation.
            if let Ok(output) = command(compiler).current_dir("/").output().await {
                assert!(!output.status.success());
            }
        }
    }
}
