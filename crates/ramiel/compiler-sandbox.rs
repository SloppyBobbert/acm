// Standalone, statically linked helper for native Linux compilers.
// Emulation is unsupported: do not grant /proc access to accommodate it.
// No user code runs in this process before the restriction is installed.
#[cfg(target_os = "linux")]
mod linux {
    use std::{
        ffi::{c_int, c_long, c_void, OsString},
        fs::{self, OpenOptions},
        io,
        os::{
            fd::{AsRawFd, FromRawFd, OwnedFd},
            unix::{fs::OpenOptionsExt, process::CommandExt},
        },
        path::Path,
        process::Command,
    };

    // Linux UAPI numbers are the same on x86_64 and aarch64.
    const CREATE_RULESET: c_long = 444;
    const ADD_RULE: c_long = 445;
    const RESTRICT_SELF: c_long = 446;
    const EXECUTE: u64 = 1;
    const WRITE_FILE: u64 = 1 << 1;
    const READ_FILE: u64 = 1 << 2;
    const READ_DIR: u64 = 1 << 3;
    const TRUNCATE: u64 = 1 << 14;
    const IOCTL_DEV: u64 = 1 << 15;
    const READ_EXEC: u64 = READ_FILE | READ_DIR | EXECUTE;
    const WORK_FILES: u64 = READ_FILE | READ_DIR | WRITE_FILE | TRUNCATE
        | (1 << 4) | (1 << 5) // remove directories/files
        | (1 << 7) | (1 << 8) // make directories/regular files
        | (1 << 12) | (1 << 13); // symlinks and cross-directory rename

    extern "C" {
        fn syscall(number: c_long, ...) -> c_long;
        fn prctl(option: c_int, ...) -> c_int;
    }

    #[repr(C)]
    struct RulesetAttr {
        handled_access_fs: u64,
    }
    // The kernel UAPI explicitly packs this structure (12 bytes, not 16).
    #[repr(C, packed)]
    struct PathAttr {
        allowed_access: u64,
        parent_fd: c_int,
    }

    fn checked(value: c_long) -> io::Result<c_long> {
        if value < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(value)
        }
    }

    struct Ruleset {
        fd: OwnedFd,
        handled: u64,
    }
    impl Ruleset {
        fn new() -> io::Result<Self> {
            let abi = checked(unsafe {
                syscall(CREATE_RULESET, std::ptr::null::<c_void>(), 0usize, 1u32)
            })?;
            if abi < 3 {
                return Err(io::Error::new(
                    io::ErrorKind::Unsupported,
                    "Landlock ABI 3 or newer is required",
                ));
            }
            let handled = ((1 << 15) - 1) | if abi >= 5 { IOCTL_DEV } else { 0 };
            let attr = RulesetAttr {
                handled_access_fs: handled,
            };
            let fd = checked(unsafe {
                syscall(
                    CREATE_RULESET,
                    &attr,
                    std::mem::size_of::<RulesetAttr>(),
                    0u32,
                )
            })?;
            Ok(Self {
                fd: unsafe { OwnedFd::from_raw_fd(fd as c_int) },
                handled,
            })
        }

        fn allow(&self, path: &Path, access: u64, optional: bool) -> io::Result<()> {
            let file = match OpenOptions::new()
                .read(true)
                .custom_flags(0x200000)
                .open(path)
            {
                // O_PATH
                Ok(file) => file,
                Err(error) if optional && error.kind() == io::ErrorKind::NotFound => return Ok(()),
                Err(error) => return Err(error),
            };
            let attr = PathAttr {
                allowed_access: access & self.handled,
                parent_fd: file.as_raw_fd(),
            };
            checked(unsafe { syscall(ADD_RULE, self.fd.as_raw_fd(), 1u32, &attr, 0u32) })?;
            Ok(())
        }

        fn enforce(self) -> io::Result<()> {
            checked(unsafe { prctl(38, 1u64, 0u64, 0u64, 0u64) } as c_long)?; // PR_SET_NO_NEW_PRIVS
            checked(unsafe { syscall(RESTRICT_SELF, self.fd.as_raw_fd(), 0u32) })?;
            // Restrictions remain after this descriptor closes and across exec/fork.
            Ok(())
        }
    }

    pub fn run() -> io::Result<()> {
        let mut args = std::env::args_os().skip(1);
        let compiler = args
            .next()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "missing compiler"))?;
        let rules = Ruleset::new()?;
        if compiler == "--check" {
            rules.enforce()?;
            return match fs::read("/etc/passwd") {
                Err(error) if error.kind() == io::ErrorKind::PermissionDenied => Ok(()),
                _ => Err(io::Error::other("filesystem denial self-check failed")),
            };
        }
        if compiler != "/opt/wasi-sdk/bin/clang++" && compiler != "/opt/submission-rust/bin/rustc" {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "compiler is not allowed",
            ));
        }
        let work = std::env::current_dir()?.canonicalize()?;
        if !work.starts_with("/tmp/acm") || work == Path::new("/tmp/acm") {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "compiler directory is not allowed",
            ));
        }
        let temporary = work.join(".compiler-tmp");
        fs::create_dir_all(&temporary)?;
        rules.allow(&work, WORK_FILES, false)?;
        for path in [
            "/opt/wasi-sdk",
            "/opt/submission-rust",
            "/lib",
            "/lib64",
            "/usr/lib",
            "/usr/lib64",
        ] {
            rules.allow(Path::new(path), READ_EXEC, true)?;
        }
        rules.allow(Path::new("/etc/ld.so.cache"), READ_FILE, true)?;
        rules.allow(
            Path::new("/dev/null"),
            READ_FILE | WRITE_FILE | IOCTL_DEV,
            false,
        )?;
        for path in ["/dev/random", "/dev/urandom"] {
            rules.allow(Path::new(path), READ_FILE, true)?;
        }
        let args: Vec<OsString> = args.collect();
        rules.enforce()?;
        Err(Command::new(compiler)
            .args(args)
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("TMPDIR", temporary)
            .exec())
    }
}

fn main() {
    #[cfg(target_os = "linux")]
    let result = linux::run();
    #[cfg(not(target_os = "linux"))]
    let result: std::io::Result<()> = Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "Linux Landlock is required",
    ));
    if let Err(error) = result {
        eprintln!("Compiler filesystem isolation failed: {error}");
        std::process::exit(125);
    }
}
