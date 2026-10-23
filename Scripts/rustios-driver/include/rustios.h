/*
 * rustios.h - C interface of the Rust compiler embedded in Rust.xcframework.
 *
 * The Rust compiler is exposed as a small, synchronous C API. Arguments use
 * the same conventions as the `rustc` command line, except that argv[0] is
 * the program name (as with `main()`).
 *
 * Example:
 *
 *     #include <rustios.h>
 *     #include <stdio.h>
 *
 *     int main(void) {
 *         const char *argv[] = {
 *             "rustc",
 *             "--edition", "2021",
 *             "-C", "opt-level=2",
 *             "--emit=obj",
 *             "hello.rs",
 *             "-o", "hello.o",
 *         };
 *         int rc = rustios_run((int)(sizeof(argv) / sizeof(argv[0])), argv);
 *         printf("rustc exited with %d (version %s)\n", rc, rustios_version());
 *         return rc;
 *     }
 *
 * The library is dynamic: rustc is only available as a dylib ("rustc_driver"
 * is a dylib crate upstream), so the framework slice contains three dylibs
 * that all have to be embedded in the app and signed:
 *
 *     Rust.xcframework/ios-arm64/libRustCompiler.dylib    <- this API
 *     Rust.xcframework/ios-arm64/librustc_driver-*.dylib  <- the compiler
 *     Rust.xcframework/ios-arm64/libstd-*.dylib           <- its runtime
 *
 * Linking by hand:
 *
 *     clang main.c -IRust.xcframework/ios-arm64/Headers \
 *           -LRust.xcframework/ios-arm64 -lRustCompiler \
 *           -Wl,-rpath,@executable_path/Frameworks
 *
 * In Xcode, add the three dylibs to a "Copy Files" phase that writes into
 * "Frameworks" and enable "Code Sign On Copy" (or use "Embed & Sign"); the
 * rpath above is where iOS looks by default.
 */
#ifndef RUSTIOS_H
#define RUSTIOS_H

#ifdef __cplusplus
extern "C" {
#endif

/* Compilation finished without errors. */
#define RUSTIOS_OK 0
/* Compilation failed; diagnostics were written to stderr. */
#define RUSTIOS_FAILED 1
/* argc/argv were invalid (NULL, empty, or not valid UTF-8). */
#define RUSTIOS_INVALID_ARGS 2
/* The compiler panicked (internal compiler error). */
#define RUSTIOS_ICE 101

/*
 * Version of the embedded compiler, e.g. "1.99.1".
 *
 * The returned pointer refers to static storage and must not be freed.
 */
const char *rustios_version(void);

/*
 * Run the compiler.
 *
 * argc : number of entries in argv (must be > 0)
 * argv : NULL-terminated UTF-8 strings; argv[0] is the program name and is
 *        ignored by the compiler itself.
 *
 * Returns one of RUSTIOS_OK, RUSTIOS_FAILED, RUSTIOS_INVALID_ARGS or
 * RUSTIOS_ICE.
 *
 * The call is synchronous, is not re-entrant and must not be made from
 * multiple threads at the same time: rustc keeps global state.
 */
int rustios_run(int argc, const char *const *argv);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* RUSTIOS_H */
