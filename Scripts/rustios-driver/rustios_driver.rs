//! `Rust.xcframework` payload: the Rust compiler as a static library with a
//! small C ABI on top, so an iOS app can run rustc in-process (the Rust
//! equivalent of LLVM-On-iOS' `CoreCompiler`).
//!
//! Built by `Scripts/build-rust-toolchain.sh xcframework` with the freshly
//! produced stage-1 compiler, targeting `aarch64-apple-ios`.
//!
//! ```c
//! const char *argv[] = {
//!     "rustc",
//!     "--sysroot", "/path/to/RustToolchain/usr",
//!     "--edition", "2021",
//!     "/tmp/hello.rs",
//!     "-o", "/tmp/hello",
//!     NULL,
//! };
//! int rc = rustios_run(8, argv);   // 0 = success
//! ```
//!
//! NOTE: this file is compiled *inside* the rust-lang/rust source tree's
//! compiler world, hence the unstable `rustc_private` feature. It must be
//! compiled with the same compiler that produced `librustc_driver`.
#![feature(rustc_private)]

extern crate rustc_driver;

use std::ffi::{c_char, c_int, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};

/// Version string of the embedded compiler, e.g. `"1.99.1"`.
///
/// The string is NUL terminated and has static lifetime; do not free it.
#[unsafe(no_mangle)]
pub extern "C" fn rustios_version() -> *const c_char {
    // `RUSTIOS_VERSION` is injected by the build script.
    static VERSION: &str = concat!(env!("RUSTIOS_VERSION"), "\0");
    VERSION.as_ptr() as *const c_char
}

struct RustiosCallbacks;

impl rustc_driver::Callbacks for RustiosCallbacks {}

/// Run the compiler with rustc's command line interface.
///
/// `argv[0]` is the program name (ignored by the compiler, use `"rustc"`).
/// Returns `0` on success, `1` when the compilation failed and `101` when the
/// compiler panicked (ICE). The process is never terminated by this function.
///
/// # Safety
///
/// `argv` must point to `argc` valid NUL terminated C strings; both must stay
/// alive for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rustios_run(argc: c_int, argv: *const *const c_char) -> c_int {
    if argc <= 0 || argv.is_null() {
        return 2;
    }

    let mut args: Vec<String> = Vec::with_capacity(argc as usize);
    for i in 0..argc as isize {
        // SAFETY: the caller guarantees `argv` holds `argc` valid pointers.
        let ptr = unsafe { *argv.offset(i) };
        if ptr.is_null() {
            return 2;
        }
        // SAFETY: guaranteed by the caller, see above.
        match unsafe { CStr::from_ptr(ptr) }.to_str() {
            Ok(arg) => args.push(arg.to_owned()),
            Err(_) => return 2,
        }
    }

    if args[0].is_empty() {
        args[0] = "rustc".to_owned();
    }

    let result = catch_unwind(AssertUnwindSafe(|| {
        let mut callbacks = RustiosCallbacks;
        rustc_driver::catch_fatal_errors(|| {
            rustc_driver::run_compiler(&args, &mut callbacks);
        })
        .map(|_| 0)
        .unwrap_or(1)
    }));

    result.unwrap_or(101)
}
