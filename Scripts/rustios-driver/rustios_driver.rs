//! rustios driver: exposes the Rust compiler through a small C ABI so that an
//! iOS app can embed `rustc` as a library.
//!
//! FALLBACK ONLY. `Rust.xcframework` ships the compiler as a static archive
//! (`libRustCompiler.a`, see `Scripts/build-rust-toolchain.sh`), and the C API
//! is compiled into `rustc_driver_impl` itself by
//! `patches/0003-rustc-1.94.0-rustios-c-api.patch`. A static archive carries no
//! crate metadata, so this file - which does `extern crate rustc_driver_impl` -
//! cannot be compiled against one: it fails with `E0463: can't find crate for
//! derive_where` in every search order, because the proc-macro dylibs it needs
//! only exist in the build machine's cargo directories.
//!
//! It is kept because it is the only way to get the C API when the tree does
//! not carry that patch, and `build_xcframework` still tries it in that case.
//! The interface is `include/rustios.h`; the in-crate implementation is the
//! `rustios_c_api` module of `rustc_driver_impl`.
//!
//! NOTE: this uses `rustc_private`, i.e. compiler internals that are not a
//! stable API. It is pinned to the Rust version recorded in `build-info.json`.
#![feature(rustc_private)]
#![allow(unused_extern_crates)]
#![deny(unsafe_op_in_unsafe_fn)]

extern crate rustc_driver_impl;

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::panic::{self, AssertUnwindSafe};
use std::sync::OnceLock;

use rustc_driver_impl::Callbacks;

/// Compilation finished without errors.
pub const RUSTIOS_OK: c_int = 0;
/// Compilation failed (diagnostics were emitted).
pub const RUSTIOS_FAILED: c_int = 1;
/// The arguments passed through the C API were invalid.
pub const RUSTIOS_INVALID_ARGS: c_int = 2;
/// rustc panicked (ICE); this must be treated as a compiler bug.
pub const RUSTIOS_ICE: c_int = 101;

/// The string `rustios_version()` returns.
///
/// `RUSTIOS_VERSION` is set by `build_xcframework` to what the stage-1
/// compiler prints for `rustc -V` minus the program name, e.g.
/// "1.94.0 (1f7f2d1 2026-01-15)". The in-crate implementation of the same API
/// returns `rustc_version_str()`, which is that string, so both agree.
const VERSION: &str = match (option_env!("RUSTIOS_VERSION"), option_env!("CARGO_PKG_VERSION")) {
    (Some(v), _) => v,
    (_, Some(v)) => v,
    _ => "unknown",
};

/// Default callbacks: compile exactly like the `rustc` binary does.
struct RustiosCallbacks;

impl Callbacks for RustiosCallbacks {}

fn version_cstr() -> &'static CStr {
    static VERSION_CSTR: OnceLock<CString> = OnceLock::new();
    VERSION_CSTR.get_or_init(|| {
        CString::new(VERSION).expect("rustios version contains a NUL byte")
    })
}

/// NUL-terminated version string of the embedded compiler.
///
/// The returned pointer is static and must not be freed.
#[unsafe(no_mangle)]
pub extern "C" fn rustios_version() -> *const c_char {
    version_cstr().as_ptr()
}

/// Run the compiler with a conventional `argv` (argv[0] is the program name).
///
/// Returns [`RUSTIOS_OK`] on success, [`RUSTIOS_FAILED`] when compilation
/// failed, [`RUSTIOS_INVALID_ARGS`] for a malformed argument vector and
/// [`RUSTIOS_ICE`] if the compiler panicked.
///
/// # Safety
///
/// `argv` must point to `argc` valid, NUL-terminated C strings; each of them
/// must stay alive for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rustios_run(argc: c_int, argv: *const *const c_char) -> c_int {
    if argc <= 0 || argv.is_null() {
        return RUSTIOS_INVALID_ARGS;
    }

    let mut args: Vec<String> = Vec::with_capacity(argc as usize);
    for i in 0..argc as usize {
        // SAFETY: the caller guarantees `argv[0..argc]` are valid pointers.
        let ptr = unsafe { *argv.add(i) };
        if ptr.is_null() {
            return RUSTIOS_INVALID_ARGS;
        }
        // SAFETY: non-null and NUL-terminated per the function contract.
        match unsafe { CStr::from_ptr(ptr) }.to_str() {
            Ok(arg) => args.push(arg.to_owned()),
            Err(_) => return RUSTIOS_INVALID_ARGS,
        }
    }

    run_args(&args)
}

fn run_args(args: &[String]) -> c_int {
    // `catch_fatal_errors` turns rustc's fatal-error unwinding into an `Err`,
    // which is how the compiler reports unsuccessful compilations. Panics
    // (ICE) are caught separately by `catch_unwind`.
    let result = panic::catch_unwind(AssertUnwindSafe(|| {
        rustc_driver_impl::catch_fatal_errors(|| {
            let mut callbacks = RustiosCallbacks;
            rustc_driver_impl::run_compiler(args, &mut callbacks);
        })
    }));

    match result {
        Ok(Ok(())) => RUSTIOS_OK,
        Ok(Err(_)) => RUSTIOS_FAILED,
        Err(_) => RUSTIOS_ICE,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_nul_terminated() {
        let v = version_cstr().to_str().unwrap();
        assert!(!v.is_empty());
    }

    #[test]
    fn rejects_empty_argv() {
        let rc = unsafe { rustios_run(0, std::ptr::null()) };
        assert_eq!(rc, RUSTIOS_INVALID_ARGS);
    }

    #[test]
    fn compiles_no_input() {
        // No input file: rustc reports an error but must not crash.
        let args = vec!["rustc".to_string()];
        assert_ne!(run_args(&args), RUSTIOS_ICE);
    }
}
