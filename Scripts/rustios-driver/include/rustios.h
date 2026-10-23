/*
 * rustios.h - run rustc in-process, on iOS.
 *
 * This header is the public interface of Rust.xcframework, the Rust analogue
 * of LLVM-On-iOS' CoreCompiler framework. The static library is built from the
 * Rust compiler itself (librustc_driver) for aarch64-apple-ios.
 *
 * Typical use:
 *
 *     const char *argv[] = {
 *         "rustc",
 *         "--sysroot", sysroot_path,       // e.g. .../RustToolchain/usr
 *         "--edition", "2021",
 *         "-C", "opt-level=2",
 *         source_path,
 *         "-o", output_path,
 *         NULL,
 *     };
 *     if (rustios_run(9, argv) != 0) { ... }
 *
 * Link with: -lc++ -lSystem (the archive contains rustc + LLVM already).
 */

#ifndef RUSTIOS_H
#define RUSTIOS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Version of the embedded compiler (e.g. "1.99.1"). Static storage, do not
 * free. Never returns NULL. */
const char *rustios_version(void);

/* Run the compiler with rustc's command line interface.
 *
 * argc/argv follow the usual C conventions and are not modified.
 * argv[0] is the program name; pass "rustc".
 *
 * Returns 0 on success, 1 when the compilation failed (diagnostics have been
 * printed to stderr), 2 on invalid arguments and 101 if the compiler panicked
 * (ICE). The calling process is never exited.
 *
 * rustc needs a --sysroot that contains lib/rustlib/aarch64-apple-ios (the
 * RustToolchain/usr directory shipped next to this framework). */
int rustios_run(int argc, const char *const *argv);

#ifdef __cplusplus
}
#endif

#endif /* RUSTIOS_H */
