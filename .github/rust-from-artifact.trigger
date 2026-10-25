# rustios: push a change to this file to build the Rust half of the toolchain
# from an already produced SwiftLLVM artifact, without re-running the Swift
# job (see .github/workflows/build-rust-from-artifact.yml).
#
# Put a run id below to use that run's `swift-llvm` artifact, or remove it to
# use the newest non-expired one in this repository.
40019585601
# (the codegen-tests fix re-runs the Rust half against the same artifact)
# (optimized-compiler-builtins = false)
# (PGOOptions patch applied)
# (libc++ patch for aarch64-apple-ios)
# (static xcframework: link the driver from bootstrap deps)
# (capture the static-driver link error)
# (static xcframework: also search the host deps dir)
# (report: post the body, and record what the xcframework is)
