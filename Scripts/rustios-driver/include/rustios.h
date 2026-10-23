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
 * The compiler is shipped as a static archive, like `llvm.a` in
 * LLVM-On-iOS' LLVM.xcframework:
 *
 *     Rust.xcframework/ios-arm64/libRustCompiler.a   <- rustc + this API
 *     Rust.xcframework/ios-arm64/Headers/rustios.h
 *
 * Link it into the app (the Rust standard library is part of the archive, so
 * only the iOS system libraries are needed):
 *
 *     clang main.c Rust.xcframework/ios-arm64/libRustCompiler.a \
 *           -IRust.xcframework/ios-arm64/Headers \
 *           -lc++ -lSystem -o app
 *
 * In Xcode, drag `libRustCompiler.a` into "Frameworks, Libraries, and
 * Embedded Content" (Do Not Embed) and add `-lc++ -lSystem` to the other
 * linker flags.
 *
 * The embedded compiler still needs a sysroot with the target's std and the
 * codegen backend at runtime: ship `RustSupportLibs/sysroot` and pass
 * `--sysroot=<...>` in the argument list.
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
 * Version of the embedded compiler, e.g. "1.94.0".
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
