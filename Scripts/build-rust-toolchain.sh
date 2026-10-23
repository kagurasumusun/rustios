#!/usr/bin/env bash
#
# rustios - build a Rust toolchain that runs on iOS.
#
# This is the rustios equivalent of emexlab/LLVM-On-iOS: it cross-compiles a
# compiler (rustc instead of clang/Swift) so that it executes on an arm64
# iPhone/iPad, and packages it into artifacts that can be installed on a
# device or embedded in an app.
#
# The heavy lifting is done by rust-lang/rust's own bootstrap (x.py) using a
# cross-compiling configuration:
#
#     build  = the macOS machine doing the work  (aarch64-apple-darwin)
#     host   = where the produced rustc runs     (aarch64-apple-ios)
#     target = what that rustc compiles for      (aarch64-apple-ios, iOS 16.0)
#
# Subcommands: fetch, configure, build, verify, package, support,
#              xcframework, all, clean, clean-all, info
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Configuration (all overridable from the environment)
# ---------------------------------------------------------------------------

# Rust release tag to build.
RUST_VERSION="${RUST_VERSION:-1.99.1}"

# Release channel of that tag (stable/beta/nightly/dev).
RUST_CHANNEL="${RUST_CHANNEL:-stable}"

# Deployment target, matching LLVM-On-iOS' OS_VER=16.0.
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-16.0}"

# Triple of the compiler we produce (host == target, like LLVM-On-iOS'
# arm64-apple-ios16.0 cross-compiler).
HOST_TRIPLE="${HOST_TRIPLE:-aarch64-apple-ios}"

# Bootstrap stage. Stage 2 is a proper, optimised, self-hosting toolchain.
STAGE="${STAGE:-2}"

# LLVM backends. rustc only compiles for HOST_TRIPLE, so AArch64 is enough.
LLVM_TARGETS="${LLVM_TARGETS:-AArch64}"

# Where things live.
RUST_SOURCE_DIR="${RUST_SOURCE_DIR:-${REPO_ROOT}/rust-source}"
BUILD_DIR="${BUILD_DIR:-${RUST_SOURCE_DIR}/build}"
WORK_DIR="${WORK_DIR:-${REPO_ROOT}/work}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-${REPO_ROOT}/artifacts}"

# Parallelism (empty = let x.py decide).
JOBS="${JOBS:-}"

# Package naming, mirroring LLVM-On-iOS' SwiftToolchain.zip / LLVM.xcframework.
PACKAGE_PREFIX="iphoneos-arm64"
TOOLCHAIN_NAME="RustToolchain"
SUPPORT_NAME="RustSupportLibs"
XCFRAMEWORK_NAME="Rust.xcframework"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_macos() {
    [[ "$(uname -s)" == "Darwin" ]] || die "this step requires macOS (Xcode + iPhoneOS SDK)"
}

detect_build_triple() {
    case "$(uname -m)" in
        arm64|aarch64) echo "aarch64-apple-darwin" ;;
        x86_64)        echo "x86_64-apple-darwin" ;;
        *)             die "unsupported build machine: $(uname -m)" ;;
    esac
}

BUILD_TRIPLE="${BUILD_TRIPLE:-$(detect_build_triple)}"

# Directory layout produced by bootstrap.
stage_dir()   { echo "${BUILD_DIR}/${HOST_TRIPLE}/stage${STAGE}"; }
llvm_dir()    { echo "${BUILD_DIR}/${HOST_TRIPLE}/llvm"; }
build_host_dir() { echo "${BUILD_DIR}/${BUILD_TRIPLE}/stage1"; }

# `shasum -a 256` writes "hash  path"; we run it from the artifacts dir so
# the manifest contains plain file names.
checksum() {
    local file="$1"
    mkdir -p "${ARTIFACTS_DIR}"
    ( cd "${ARTIFACTS_DIR}" && shasum -a 256 "$(basename "${file}")" >> SHA256SUMS.txt )
}

human_size() {
    du -h "$1" | awk '{print $1}'
}

# tar_xz <directory> <name> <output> : archive <name> (a direct child of
# <directory>) as <output>, with all cores used by xz.
tar_xz() {
    local dir="$1" name="$2" out="$3"
    mkdir -p "$(dirname "${out}")"
    rm -f "${out}"
    ( cd "${dir}" && XZ_OPT="-T0 -6" tar -cJf "${out}" "${name}" )
}

write_usage_doc() {
    local dest="$1"
    cat > "${dest}/USAGE.md" <<EOF
# ${TOOLCHAIN_NAME} for iOS

A Rust toolchain (rustc) built for **aarch64-apple-ios** with deployment
target **iOS ${IOS_DEPLOYMENT_TARGET}**, from Rust ${RUST_VERSION}
(${RUST_CHANNEL}).

This is the rustios counterpart of LLVM-On-iOS' Swift toolchain: the compiler
itself runs on the device.

## Install

\`\`\`sh
tar -xJf ${TOOLCHAIN_NAME}-${PACKAGE_PREFIX}-${RUST_VERSION}.tar.xz
# on the device / inside your app container:
export RUST_DIR="\$PWD/${TOOLCHAIN_NAME}/usr"
export PATH="\$RUST_DIR/bin:\$PATH"
\`\`\`

## Use

\`\`\`sh
rustc --version
rustc --edition 2021 -C opt-level=2 hello.rs -o hello
\`\`\`

\`rustc\` needs a Mach-O linker (\`ld\`/\`ld64\`, or the one shipped by your
jailbreak/TrollStore environment) and an iPhoneOS SDK to link programs.
Compiling to object files (\`--emit=obj\`) or rlibs works without a linker.

cargo is not part of this toolchain: it spawns child processes, which needs
extra plumbing on iOS (see the README).
EOF
}

write_build_info() {
    local dest="$1"
    cat > "${dest}/build-info.json" <<EOF
{
  "name": "rustios",
  "rust_version": "${RUST_VERSION}",
  "rust_channel": "${RUST_CHANNEL}",
  "build_triple": "${BUILD_TRIPLE}",
  "host_triple": "${HOST_TRIPLE}",
  "target": "${HOST_TRIPLE}",
  "ios_deployment_target": "${IOS_DEPLOYMENT_TARGET}",
  "llvm_targets": "${LLVM_TARGETS}",
  "stage": ${STAGE},
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

# Ad-hoc sign every Mach-O in the tree. iOS refuses to execute unsigned code;
# an ad-hoc signature is enough once the app itself is signed.
sign_tree() {
    local dir="$1" file
    require_cmd codesign
    while IFS= read -r -d '' file; do
        if file -b "${file}" | grep -q 'Mach-O'; then
            codesign --force --sign - --timestamp=none "${file}" >/dev/null 2>&1 \
                || warn "failed to sign ${file}"
        fi
    done < <(find "${dir}" -type f \( -perm -u+x -o -name '*.dylib' \) -print0)
}

# ---------------------------------------------------------------------------
# fetch
# ---------------------------------------------------------------------------

fetch() {
    require_cmd git

    if [[ -d "${RUST_SOURCE_DIR}/.git" ]]; then
        local current
        current="$(git -C "${RUST_SOURCE_DIR}" describe --tags --exact-match 2>/dev/null \
                   || git -C "${RUST_SOURCE_DIR}" rev-parse --short HEAD)"
        if [[ "${current}" != "${RUST_VERSION}" ]]; then
            warn "existing checkout is '${current}', expected '${RUST_VERSION}' - re-cloning"
            rm -rf "${RUST_SOURCE_DIR}"
        fi
    fi

    if [[ ! -d "${RUST_SOURCE_DIR}/.git" ]]; then
        mkdir -p "$(dirname "${RUST_SOURCE_DIR}")"
        log "cloning rust-lang/rust ${RUST_VERSION} (shallow)"
        git clone --depth 1 --branch "${RUST_VERSION}" \
            https://github.com/rust-lang/rust.git "${RUST_SOURCE_DIR}"
    fi

    # bootstrap needs src/llvm-project (LLVM sources) and library/backtrace
    # (a std dependency). Everything else is only needed for dist/docs.
    log "updating required submodules"
    git -C "${RUST_SOURCE_DIR}" submodule update --init --depth 1 -- \
        src/llvm-project library/backtrace \
        || git -C "${RUST_SOURCE_DIR}" submodule update --init -- \
            src/llvm-project library/backtrace

    [[ -f "${RUST_SOURCE_DIR}/src/llvm-project/llvm/CMakeLists.txt" ]] \
        || die "src/llvm-project is empty; submodule checkout failed"
    [[ -f "${RUST_SOURCE_DIR}/library/backtrace/Cargo.toml" ]] \
        || die "library/backtrace is empty; submodule checkout failed"
    [[ -f "${RUST_SOURCE_DIR}/x.py" ]] || die "x.py not found in ${RUST_SOURCE_DIR}"

    log "rust sources ready ($(git -C "${RUST_SOURCE_DIR}" rev-parse --short HEAD))"
}

# ---------------------------------------------------------------------------
# configure
# ---------------------------------------------------------------------------

configure() {
    [[ -d "${RUST_SOURCE_DIR}" ]] || die "${RUST_SOURCE_DIR} does not exist; run 'fetch' first"

    local cfg="${RUST_SOURCE_DIR}/bootstrap.toml"
    local jobs_line="" ccache_line=""
    [[ -n "${JOBS}" ]] && jobs_line="jobs = ${JOBS}"
    # bootstrap feeds `build.ccache` to RUSTC_WRAPPER and to LLVM's
    # CMAKE_<LANG>_COMPILER_LAUNCHER, so sccache covers both rustc and LLVM.
    if command -v sccache >/dev/null 2>&1; then
        ccache_line='ccache = "sccache"'
    elif command -v ccache >/dev/null 2>&1; then
        ccache_line='ccache = "ccache"'
    fi
    if [[ -n "${ccache_line}" ]]; then
        log "using ${ccache_line#ccache = \"} for compiler caching"
    fi

    log "writing ${cfg}"
    cat > "${cfg}" <<EOF
# Generated by Scripts/build-rust-toolchain.sh - do not edit, re-run 'configure'.
#
# build  : the macOS machine that does the work
# host   : where the produced rustc runs
# target : what that rustc compiles for
[build]
build = "${BUILD_TRIPLE}"
host = ["${HOST_TRIPLE}"]
target = ["${HOST_TRIPLE}"]
build-dir = "build"
docs = false
compiler-docs = false
extended = false
submodules = true
locked-deps = true
${jobs_line}
${ccache_line}

[install]
prefix = "${WORK_DIR}/install"

[rust]
channel = "${RUST_CHANNEL}"
optimize = true
debug = false
debuginfo-level = 0
debuginfo-level-rustc = 0
debuginfo-level-std = 0
codegen-units = 16
incremental = false
download-rustc = false
# Ship llvm-tools (llvm-ar, llvm-objcopy, ...) next to the compiler: they are
# built as part of LLVM anyway, and are needed to produce archives on device.
llvm-tools = true

[llvm]
# The LLVM that ends up inside the iOS rustc must be an iOS library, so the
# prebuilt macOS LLVM cannot be downloaded.
download-ci-llvm = false
optimize = true
assertions = false
tests = false
ninja = true
targets = "${LLVM_TARGETS}"
experimental-targets = ""
link-shared = false
static-libstdcpp = false
libzstd = false
clang = false
enable-warnings = false
EOF

    log "bootstrap.toml written (build=${BUILD_TRIPLE} host=${HOST_TRIPLE} iOS ${IOS_DEPLOYMENT_TARGET})"
    printf '%s\n' "--- ${cfg} ---"
    sed 's/^/    /' "${cfg}"
}

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

build() {
    require_macos
    require_cmd python3
    require_cmd xcrun

    [[ -f "${RUST_SOURCE_DIR}/bootstrap.toml" ]] || die "missing bootstrap.toml; run 'configure' first"

    local sdk
    sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
    [[ -n "${sdk}" ]] || die "could not find the iPhoneOS SDK"
    log "iPhoneOS SDK: ${sdk}"

    export IPHONEOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}"
    # rustc must not pick up the SDK for *host* (macOS) compilations, so
    # SDKROOT is deliberately not exported. It queries xcrun itself when
    # compiling for iOS.

    local stage_args=(build --stage "${STAGE}")
    if [[ -n "${JOBS}" ]]; then
        stage_args+=(-j "${JOBS}")
    fi

    log "running: python3 x.py ${stage_args[*]}  (this takes hours)"
    ( cd "${RUST_SOURCE_DIR}" && python3 x.py "${stage_args[@]}" )
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------

verify() {
    require_macos
    local sysroot rustc
    sysroot="$(stage_dir)"
    rustc="${sysroot}/bin/rustc"

    [[ -x "${rustc}" ]] || die "missing ${rustc}; the build did not produce a compiler"

    log "checking ${rustc}"
    file "${rustc}"
    file "${rustc}" | grep -q 'Mach-O 64-bit executable arm64' \
        || die "rustc is not an arm64 Mach-O executable"
    lipo -archs "${rustc}" | grep -qw arm64 \
        || die "rustc does not contain an arm64 slice"

    if command -v vtool >/dev/null 2>&1; then
        vtool -show-build "${rustc}"
        vtool -show-build "${rustc}" | grep -q 'platform IOS' \
            || die "rustc was not linked for the iOS platform"
        vtool -show-build "${rustc}" | grep -q "minos ${IOS_DEPLOYMENT_TARGET}" \
            || warn "deployment target is not ${IOS_DEPLOYMENT_TARGET}"
    fi

    [[ -d "${sysroot}/lib/rustlib/${HOST_TRIPLE}/lib" ]] \
        || die "std for ${HOST_TRIPLE} is missing"
    ls "${sysroot}/lib/rustlib/${HOST_TRIPLE}/lib"/libstd-*.rlib >/dev/null 2>&1 \
        || die "libstd for ${HOST_TRIPLE} is missing"

    log "rustc, std and codegen backends are iOS/arm64 artifacts"
}

# ---------------------------------------------------------------------------
# package: RustToolchain (the compilers + std, i.e. SwiftToolchain.zip)
# ---------------------------------------------------------------------------

package() {
    local stage dest tarball
    stage="$(stage_dir)"
    dest="${WORK_DIR}/${TOOLCHAIN_NAME}"

    [[ -x "${stage}/bin/rustc" ]] || die "missing ${stage}/bin/rustc; run 'build' first"

    log "assembling ${dest}"
    rm -rf "${dest}"
    mkdir -p "${dest}/usr"
    cp -a "${stage}/bin" "${dest}/usr/"
    cp -a "${stage}/lib" "${dest}/usr/"

    # Never ship host-side leftovers.
    if [[ "${BUILD_TRIPLE}" != "${HOST_TRIPLE}" ]]; then
        rm -rf "${dest}/usr/lib/rustlib/${BUILD_TRIPLE}"
    fi
    find "${dest}" -name '*.dSYM' -prune -exec rm -rf {} + 2>/dev/null || true

    write_usage_doc "${dest}"
    write_build_info "${dest}"

    if [[ "$(uname -s)" == "Darwin" ]] && command -v codesign >/dev/null 2>&1; then
        log "ad-hoc signing Mach-O files"
        sign_tree "${dest}/usr"
    fi

    tarball="${ARTIFACTS_DIR}/${TOOLCHAIN_NAME}-${PACKAGE_PREFIX}-${RUST_VERSION}.tar.xz"
    log "creating ${tarball}"
    tar_xz "${WORK_DIR}" "${TOOLCHAIN_NAME}" "${tarball}"
    checksum "${tarball}"
    log "toolchain: $(human_size "${tarball}")"

    # A second archive with exactly the layout rustup/LLVM-On-iOS users
    # expect (usr/bin + usr/lib at the top level).
    local bare="${ARTIFACTS_DIR}/${TOOLCHAIN_NAME}-${PACKAGE_PREFIX}-${RUST_VERSION}-usr.tar.xz"
    log "creating ${bare}"
    ( cd "${dest}" && XZ_OPT="-T0 -6" tar -cJf "${bare}" usr )
    checksum "${bare}"
}

# ---------------------------------------------------------------------------
# support: RustSupportLibs (LLVM for iOS + std), LLVM-On-iOS' CoreCompilerSupportLibs
# ---------------------------------------------------------------------------

support() {
    local llvm libdir dest tarball
    llvm="$(llvm_dir)"
    libdir="$(stage_dir)/lib/rustlib/${HOST_TRIPLE}/lib"
    dest="${WORK_DIR}/${SUPPORT_NAME}"

    [[ -d "${llvm}/lib" ]] || die "missing iOS LLVM at ${llvm}/lib; run 'build' first"
    [[ -d "${libdir}" ]]   || die "missing std at ${libdir}; run 'build' first"

    log "collecting iOS LLVM static libraries"
    rm -rf "${dest}"
    mkdir -p "${dest}/llvm/lib" "${dest}/rustlib"
    cp -a "${llvm}/lib/"*.a "${dest}/llvm/lib/" 2>/dev/null || true
    cp -a "${llvm}/bin/llvm-config" "${dest}/llvm/" 2>/dev/null || true
    cp -a "${libdir}" "${dest}/rustlib/lib"

    local backends
    backends="$(stage_dir)/lib/rustlib/${HOST_TRIPLE}/codegen-backends"
    [[ -d "${backends}" ]] && cp -a "${backends}" "${dest}/rustlib/"

    cat > "${dest}/README.md" <<EOF
# ${SUPPORT_NAME} (${PACKAGE_PREFIX})

Support libraries for the rustios toolchain, i.e. the counterpart of
LLVM-On-iOS' \`CoreCompilerSupportLibs\`.

* \`llvm/lib/*.a\` - LLVM, built for ${HOST_TRIPLE}
* \`llvm/llvm-config\` - llvm-config for ${HOST_TRIPLE}
* \`rustlib/lib/*.rlib\` - core/std/alloc/... for ${HOST_TRIPLE}
* \`rustlib/codegen-backends/\` - the LLVM codegen backend for ${HOST_TRIPLE}

These are needed when linking \`${XCFRAMEWORK_NAME}\` into an app, or when
building a custom rustc driver on the device.
EOF

    write_build_info "${dest}"

    tarball="${ARTIFACTS_DIR}/${SUPPORT_NAME}-${PACKAGE_PREFIX}-${RUST_VERSION}.tar.xz"
    log "creating ${tarball}"
    tar_xz "${WORK_DIR}" "${SUPPORT_NAME}" "${tarball}"
    checksum "${tarball}"
    log "support libraries: $(human_size "${tarball}")"
}

# ---------------------------------------------------------------------------
# xcframework: rustc as a static library + C API (LLVM.xcframework analogue)
# ---------------------------------------------------------------------------

build_xcframework() {
    require_macos
    local stage1 stage2 out_dir merged
    stage1="$(build_host_dir)"
    stage2="$(stage_dir)"
    out_dir="${WORK_DIR}/${XCFRAMEWORK_NAME}.build"
    merged="${out_dir}/sysroot"

    [[ "${STAGE}" -ge 2 ]] || die "the xcframework driver needs --stage 2 (stage1 cannot run on the build host)"
    [[ -x "${stage1}/bin/rustc" ]] || die "missing ${stage1}/bin/rustc; run 'build' first"
    [[ -d "${stage2}/lib/rustlib/${HOST_TRIPLE}/lib" ]] \
        || die "missing std for ${HOST_TRIPLE}; run 'build' first"

    log "building the rustios driver static library (rustc_private)"
    rm -rf "${out_dir}"
    mkdir -p "${out_dir}/include" "${merged}/lib/rustlib"

    # The driver is compiled by the stage1 compiler (which runs on the build
    # machine) for ${HOST_TRIPLE}, but it needs the *host* side of the stage1
    # sysroot (codegen backend dylibs) and the *target* side of the stage2
    # sysroot (std + rustc_private rlibs). Merge them into one sysroot.
    cp -a "${stage1}/lib/"*.dylib "${merged}/lib/" 2>/dev/null || true
    ln -sfn "${stage2}/lib/rustlib/${HOST_TRIPLE}" "${merged}/lib/rustlib/${HOST_TRIPLE}"
    cp "${SCRIPT_DIR}/rustios-driver/include/rustios.h" "${out_dir}/include/"

    RUSTC_BOOTSTRAP=1 \
    RUSTIOS_VERSION="${RUST_VERSION}" \
    IPHONEOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}" \
    "${stage1}/bin/rustc" \
        --edition 2021 \
        --crate-name rustios_driver \
        --crate-type staticlib \
        --target "${HOST_TRIPLE}" \
        --sysroot "${merged}" \
        -C opt-level=2 \
        -C debuginfo=0 \
        -L "dependency=${stage2}/lib/rustlib/${HOST_TRIPLE}/lib" \
        -L "native=$(llvm_dir)/lib" \
        -o "${out_dir}/libRustCompiler.a" \
        "${SCRIPT_DIR}/rustios-driver/rustios_driver.rs"

    [[ -f "${out_dir}/libRustCompiler.a" ]] || die "static library was not produced"

    cat > "${out_dir}/build-info.json" <<EOF
{
  "name": "rustios",
  "rust_version": "${RUST_VERSION}",
  "crate": "rustios_driver",
  "host_triple": "${HOST_TRIPLE}",
  "target": "${HOST_TRIPLE}",
  "ios_deployment_target": "${IOS_DEPLOYMENT_TARGET}",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

    rm -rf "${out_dir}/${XCFRAMEWORK_NAME}"
    log "creating ${XCFRAMEWORK_NAME}"
    xcodebuild -create-xcframework \
        -library "${out_dir}/libRustCompiler.a" \
        -headers "${out_dir}/include" \
        -output "${out_dir}/${XCFRAMEWORK_NAME}"

    local a="${ARTIFACTS_DIR}/${XCFRAMEWORK_NAME}-${PACKAGE_PREFIX}-${RUST_VERSION}.tar.xz"
    log "creating ${a}"
    tar_xz "${out_dir}" "${XCFRAMEWORK_NAME}" "${a}"
    checksum "${a}"
    log "xcframework: $(human_size "${a}")"
}

# ---------------------------------------------------------------------------
# misc
# ---------------------------------------------------------------------------

info() {
    cat <<EOF
rustios build configuration
  rust version          : ${RUST_VERSION} (${RUST_CHANNEL})
  iOS deployment target : ${IOS_DEPLOYMENT_TARGET}
  build triple          : ${BUILD_TRIPLE}
  host triple           : ${HOST_TRIPLE}
  target                : ${HOST_TRIPLE}
  stage                 : ${STAGE}
  LLVM targets          : ${LLVM_TARGETS}
  rust sources          : ${RUST_SOURCE_DIR}
  build dir             : ${BUILD_DIR}
  work dir              : ${WORK_DIR}
  artifacts dir         : ${ARTIFACTS_DIR}
  package               : ${TOOLCHAIN_NAME}-${PACKAGE_PREFIX}-${RUST_VERSION}.tar.xz
EOF
}

clean() {
    log "removing build output, work dir and artifacts"
    rm -rf "${BUILD_DIR}" "${WORK_DIR}" "${ARTIFACTS_DIR}"
}

clean_all() {
    clean
    log "removing Rust sources"
    rm -rf "${RUST_SOURCE_DIR}"
}

usage() {
    cat <<EOF
usage: $(basename "$0") <command>

commands:
  fetch         clone rust ${RUST_VERSION} and the required submodules
  configure     write bootstrap.toml (cross-compile rustc for ${HOST_TRIPLE})
  build         run x.py build --stage ${STAGE}
  verify        check that rustc/std really are iOS arm64 artifacts
  package       create ${TOOLCHAIN_NAME}-${PACKAGE_PREFIX}-${RUST_VERSION}.tar.xz
  support       create ${SUPPORT_NAME}-${PACKAGE_PREFIX}-${RUST_VERSION}.tar.xz
  xcframework   create ${XCFRAMEWORK_NAME}-${PACKAGE_PREFIX}-${RUST_VERSION}.tar.xz
  all           fetch + configure + build + verify + package + support + xcframework
  info          print the effective configuration
  clean         remove build output, work dir and artifacts
  clean-all     clean + remove the Rust checkout

environment: RUST_VERSION, RUST_CHANNEL, IOS_DEPLOYMENT_TARGET, HOST_TRIPLE,
             STAGE, LLVM_TARGETS, JOBS, RUST_SOURCE_DIR, BUILD_DIR, WORK_DIR,
             ARTIFACTS_DIR
EOF
}

main() {
    local cmd="${1:-}"
    case "${cmd}" in
        fetch)       fetch ;;
        configure)   configure ;;
        build)       build ;;
        verify)      verify ;;
        package)     package ;;
        support)     support ;;
        xcframework) build_xcframework ;;
        all)
            fetch
            configure
            build
            verify
            package
            support
            build_xcframework
            ;;
        info)        info ;;
        clean)       clean ;;
        clean-all)   clean_all ;;
        ""|-h|--help|help) usage ;;
        *) usage; die "unknown command: ${cmd}" ;;
    esac
}

main "$@"
