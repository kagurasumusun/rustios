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

# write_build_info <directory> [extra "key": value lines...]
write_build_info() {
    local dest="$1"
    shift

    local entries=(
        '"name": "rustios"'
        '"rust_version": "'${RUST_VERSION}'"'
        '"rust_channel": "'${RUST_CHANNEL}'"'
        '"build_triple": "'${BUILD_TRIPLE}'"'
        '"host_triple": "'${HOST_TRIPLE}'"'
        '"target": "'${HOST_TRIPLE}'"'
        '"ios_deployment_target": "'${IOS_DEPLOYMENT_TARGET}'"'
        '"llvm_targets": "'${LLVM_TARGETS}'"'
        '"stage": '${STAGE}
        '"built_at": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"'
    )
    local entry first=1

    {
        printf '{\n'
        for entry in "${entries[@]}" "$@"; do
            if [[ "${first}" -eq 1 ]]; then
                first=0
            else
                printf ',\n'
            fi
            printf '  %s' "${entry}"
        done
        printf '\n}\n'
    } > "${dest}/build-info.json"
}

# assert_ios_only <directory> <label>: fail when the tree contains Mach-O
# binaries that are not iOS/arm64.
#
# The build machine is a Mac, so it is easy to leak a macOS tool or dylib into
# an artifact (LLVM's llvm-config, a host std, ...). Every shipped Mach-O must
# be arm64 and - when vtool is available - claim `platform IOS`.
assert_ios_only() {
    local dir="$1" label="$2" exclude="${3:-}" file desc build_info
    local bad=()
    [[ -d "${dir}" ]] || return 0
    while IFS= read -r -d '' file; do
        desc="$(file -b "${file}" 2>/dev/null || true)"
        [[ "${desc}" == *Mach-O* ]] || continue
        if [[ "${desc}" != *"arm64"* ]]; then
            bad+=("${file}: ${desc}")
            continue
        fi
        if command -v vtool >/dev/null 2>&1; then
            build_info="$(vtool -show-build "${file}" 2>/dev/null || true)"
            if [[ -n "${build_info}" && "${build_info}" != *"platform IOS"* ]]; then
                bad+=("${file}: $(printf '%s' "${build_info}" | sed -n 's/^ *platform //p' | sed -n 1p)")
            fi
        fi
    done < <(find "${dir}" -type f \( -perm -u+x -o -name '*.dylib' \) \
                  ${exclude:+-not -path "${dir}/${exclude}/*"} -print0)

    if [[ "${#bad[@]}" -gt 0 ]]; then
        printf '  %s\n' "${bad[@]}" >&2
        die "${label} contains non-iOS binaries; refusing to ship it"
    fi
    log "${label}: every Mach-O file is iOS/arm64"
}

# Ad-hoc sign every Mach-O in the tree. iOS refuses to execute unsigned code;
# an ad-hoc signature is enough once the app itself is signed.
sign_tree() {
    local dir="$1" file desc
    require_cmd codesign
    while IFS= read -r -d '' file; do
        desc="$(file -b "${file}" 2>/dev/null || true)"
        if [[ "${desc}" == *Mach-O* ]]; then
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
# bootstrap patch: build LLVM for iOS
#
# Upstream's `configure_cmake` overrides `CMAKE_SYSTEM_NAME` to `Darwin`, sets
# the sysroot to `/` and clears the deployment target for every Apple mobile
# target, because compiler-rt's CMake configuration assumes macOS. That is fine
# for compiler-rt, but a full LLVM built that way is not an iOS library, and the
# rustc that links it would not be an iOS executable.
#
# This patch makes the block conditional on `RUSTIOS_IOS_SDK` (exported by
# `build`), so LLVM is configured with the iPhoneOS SDK and the deployment
# target while everything else keeps the upstream behaviour.
# ---------------------------------------------------------------------------

patch_bootstrap_llvm() {
    local file="${RUST_SOURCE_DIR}/src/bootstrap/src/core/build_steps/llvm.rs"
    [[ -f "${file}" ]] || { warn "bootstrap llvm.rs not found; skipping iOS LLVM patch"; return 0; }
    require_cmd python3

    if ! python3 - "${file}" <<'PY'
import pathlib
import sys

MARKER = "rustios: build a real iOS LLVM"
path = pathlib.Path(sys.argv[1])
src = path.read_text()

if MARKER in src:
    print("bootstrap already patched")
    sys.exit(0)

lines = src.splitlines(keepends=True)

# Locate the `if !target.contains("darwin")` branch inside the Apple block.
start = None
for i, line in enumerate(lines):
    if 'if !target.contains("darwin")' in line:
        start = i
        break

if start is None:
    sys.stderr.write("could not find the Apple-mobile block in llvm.rs\n")
    sys.exit(3)

# The three defines we want to replace live between `start` and the next
# closing brace at the same indentation.
indent = lines[start][: len(lines[start]) - len(lines[start].lstrip())]
end = None
for i in range(start + 1, len(lines)):
    if lines[i].rstrip("\n") == indent + "}":
        end = i
        break

if end is None:
    sys.stderr.write("could not find the end of the Apple-mobile block\n")
    sys.exit(3)

block = lines[start + 1 : end]
sys_idx = sys_idx2 = dt_idx = None
for offset, line in enumerate(block):
    if 'cfg.define("CMAKE_SYSTEM_NAME", "Darwin")' in line and sys_idx is None:
        sys_idx = offset
    if 'cfg.define("CMAKE_OSX_SYSROOT", "/")' in line:
        sys_idx2 = offset
    if 'cfg.define("CMAKE_OSX_DEPLOYMENT_TARGET", "")' in line:
        dt_idx = offset

if sys_idx is None or sys_idx2 is None or dt_idx is None or not (sys_idx < sys_idx2 <= dt_idx):
    sys.stderr.write("unexpected bootstrap LLVM layout; please update the rustios patch\n")
    sys.exit(3)

# Also drop the stale FIXME comment block directly above the statements.
while sys_idx > 0:
    prev = block[sys_idx - 1].strip()
    if prev == "" or prev.startswith("//"):
        sys_idx -= 1
    else:
        break

# Only blank lines, comments and those three statements may be replaced.
allowed = []
for offset in range(sys_idx, dt_idx + 1):
    line = block[offset].strip()
    ok = (
        line == ""
        or line.startswith("//")
        or 'cfg.define("CMAKE_SYSTEM_NAME", "Darwin")' in line
        or 'cfg.define("CMAKE_OSX_SYSROOT", "/")' in line
        or 'cfg.define("CMAKE_OSX_DEPLOYMENT_TARGET", "")' in line
    )
    if not ok:
        sys.stderr.write(f"unexpected line in the block: {block[offset]!r}\n")
        sys.exit(3)
    allowed.append(offset)

ind = indent + "    "  # indentation inside the `if !target.contains("darwin")` branch
replacement = [
    f"{ind}// {MARKER}.\n",
    f"{ind}// Upstream forces CMAKE_SYSTEM_NAME=Darwin and an empty sysroot here,\n",
    f"{ind}// which only works for compiler-rt. A full LLVM must be built against\n",
    f"{ind}// the iPhoneOS SDK, otherwise the objects are not iOS objects.\n",
    f'{ind}if let Ok(sdk) = std::env::var("RUSTIOS_IOS_SDK") {{\n',
    f'{ind}    cfg.define("CMAKE_SYSTEM_NAME", "iOS");\n',
    f'{ind}    cfg.define("CMAKE_OSX_SYSROOT", sdk);\n',
    f'{ind}    cfg.define(\n',
    f'{ind}        "CMAKE_OSX_DEPLOYMENT_TARGET",\n',
    f'{ind}        std::env::var("RUSTIOS_IOS_DEPLOYMENT_TARGET")\n',
    f'{ind}            .unwrap_or_else(|_| "16.0".to_string()),\n',
    f'{ind}    );\n',
    f'{ind}    // CMake defaults MACOSX_BUNDLE to ON for iOS, which turns every\n',
    f'{ind}    // LLVM tool into a .app and makes `install(TARGETS ...)` fail. We\n',
    f'{ind}    // want plain Mach-O executables.\n',
    f'{ind}    cfg.define("CMAKE_MACOSX_BUNDLE", "OFF");\n',
    f'{ind}}} else {{\n',
    f'{ind}    cfg.define("CMAKE_SYSTEM_NAME", "Darwin");\n',
    f'{ind}    cfg.define("CMAKE_OSX_SYSROOT", "/");\n',
    f'{ind}    cfg.define("CMAKE_OSX_DEPLOYMENT_TARGET", "");\n',
    f'{ind}}}\n',
]

new_block = (
    block[: sys_idx]
    + replacement
    + block[dt_idx + 1 :]
)
new_lines = lines[: start + 1] + new_block + lines[end:]

path.write_text("".join(new_lines))
print("patched bootstrap LLVM build for iOS")
PY
    then
        warn "could not patch bootstrap's LLVM iOS settings (patch is valid for RUST_VERSION=${RUST_VERSION}); continuing"
    fi

    if grep -q "rustios: build a real iOS LLVM" "${file}"; then
        log "bootstrap patched: LLVM for iOS is configured with the iPhoneOS SDK"
    else
        warn "bootstrap patch did not apply; the iOS LLVM build may fail"
    fi
}

# ---------------------------------------------------------------------------
# bootstrap patch: keep the rustc object files
#
# Upstream copies only `.rmeta` files for the rustc crates into the sysroot:
# the object files are already inside `librustc_driver.so`, and the metadata is
# enough to link a driver against it. That makes a *static* driver impossible.
#
# rustios ships `Rust.xcframework` as a static archive (like LLVM-On-iOS'
# `llvm.a`), so the rlibs have to survive. This patch keeps them.
# ---------------------------------------------------------------------------

patch_bootstrap_rustc_artifacts() {
    local file="${RUST_SOURCE_DIR}/src/bootstrap/src/core/build_steps/compile.rs"
    if [[ ! -f "${file}" ]]; then
        warn "bootstrap compile.rs not found; skipping the rlib patch"
        return 0
    fi
    require_cmd python3

    if ! python3 - "${file}" <<'PY'
import pathlib
import sys

MARKER = "rustios: keep the object files"
path = pathlib.Path(sys.argv[1])
src = path.read_text()

if MARKER in src:
    print("bootstrap already keeps the rustc rlibs")
    sys.exit(0)

old = '                filename.ends_with(".rmeta")\n'
new = (
    "                // rustios: keep the object files as well, so that the\n"
    "                // static driver in Rust.xcframework (libRustCompiler.a)\n"
    "                // can link against rustc_driver_impl and its deps.\n"
    '                filename.ends_with(".rmeta") || filename.ends_with(".rlib")\n'
)

if src.count(old) != 1:
    sys.stderr.write(
        "could not find the single rustc artifact filter in compile.rs "
        f"(found {src.count(old)} matches)\n"
    )
    sys.exit(3)

path.write_text(src.replace(old, new, 1))
print("patched bootstrap: rustc rlibs are kept in the sysroot")
PY
    then
        warn "could not patch bootstrap's rustc artifact filter (valid for RUST_VERSION=${RUST_VERSION}); continuing"
    fi

    if grep -q "rustios: keep the object files" "${file}"; then
        log "bootstrap patched: rustc rlibs stay in the sysroot (static xcframework)"
    else
        warn "rustc rlibs will not be kept; Rust.xcframework falls back to a dylib"
    fi
}

# ---------------------------------------------------------------------------
# configure
# ---------------------------------------------------------------------------

configure() {
    [[ -d "${RUST_SOURCE_DIR}" ]] || die "${RUST_SOURCE_DIR} does not exist; run 'fetch' first"

    local cfg="${RUST_SOURCE_DIR}/bootstrap.toml"
    local jobs_line="" ccache_line=""
    # bootstrap resolves build-dir relative to the source directory, so keep it
    # relative when it is the default and absolute when it was overridden.
    local build_dir_line="build"
    if [[ "${BUILD_DIR}" != "${RUST_SOURCE_DIR}/build" ]]; then
        build_dir_line="${BUILD_DIR}"
    fi

    [[ -n "${JOBS}" ]] && jobs_line="jobs = ${JOBS}"
    # bootstrap feeds `build.ccache` to RUSTC_WRAPPER and to LLVM's
    # CMAKE_<LANG>_COMPILER_LAUNCHER, so the wrapper covers both rustc and LLVM.
    # Only a locally installed wrapper is used: a remote cache that fails mid
    # build aborts the compiler invocation, and this build is hours long.
    local ccache_tool=""
    if command -v sccache >/dev/null 2>&1; then
        ccache_tool="sccache"
    elif command -v ccache >/dev/null 2>&1; then
        ccache_tool="ccache"
    fi
    if [[ -n "${ccache_tool}" ]]; then
        ccache_line="ccache = \"${ccache_tool}\""
        log "using ${ccache_tool} for compiler caching"
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
build-dir = "${build_dir_line}"
docs = false
compiler-docs = false
extended = false
# fetch only clones src/llvm-project and library/backtrace; do not let x.py
# pull cargo/gcc/enzyme/rustc-perf as well (it also keeps the build offline).
submodules = false
locked-deps = true
# Sanitizer runtimes use compiler-rt's own (macOS-flavoured) CMake setup, which
# the rustios LLVM patch deliberately bypasses. Build LLVM only.
sanitizers = false
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

    patch_bootstrap_llvm
    patch_bootstrap_rustc_artifacts
}

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

# xpy_build <stage> <host> [paths...]
#
# Run one phase of the bootstrap. The two phases exist because a cross-host
# build needs a compiler that runs on the build machine first:
#
#   host phase   : LLVM for the build machine, the stage1 compiler, and the
#                  target's std built by that compiler
#   target phase : LLVM for the iOS host, and the compiler that runs on iOS
xpy_build() {
    local stage="$1" host="$2"
    shift 2

    local args=(build --stage "${stage}" --host "${host}")
    if [[ -n "${JOBS}" ]]; then
        args+=(-j "${JOBS}")
    fi
    args+=("$@")

    log "running: python3 x.py ${args[*]}"
    ( cd "${RUST_SOURCE_DIR}" && python3 x.py "${args[@]}" )
}

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
    # Read by the bootstrap patch (see patch_bootstrap_llvm) when it configures
    # LLVM for the iOS host: the full LLVM must be built against the iPhoneOS
    # SDK, not against `/`.
    export RUSTIOS_IOS_SDK="${sdk}"
    export RUSTIOS_IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}"
    # rustc must not pick up the SDK for *host* (macOS) compilations, so
    # SDKROOT is deliberately not exported. It queries xcrun itself when
    # compiling for iOS.

    case "${RUSTIOS_BUILD_PHASE:-all}" in
        host)
            xpy_build 1 "${BUILD_TRIPLE}"
            ;;
        target)
            [[ "${STAGE}" -ge 2 ]] || die "the target phase needs STAGE >= 2"
            # `compiler` = the Assemble step: build the sysroot (compiler +
            # codegen backends + std link) for the iOS host. Without the path
            # filter bootstrap would also build a stage-2 compiler for the
            # build machine, which nothing here needs.
            xpy_build "${STAGE}" "${HOST_TRIPLE}" compiler
            ;;
        all)
            xpy_build 1 "${BUILD_TRIPLE}"
            if [[ "${STAGE}" -ge 2 ]]; then
                xpy_build "${STAGE}" "${HOST_TRIPLE}" compiler
            fi
            ;;
        *)
            die "unknown RUSTIOS_BUILD_PHASE: ${RUSTIOS_BUILD_PHASE} (host|target|all)"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------

verify() {
    require_macos
    local sysroot rustc desc archs build_info
    sysroot="$(stage_dir)"
    rustc="${sysroot}/bin/rustc"

    [[ -x "${rustc}" ]] || die "missing ${rustc}; the build did not produce a compiler"

    log "checking ${rustc}"
    file "${rustc}"
    desc="$(file -b "${rustc}")"
    [[ "${desc}" == *"Mach-O 64-bit executable arm64"* ]] \
        || die "rustc is not an arm64 Mach-O executable: ${desc}"
    archs="$(lipo -archs "${rustc}")"
    [[ " ${archs} " == *" arm64 "* ]] \
        || die "rustc does not contain an arm64 slice (lipo: ${archs})"

    if command -v vtool >/dev/null 2>&1; then
        build_info="$(vtool -show-build "${rustc}")"
        printf '%s\n' "${build_info}"
        [[ "${build_info}" == *"platform IOS"* ]] \
            || die "rustc was not linked for the iOS platform"
        [[ "${build_info}" == *"minos ${IOS_DEPLOYMENT_TARGET}"* ]] \
            || warn "deployment target is not ${IOS_DEPLOYMENT_TARGET}"
    fi

    local libdir
    libdir="${sysroot}/lib/rustlib/${HOST_TRIPLE}/lib"
    [[ -d "${libdir}" ]] || die "std for ${HOST_TRIPLE} is missing (${libdir})"
    shopt -s nullglob
    local std_rlibs=("${libdir}"/libstd-*.rlib)
    shopt -u nullglob
    [[ "${#std_rlibs[@]}" -gt 0 ]] || die "libstd for ${HOST_TRIPLE} is missing"
    [[ -d "${sysroot}/lib/rustlib/${HOST_TRIPLE}/codegen-backends" ]] \
        || die "codegen backends for ${HOST_TRIPLE} are missing"

    # A static Rust.xcframework needs the rustc rlibs, which only exist when
    # patch_bootstrap_rustc_artifacts applied before the build.
    shopt -s nullglob
    local driver_rlibs=("${libdir}"/librustc_driver_impl-*.rlib)
    local compiler_dylibs=("${sysroot}/lib"/librustc_driver-*.dylib)
    shopt -u nullglob
    if [[ "${#driver_rlibs[@]}" -eq 0 ]]; then
        warn "librustc_driver_impl-*.rlib is missing from ${libdir}"
        warn "Rust.xcframework will fall back to a dynamic library (no C API)"
        warn "re-run 'configure' and rebuild to get the static archive"
    elif [[ "${#compiler_dylibs[@]}" -eq 0 ]]; then
        warn "librustc_driver-*.dylib is missing from ${sysroot}/lib"
    fi

    assert_ios_only "${sysroot}/bin" "the iOS toolchain (bin)"
    # bootstrap links the build machine's std (macOS) into the compiler
    # sysroot; packaging deletes it, so it is not part of the product.
    assert_ios_only "${sysroot}/lib" "the iOS toolchain (lib)" \
        "rustlib/${BUILD_TRIPLE}"

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

    # The build machine's std (macOS) can be linked into the *compiler's*
    # sysroot by bootstrap; it must never be shipped.
    assert_ios_only "${dest}/usr/bin" "RustToolchain (bin)"
    assert_ios_only "${dest}/usr/lib" "RustToolchain (lib)"

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
    local llvm rustlib dest tarball
    llvm="$(llvm_dir)"
    rustlib="$(stage_dir)/lib/rustlib/${HOST_TRIPLE}"
    dest="${WORK_DIR}/${SUPPORT_NAME}"

    [[ -d "${llvm}/lib" ]] || die "missing iOS LLVM at ${llvm}/lib; run 'build' first"
    [[ -d "${rustlib}/lib" ]] || die "missing std at ${rustlib}/lib; run 'build' first"

    log "collecting iOS LLVM static libraries"
    rm -rf "${dest}"
    mkdir -p "${dest}/llvm/lib" "${dest}/sysroot/lib/rustlib"

    shopt -s nullglob
    local archives=("${llvm}/lib/"*.a)
    shopt -u nullglob
    [[ "${#archives[@]}" -gt 0 ]] || die "no static LLVM libraries in ${llvm}/lib"
    cp -a "${archives[@]}" "${dest}/llvm/lib/"
    # llvm-config is a *host* tool: for a cross build it is a macOS binary, so
    # it does not belong in an iOS payload.

    # The sysroot layout is what `rustc --sysroot` expects, so an app that
    # embeds Rust.xcframework can compile user code with
    # `--sysroot=<RustSupportLibs>/sysroot`.
    cp -a "${rustlib}" "${dest}/sysroot/lib/rustlib/${HOST_TRIPLE}"

    cat > "${dest}/README.md" <<EOF
# ${SUPPORT_NAME} (${PACKAGE_PREFIX})

Support libraries for the rustios toolchain, i.e. the counterpart of
LLVM-On-iOS' \`CoreCompilerSupportLibs\`.

* \`llvm/lib/*.a\` - LLVM, built for ${HOST_TRIPLE}
* \`sysroot/lib/rustlib/${HOST_TRIPLE}/lib/*.rlib\` - core/std/alloc/... for ${HOST_TRIPLE}
* \`sysroot/lib/rustlib/${HOST_TRIPLE}/codegen-backends/\` - the LLVM codegen backend

\`sysroot/\` is a rustc sysroot: pass it to the compiler when it runs on the
device, e.g. through the C API in \`${XCFRAMEWORK_NAME}\`:

\`\`\`c
const char *argv[] = {
    "rustc", "--sysroot", "/path/to/${SUPPORT_NAME}/sysroot",
    "--emit=obj", "hello.rs", "-o", "hello.o",
};
\`\`\`

These are also needed when linking \`${XCFRAMEWORK_NAME}\` into an app.
EOF

    write_build_info "${dest}"
    assert_ios_only "${dest}/llvm" "RustSupportLibs (LLVM)"
    assert_ios_only "${dest}/sysroot" "RustSupportLibs (sysroot)"

    if [[ "$(uname -s)" == "Darwin" ]] && command -v codesign >/dev/null 2>&1; then
        log "ad-hoc signing the codegen backend"
        sign_tree "${dest}/sysroot"
    fi

    tarball="${ARTIFACTS_DIR}/${SUPPORT_NAME}-${PACKAGE_PREFIX}-${RUST_VERSION}.tar.xz"
    log "creating ${tarball}"
    tar_xz "${WORK_DIR}" "${SUPPORT_NAME}" "${tarball}"
    checksum "${tarball}"
    log "support libraries: $(human_size "${tarball}")"
}

# ---------------------------------------------------------------------------
# xcframework: Rust.xcframework (LLVM-On-iOS' LLVM.xcframework)
#
# LLVM-On-iOS ships `llvm.a` inside `LLVM.xcframework`; this does the same for
# rustc. A static archive is possible because bootstrap keeps the rustc rlibs
# (see patch_bootstrap_rustc_artifacts) - upstream throws the object files away
# and only distributes `.rmeta`, because `rustc_driver` is a dylib crate.
#
# The static library is produced by the stage1 (build machine) compiler, which
# emits aarch64-apple-ios objects, and links the stage2 rlibs for that same
# target. If those rlibs are missing the framework falls back to a dynamic
# slice holding the compiler dylib itself (no C API, `"c_api": false`).
# ---------------------------------------------------------------------------

# is_ios_dylib <file>: true for an arm64 Mach-O dylib linked for iOS.
is_ios_dylib() {
    local candidate="$1" desc build_info
    desc="$(file -b "${candidate}" 2>/dev/null || true)"
    [[ "${desc}" == *"Mach-O 64-bit dynamically linked shared library arm64"* ]] \
        || return 1
    if command -v vtool >/dev/null 2>&1; then
        # A macOS dylib is also arm64; only the platform tells them apart.
        # Capture the output instead of piping into `grep -q`, which would
        # SIGPIPE vtool and fail the pipeline under `set -o pipefail`.
        build_info="$(vtool -show-build "${candidate}" 2>/dev/null || true)"
        [[ "${build_info}" == *"platform IOS"* ]] || return 1
    fi
    return 0
}

# find_ios_dylib <result-var> <prefix...>: store the first arm64 iOS dylib
# called <prefix>-*.dylib (or <prefix>.dylib) found in the build tree.
find_ios_dylib() {
    local result_var="$1" prefix dir candidate
    local matches
    shift
    for prefix in "$@"; do
        for dir in "${XCFRAMEWORK_SEARCH_DIRS[@]}"; do
            if [[ ! -d "${dir}" ]]; then
                continue
            fi
            # nullglob drops unmatched *patterns*; a fully quoted name is a
            # literal and would survive, so test it explicitly.
            shopt -s nullglob
            matches=("${dir}/${prefix}-"*.dylib)
            shopt -u nullglob
            if [[ -f "${dir}/${prefix}.dylib" ]]; then
                matches+=("${dir}/${prefix}.dylib")
            fi
            # macOS ships bash 3.2, where an empty "${matches[@]}" is an
            # unbound variable under `set -u`.
            if [[ "${#matches[@]}" -gt 0 ]]; then
                for candidate in "${matches[@]}"; do
                    if is_ios_dylib "${candidate}"; then
                        printf -v "${result_var}" '%s' "${candidate}"
                        return 0
                    fi
                done
            fi
        done
    done
    return 1
}

# find_target_rlib <result-var> <prefix...>: store the first rlib for the iOS
# target (ties are broken by the first search directory that has one).
find_target_rlib() {
    local result_var="$1" prefix dir
    local matches
    shift
    for prefix in "$@"; do
        for dir in "${XCFRAMEWORK_SEARCH_DIRS[@]}"; do
            if [[ ! -d "${dir}" ]]; then
                continue
            fi
            shopt -s nullglob
            matches=("${dir}/${prefix}-"*.rlib)
            shopt -u nullglob
            if [[ "${#matches[@]}" -gt 0 ]]; then
                printf -v "${result_var}" '%s' "${matches[0]}"
                return 0
            fi
        done
    done
    return 1
}

# make_relocatable <directory>: rewrite the dylibs in <directory> so that they
# can be shipped together in one folder inside an app bundle.
make_relocatable() {
    local dir="$1" file dep base
    if ! command -v install_name_tool >/dev/null 2>&1 || ! command -v otool >/dev/null 2>&1; then
        warn "install_name_tool/otool not found; leaving the dylibs as built"
        return 0
    fi

    shopt -s nullglob
    local dylibs=("${dir}"/*.dylib)
    shopt -u nullglob
    for file in "${dylibs[@]}"; do
        base="$(basename "${file}")"
        install_name_tool -id "@rpath/${base}" "${file}" 2>/dev/null || true
    done

    for file in "${dylibs[@]}"; do
        while IFS= read -r dep; do
            if [[ -z "${dep}" || "${dep}" == "@rpath/"* || "${dep}" == "@loader_path/"* ]]; then
                continue
            fi
            base="$(basename "${dep}")"
            if [[ -f "${dir}/${base}" ]]; then
                install_name_tool -change "${dep}" "@rpath/${base}" "${file}" \
                    || warn "could not rewrite ${dep} in $(basename "${file}")"
            fi
        done < <(otool -L "${file}" | awk 'NR > 1 { print $1 }')
        install_name_tool -add_rpath "@loader_path" "${file}" >/dev/null 2>&1 || true
    done
}

# write_xcframework_plist <path> <slice-id> <library> <has-headers>
write_xcframework_plist() {
    local plist="$1" slice_id="$2" library="$3" has_headers="$4"
    local headers_entry=""
    if [[ "${has_headers}" == "true" ]]; then
        headers_entry='
            <key>HeadersPath</key>
            <string>Headers</string>'
    fi
    cat > "${plist}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>
        <dict>
            <key>LibraryIdentifier</key>
            <string>${slice_id}</string>
            <key>LibraryPath</key>
            <string>${library}</string>${headers_entry}
            <key>SupportedArchitectures</key>
            <array>
                <string>arm64</string>
            </array>
            <key>SupportedPlatform</key>
            <string>ios</string>
        </dict>
    </array>
    <key>CFBundlePackageType</key>
    <string>XFWK</string>
    <key>XCFrameworkFormatVersion</key>
    <string>1.0</string>
</dict>
</plist>
EOF
}

# check_static_library <path>: the archive must be an arm64 static library
# that defines the C API.
check_static_library() {
    local lib="$1" desc archs symbols
    desc="$(file -b "${lib}")"
    [[ "${desc}" == *"ar archive"* ]] || die "$(basename "${lib}") is not a static archive: ${desc}"
    archs="$(lipo -info "${lib}" 2>&1 || true)"
    [[ "${archs}" == *arm64* ]] \
        || die "$(basename "${lib}") has no arm64 objects: ${archs}"
    if command -v nm >/dev/null 2>&1; then
        symbols="$(nm -g "${lib}" 2>/dev/null || true)"
        [[ "${symbols}" == *"_rustios_run"* ]] \
            || die "$(basename "${lib}") does not export rustios_run"
        [[ "${symbols}" == *"_rustios_version"* ]] \
            || die "$(basename "${lib}") does not export rustios_version"
    fi
    log "static library: arm64, exports the rustios C API"
}

build_xcframework() {
    require_macos
    local stage1 stage2 libdir out_dir merged xcfw slice
    local runtime_driver runtime_std driver_rlib library
    local has_headers="false" c_api="false" static_lib="false"
    local desc archs build_info
    stage1="$(build_host_dir)"
    stage2="$(stage_dir)"
    libdir="${stage2}/lib/rustlib/${HOST_TRIPLE}/lib"
    out_dir="${WORK_DIR}/${XCFRAMEWORK_NAME}.build"
    xcfw="${out_dir}/${XCFRAMEWORK_NAME}"
    merged="${out_dir}/sysroot"

    [[ "${STAGE}" -ge 2 ]] || die "the xcframework needs --stage 2 output (STAGE=${STAGE})"
    [[ -x "${stage1}/bin/rustc" ]] || die "missing ${stage1}/bin/rustc; run 'build' first"
    [[ -d "${libdir}" ]] || die "missing ${libdir}; run 'build' first"

    # Target artifacts live in the sysroot; the compiler dylibs in <sysroot>/lib.
    XCFRAMEWORK_SEARCH_DIRS=(
        "${libdir}"
        "${stage2}/lib"
        "${stage2}/lib/rustlib/${HOST_TRIPLE}/lib"
        "${stage1}/lib"
    )

    log "assembling ${out_dir}"
    rm -rf "${out_dir}"
    mkdir -p "${out_dir}/lib" "${merged}/lib/rustlib"

    # The stage1 compiler runs on the build machine but emits iOS/arm64 code.
    # Its sysroot has to contain both the stage1 codegen backends (for the
    # build machine) and the stage2 std/rustc rlibs (for the target).
    if [[ "${BUILD_TRIPLE}" != "${HOST_TRIPLE}" && -d "${stage1}/lib/rustlib/${BUILD_TRIPLE}" ]]; then
        ln -sfn "${stage1}/lib/rustlib/${BUILD_TRIPLE}" "${merged}/lib/rustlib/${BUILD_TRIPLE}"
    fi
    ln -sfn "${stage2}/lib/rustlib/${HOST_TRIPLE}" "${merged}/lib/rustlib/${HOST_TRIPLE}"

    if find_target_rlib driver_rlib librustc_driver_impl; then
        log "building the static rustios driver (libRustCompiler.a)"
        log "  rustc_driver_impl: ${driver_rlib}"
        if RUSTC_BOOTSTRAP=1 \
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
                -L "dependency=${libdir}" \
                -o "${out_dir}/lib/libRustCompiler.a" \
                "${SCRIPT_DIR}/rustios-driver/rustios_driver.rs"; then
            static_lib="true"
            c_api="true"
            library="libRustCompiler.a"
            has_headers="true"
            mkdir -p "${out_dir}/Headers"
            cp "${SCRIPT_DIR}/rustios-driver/include/rustios.h" "${out_dir}/Headers/"
        else
            warn "could not build the static rustios driver"
        fi
    else
        warn "no librustc_driver_impl-*.rlib in ${libdir}"
        warn "bootstrap did not keep the rustc rlibs; run 'configure' + a full rebuild"
    fi

    if [[ "${static_lib}" != "true" ]]; then
        # Fallback: ship the compiler dylib itself. It is an iOS shared library
        # (rustc_driver is a dylib crate upstream), so the framework stays
        # usable for dlopen()-style embedding, just without the C API.
        warn "falling back to a dynamic Rust.xcframework"
        find_ios_dylib runtime_driver librustc_driver \
            || die "no librustc_driver-*.dylib for ${HOST_TRIPLE} (searched: ${XCFRAMEWORK_SEARCH_DIRS[*]})"
        find_ios_dylib runtime_std libstd \
            || die "no libstd-*.dylib for ${HOST_TRIPLE} (searched: ${XCFRAMEWORK_SEARCH_DIRS[*]})"
        log "compiler dylib: ${runtime_driver}"
        # Keep the original file name: the install_name inside the dylib
        # (@rpath/librustc_driver-<hash>.dylib) has to stay resolvable.
        library="$(basename "${runtime_driver}")"
        cp -f "${runtime_driver}" "${out_dir}/lib/"
        cp -f "${runtime_std}" "${out_dir}/lib/"
        make_relocatable "${out_dir}/lib"
    fi

    local kind="dynamic"
    [[ "${static_lib}" == "true" ]] && kind="static"
    local extra=('"c_api": '"${c_api}" '"library": "'"${kind}"'"')
    write_build_info "${out_dir}" "${extra[@]}"

    if [[ "$(uname -s)" == "Darwin" ]] && command -v codesign >/dev/null 2>&1; then
        sign_tree "${out_dir}/lib"
    fi

    log "creating ${XCFRAMEWORK_NAME}"
    rm -rf "${xcfw}"
    slice="${xcfw}/ios-arm64"
    mkdir -p "${slice}"
    cp -a "${out_dir}/lib/." "${slice}/"
    if [[ "${has_headers}" == "true" ]]; then
        cp -a "${out_dir}/Headers" "${slice}/"
    fi
    write_xcframework_plist "${xcfw}/Info.plist" "ios-arm64" "${library}" "${has_headers}"

    if [[ "${static_lib}" == "true" ]]; then
        check_static_library "${slice}/${library}"
        [[ -f "${slice}/Headers/rustios.h" ]] || die "Headers/rustios.h is missing"
    else
        desc="$(file -b "${slice}/${library}")"
        [[ "${desc}" == *"Mach-O 64-bit dynamically linked shared library arm64"* ]] \
            || die "${library} is not an arm64 dylib: ${desc}"
        archs="$(lipo -archs "${slice}/${library}")"
        [[ " ${archs} " == *" arm64 "* ]] || die "${library} has no arm64 slice: ${archs}"
        if command -v vtool >/dev/null 2>&1; then
            build_info="$(vtool -show-build "${slice}/${library}")"
            [[ "${build_info}" == *"platform IOS"* ]] \
                || die "${library} was not linked for iOS"
            [[ "${build_info}" == *"minos ${IOS_DEPLOYMENT_TARGET}"* ]] \
                || warn "${library} deployment target is not ${IOS_DEPLOYMENT_TARGET}"
        fi
    fi

    local a="${ARTIFACTS_DIR}/${XCFRAMEWORK_NAME}-${PACKAGE_PREFIX}-${RUST_VERSION}.tar.xz"
    log "creating ${a}"
    tar_xz "${out_dir}" "${XCFRAMEWORK_NAME}" "${a}"
    checksum "${a}"
    log "xcframework: $(human_size "${a}") (${kind}, c_api=${c_api}, library=${library})"
}

# ---------------------------------------------------------------------------
# misc
# ---------------------------------------------------------------------------

info() {
    cat <<EOF
rustios build configuration

  The product is an iOS toolchain. macOS is only the machine that runs the
  build (Xcode + the iPhoneOS SDK are required for that); nothing built for
  macOS is shipped.

  rust version            : ${RUST_VERSION} (${RUST_CHANNEL})
  iOS deployment target   : ${IOS_DEPLOYMENT_TARGET}
  product runs on (host)  : ${HOST_TRIPLE} (iOS/arm64)
  product compiles for    : ${HOST_TRIPLE} (iOS/arm64)
  build machine (macOS)   : ${BUILD_TRIPLE} (not shipped)
  stage                   : ${STAGE}
  LLVM targets            : ${LLVM_TARGETS}
  rust sources            : ${RUST_SOURCE_DIR}
  build dir               : ${BUILD_DIR}
  work dir                : ${WORK_DIR}
  artifacts dir           : ${ARTIFACTS_DIR}
  packages (all iOS/arm64):
                          ${TOOLCHAIN_NAME}-${PACKAGE_PREFIX}-${RUST_VERSION}.tar.xz
                          ${TOOLCHAIN_NAME}-${PACKAGE_PREFIX}-${RUST_VERSION}-usr.tar.xz
                          ${SUPPORT_NAME}-${PACKAGE_PREFIX}-${RUST_VERSION}.tar.xz
                          ${XCFRAMEWORK_NAME}-${PACKAGE_PREFIX}-${RUST_VERSION}.tar.xz
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
             ARTIFACTS_DIR, RUSTIOS_BUILD_PHASE (host|target|all)

'build' runs both phases by default: the stage1 compiler for this machine
(needed to compile for iOS) and then the compiler that runs on iOS. Set
RUSTIOS_BUILD_PHASE to run one of them, e.g. to cache in between.
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
