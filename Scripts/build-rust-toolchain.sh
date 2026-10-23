#!/usr/bin/env bash
#
# Build a Rust toolchain whose *host* is iOS: i.e. a rustc that runs on an
# arm64 iPhone/iPad (the same idea as https://github.com/emexlab/LLVM-On-iOS,
# which cross-builds Swift/LLVM so that it runs on iOS).
#
# The heavy lifting is done by rust-lang/rust's own bootstrap (`x.py`) using a
# cross-host configuration:
#
#   build  = aarch64-apple-darwin   (the macOS runner that does the work)
#   host   = aarch64-apple-ios      (where the produced rustc runs)
#   target = aarch64-apple-ios      (what the produced rustc compiles for)
#
# See README.md for the full picture.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Configuration (everything can be overridden through the environment)
# ---------------------------------------------------------------------------

RUST_VERSION="${RUST_VERSION:-1.99.1}"
RUST_CHANNEL="${RUST_CHANNEL:-}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-16.0}"

HOST_TRIPLE="${HOST_TRIPLE:-aarch64-apple-ios}"
STAGE="${STAGE:-2}"
LLVM_TARGETS="${LLVM_TARGETS:-AArch64}"
LLVM_EXPERIMENTAL_TARGETS="${LLVM_EXPERIMENTAL_TARGETS:-}"

RUST_SOURCE_DIR="${RUST_SOURCE_DIR:-${ROOT}/rust-source}"
BUILD_DIR="${BUILD_DIR:-${ROOT}/rust-build}"
WORK_DIR="${WORK_DIR:-${ROOT}/work}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-${ROOT}/artifacts}"

PACKAGE_SUFFIX="${PACKAGE_SUFFIX:-iphoneos-arm64}"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-${WORK_DIR}/RustToolchain}"
PACKAGE_BASENAME="RustToolchain-${PACKAGE_SUFFIX}-${RUST_VERSION}"

JOBS="${JOBS:-}"
BUILD_XCFRAMEWORK="${BUILD_XCFRAMEWORK:-true}"
SIGN_TOOLCHAIN="${SIGN_TOOLCHAIN:-true}"
TAR_XZ_LEVEL="${TAR_XZ_LEVEL:-6}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { printf '\033[32m\033[1m[*]\033[0m \033[32m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m\033[1m[!]\033[0m \033[33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m\033[1m[x]\033[0m \033[31m%s\033[0m\n' "$*" >&2; exit 1; }

require_tool() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  fetch        Clone the Rust sources (tag \${RUST_VERSION}) plus the two
               submodules that are needed to build the compiler and std.
  configure    Write rust-source/bootstrap.toml with the iOS cross-host setup.
  build        Run x.py build --stage \${STAGE} (rustc for aarch64-apple-ios).
  package      Assemble RustToolchain/ and write the .tar.xz artifact.
  support      Write the CoreCompilerSupportLibs-style support library archive.
  xcframework  Build Rust.xcframework (rustc as a static library + C header).
  verify       Sanity-check the produced iOS binaries.
  all          fetch + configure + build + verify + package + support (+ xcframework).
  clean        Remove build outputs (keeps the Rust checkout).
  clean-all    Remove build outputs *and* the Rust checkout.
  info         Print the effective configuration.

Environment:
  RUST_VERSION=${RUST_VERSION}
  RUST_CHANNEL=${RUST_CHANNEL:-<auto>}
  IOS_DEPLOYMENT_TARGET=${IOS_DEPLOYMENT_TARGET}
  HOST_TRIPLE=${HOST_TRIPLE}
  STAGE=${STAGE}
  RUST_SOURCE_DIR=${RUST_SOURCE_DIR}
  ARTIFACTS_DIR=${ARTIFACTS_DIR}
  JOBS=${JOBS:-<nproc>}
  BUILD_XCFRAMEWORK=${BUILD_XCFRAMEWORK}
EOF
}

is_macos() { [[ "$(uname -s)" == "Darwin" ]]; }

detect_build_triple() {
    case "$(uname -m)" in
        arm64|aarch64) echo "aarch64-apple-darwin" ;;
        x86_64)        echo "x86_64-apple-darwin" ;;
        *)             die "unsupported build machine: $(uname -m)" ;;
    esac
}

BUILD_TRIPLE="${BUILD_TRIPLE:-$(detect_build_triple)}"

# The build machine's own LLVM must be able to codegen for the build arch
# (build scripts, proc macros and the stage1 compiler are built for it), so an
# Intel build host needs the X86 backend in addition to AArch64.
if [[ "${BUILD_TRIPLE}" == x86_64-* && "${LLVM_TARGETS}" != *X86* ]]; then
    LLVM_TARGETS="${LLVM_TARGETS};X86"
fi

if [[ -z "${RUST_CHANNEL}" ]]; then
    case "${RUST_VERSION}" in
        nightly*|dev*) RUST_CHANNEL="nightly" ;;
        *)             RUST_CHANNEL="stable" ;;
    esac
fi

sysroot_dir() { echo "${BUILD_DIR}/${HOST_TRIPLE}/stage${STAGE}"; }
stage1_dir()  { echo "${BUILD_DIR}/${BUILD_TRIPLE}/stage1"; }
llvm_dir()    { echo "${BUILD_DIR}/${HOST_TRIPLE}/llvm"; }
sdk_path()    { xcrun --sdk iphoneos --show-sdk-path; }
rust_src_version() { cat "${RUST_SOURCE_DIR}/src/version" 2>/dev/null || echo "${RUST_VERSION}"; }

# shasum (macOS) / sha256sum (Linux); writes one "<hash>  <file>" line.
sha256_one() {
    local file="$1"
    if command -v shasum >/dev/null 2>&1; then
        ( cd "$(dirname "${file}")" && shasum -a 256 "$(basename "${file}")" )
    else
        ( cd "$(dirname "${file}")" && sha256sum "$(basename "${file}")" )
    fi
}

checksum() {
    local file="$1"
    mkdir -p "${ARTIFACTS_DIR}"
    sha256_one "${file}" >> "${ARTIFACTS_DIR}/SHA256SUMS.txt"
}

# compress <parent-dir> <entry> <out-file> [xz-level]
compress() {
    local parent="$1" entry="$2" out="$3" level="${4:-${TAR_XZ_LEVEL}}"
    mkdir -p "$(dirname "${out}")"
    rm -f "${out}"
    if command -v xz >/dev/null 2>&1; then
        ( cd "${parent}" && XZ_OPT="-T0 -${level}" tar -cJf "${out}" "${entry}" )
    else
        warn "xz not found; falling back to gzip"
        ( cd "${parent}" && tar -czf "${out%.xz}.tar.gz" "${entry}" )
        printf '%s\n' "${out%.xz}.tar.gz"
    fi
}

human_size() { du -h "$1" 2>/dev/null | cut -f1; }

# ---------------------------------------------------------------------------
# fetch
# ---------------------------------------------------------------------------

fetch() {
    require_tool git

    local url="https://github.com/rust-lang/rust.git"
    local needs_clone=1

    if [[ -d "${RUST_SOURCE_DIR}/.git" ]]; then
        local current
        current="$(git -C "${RUST_SOURCE_DIR}" describe --tags --exact-match 2>/dev/null || true)"
        if [[ "${current}" == "${RUST_VERSION}" ]]; then
            log "reusing Rust checkout at ${RUST_SOURCE_DIR} (${RUST_VERSION})"
            needs_clone=0
        elif [[ -n "${current}" ]]; then
            log "replacing Rust checkout (${current} -> ${RUST_VERSION})"
            rm -rf "${RUST_SOURCE_DIR}"
        else
            log "reusing Rust checkout at ${RUST_SOURCE_DIR} (unknown revision)"
            needs_clone=0
        fi
    fi

    if [[ "${needs_clone}" -eq 1 ]]; then
        mkdir -p "$(dirname "${RUST_SOURCE_DIR}")"
        log "cloning rust ${RUST_VERSION} (shallow)"
        git clone --depth 1 --branch "${RUST_VERSION}" "${url}" "${RUST_SOURCE_DIR}"
    fi

    # Only these two submodules are required: src/llvm-project carries the
    # rust-lang LLVM fork, library/backtrace is a std dependency.
    log "updating required submodules (src/llvm-project, library/backtrace)"
    if ! git -C "${RUST_SOURCE_DIR}" submodule update --init --depth 1 -- \
            src/llvm-project library/backtrace; then
        warn "shallow submodule fetch failed; retrying without --depth"
        git -C "${RUST_SOURCE_DIR}" submodule update --init -- \
            src/llvm-project library/backtrace
    fi

    [[ -f "${RUST_SOURCE_DIR}/src/llvm-project/llvm/CMakeLists.txt" ]] \
        || die "src/llvm-project is missing; submodule checkout failed"
    [[ -f "${RUST_SOURCE_DIR}/library/backtrace/Cargo.toml" ]] \
        || die "library/backtrace is missing; submodule checkout failed"
    [[ -f "${RUST_SOURCE_DIR}/x.py" ]] || die "x.py not found in ${RUST_SOURCE_DIR}"

    log "rust sources ready: $(git -C "${RUST_SOURCE_DIR}" rev-parse --short HEAD)"
}

# ---------------------------------------------------------------------------
# bootstrap patch: build a real iOS LLVM
#
# Upstream bootstrap forces CMAKE_SYSTEM_NAME=Darwin, CMAKE_OSX_SYSROOT=/
# and an empty deployment target whenever it cross-builds LLVM for an Apple
# mobile target. That is fine for compiler-rt but a *full* LLVM build then
# compiles against "/" instead of the iPhoneOS SDK, so the resulting objects
# are not iOS objects (or the build fails outright).
#
# rustios patches that block so that, when RUSTIOS_IOS_SDK is set, LLVM is
# built with the proper CMake iOS toolchain settings. This mirrors the
# LLVM-On-iOS approach of patching Swift's build system for iphoneos.
# ---------------------------------------------------------------------------

patch_bootstrap_llvm() {
    local file="${RUST_SOURCE_DIR}/src/bootstrap/src/core/build_steps/llvm.rs"
    [[ -f "${file}" ]] || { warn "bootstrap llvm.rs not found; skipping iOS LLVM patch"; return 0; }
    require_tool python3

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
# configure
# ---------------------------------------------------------------------------

configure() {
    [[ -d "${RUST_SOURCE_DIR}" ]] || die "missing ${RUST_SOURCE_DIR}; run 'fetch' first"

    local config="${RUST_SOURCE_DIR}/bootstrap.toml"
    local install_prefix="${WORK_DIR}/install"

    local ccache_line="" jobs_line=""
    if command -v sccache >/dev/null 2>&1; then
        ccache_line='ccache = "sccache"'
        log "sccache found: rustc + LLVM compilations will be cached"
    elif command -v ccache >/dev/null 2>&1; then
        ccache_line='ccache = "ccache"'
        log "ccache found: rustc + LLVM compilations will be cached"
    fi
    [[ -n "${JOBS}" ]] && jobs_line="jobs = ${JOBS}"

    log "writing ${config}"
    cat > "${config}" <<EOF
# Generated by Scripts/build-rust-toolchain.sh -- do not edit by hand.
#
# Cross-host bootstrap: the compiler is built *on* ${BUILD_TRIPLE}
# and *for* ${HOST_TRIPLE} (the same platform LLVM-On-iOS targets).

[build]
build = "${BUILD_TRIPLE}"
host = ["${HOST_TRIPLE}"]
target = ["${HOST_TRIPLE}"]
build-dir = "${BUILD_DIR}"
docs = false
compiler-docs = false
extended = false
# Scripts/build-rust-toolchain.sh fetches only src/llvm-project and
# library/backtrace; do not let x.py pull cargo/gcc/enzyme/rustc-perf as well.
submodules = false
locked-deps = true
# Sanitizer runtimes use compiler-rt's own (macOS-flavoured) CMake setup, which
# the rustios LLVM patch intentionally bypasses. Build LLVM only.
sanitizers = false
${jobs_line}
${ccache_line}

[install]
prefix = "${install_prefix}"

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
llvm-tools = false
remap-debuginfo = false

[llvm]
# The LLVM linked into the iOS rustc must itself be built for iOS, so the
# macOS CI LLVM cannot be used. Both LLVM copies (build host + iOS host) are
# built locally into build/<triple>/llvm and cached by the CI workflow.
download-ci-llvm = false
optimize = true
assertions = false
tests = false
ninja = true
targets = "${LLVM_TARGETS}"
experimental-targets = "${LLVM_EXPERIMENTAL_TARGETS}"
link-shared = false
static-libstdcpp = false
libzstd = false
clang = false
enable-warnings = false
EOF

    patch_bootstrap_llvm

    log "bootstrap.toml written (host=${HOST_TRIPLE}, channel=${RUST_CHANNEL}, iOS ${IOS_DEPLOYMENT_TARGET})"
}

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

build() {
    is_macos || die "'build' requires macOS (Xcode + iPhoneOS SDK)"
    require_tool python3
    require_tool xcrun

    [[ -f "${RUST_SOURCE_DIR}/bootstrap.toml" ]] || configure

    local sdk
    sdk="$(sdk_path)" || die "could not locate the iPhoneOS SDK (xcrun --sdk iphoneos)"
    [[ -d "${sdk}" ]] || die "iPhoneOS SDK not found: ${sdk}"

    export IPHONEOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}"
    # Read by the rustios bootstrap patch (LLVM for iOS).
    export RUSTIOS_IOS_SDK="${sdk}"
    export RUSTIOS_IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}"
    # Deliberately do NOT export SDKROOT: bootstrap compiles host tools (LLVM,
    # build scripts, ...) with the macOS SDK, and an inherited SDKROOT pointing
    # at the iPhoneOS SDK would break those builds.

    if command -v sccache >/dev/null 2>&1; then
        export SCCACHE_GHA_ENABLED="${SCCACHE_GHA_ENABLED:-true}"
        export SCCACHE_CACHE_SIZE="${SCCACHE_CACHE_SIZE:-10G}"
    fi

    log "iPhoneOS SDK: ${sdk}"
    log "building rustc ${RUST_VERSION} for ${HOST_TRIPLE} (stage ${STAGE})"
    log "cold build: LLVM x2 + rustc x2 + std; expect roughly 1.5-3h on a 3-core runner"

    local xargs=(build "--stage" "${STAGE}")
    [[ -n "${JOBS}" ]] && xargs+=("-j" "${JOBS}")
    if [[ -n "${EXTRA_XARGS:-}" ]]; then
        # shellcheck disable=SC2206
        xargs+=(${EXTRA_XARGS})
    fi

    ( cd "${RUST_SOURCE_DIR}" && python3 ./x.py "${xargs[@]}" )
}

# ---------------------------------------------------------------------------
# packaging
# ---------------------------------------------------------------------------

write_build_info() {
    local out="$1" rust_sha llvm_sha built_at version
    rust_sha="$(git -C "${RUST_SOURCE_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"
    llvm_sha="$(git -C "${RUST_SOURCE_DIR}/src/llvm-project" rev-parse HEAD 2>/dev/null || echo unknown)"
    built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    version="$(rust_src_version)"

    cat > "${out}" <<EOF
{
  "name": "rustios",
  "rust_version": "${version}",
  "rust_channel": "${RUST_CHANNEL}",
  "rust_commit": "${rust_sha}",
  "llvm_commit": "${llvm_sha}",
  "build_triple": "${BUILD_TRIPLE}",
  "host_triple": "${HOST_TRIPLE}",
  "target_triple": "${HOST_TRIPLE}",
  "ios_deployment_target": "${IOS_DEPLOYMENT_TARGET}",
  "llvm_targets": "${LLVM_TARGETS}",
  "stage": ${STAGE},
  "built_at": "${built_at}"
}
EOF
}

write_usage_doc() {
    local dest="$1" version
    version="$(rust_src_version)"

    cat > "${dest}/USAGE.md" <<EOF
# RustToolchain for iOS (${PACKAGE_SUFFIX})

Built from Rust ${version} (${RUST_CHANNEL}) by rustios.

* host (where rustc runs): \`${HOST_TRIPLE}\`
* target (what rustc compiles for): \`${HOST_TRIPLE}\`
* iOS deployment target: \`${IOS_DEPLOYMENT_TARGET}\`
* LLVM targets: \`${LLVM_TARGETS}\`

## Layout

\`\`\`
RustToolchain/usr/bin/rustc
RustToolchain/usr/bin/rustdoc
RustToolchain/usr/lib/rustlib/${HOST_TRIPLE}/lib/*.rlib
RustToolchain/usr/lib/rustlib/${HOST_TRIPLE}/codegen-backends/*.dylib
RustToolchain/build-info.json
\`\`\`

## Usage on a device

\`\`\`sh
export RUST_DIR=/path/to/RustToolchain/usr
export PATH="\$RUST_DIR/bin:\$PATH"

rustc --edition 2021 -C opt-level=2 hello.rs -o hello
\`\`\`

The toolchain does not include cargo (see README). On device \`rustc\` needs a
linker (\`ld\`/\`ld64\`) and an iPhoneOS SDK, exactly like the Swift toolchain
produced by LLVM-On-iOS.

Every Mach-O in this archive is ad-hoc signed (\`codesign -s -\`) so that
\`dyld\`/\`dlopen\` accepts it on jailbroken / TrollStore setups. Re-sign with
your own identity when you ship it inside an app.
EOF
}

sign_tree() {
    local dir="$1" file count=0
    while IFS= read -r file; do
        case "$(file -b "${file}" 2>/dev/null || true)" in
            *Mach-O*)
                if codesign --force --sign - --timestamp=none "${file}" >/dev/null 2>&1; then
                    count=$((count + 1))
                fi
                ;;
        esac
    done < <(find "${dir}" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.a' \))
    [[ "${count}" -gt 0 ]] && log "ad-hoc signed ${count} Mach-O files"
}

package_toolchain() {
    local sysroot out
    sysroot="$(sysroot_dir)"

    [[ -d "${sysroot}" ]] || die "missing build output ${sysroot}; run 'build' first"
    [[ -x "${sysroot}/bin/rustc" ]] || die "missing ${sysroot}/bin/rustc"

    log "assembling ${TOOLCHAIN_DIR}"
    rm -rf "${TOOLCHAIN_DIR}"
    mkdir -p "${TOOLCHAIN_DIR}/usr"
    cp -a "${sysroot}/." "${TOOLCHAIN_DIR}/usr/"

    # Build-only metadata that is useless on device.
    find "${TOOLCHAIN_DIR}" -name '.rustc_info.json' -delete 2>/dev/null || true
    find "${TOOLCHAIN_DIR}" -name '*.dSYM' -type d -prune -exec rm -rf {} + 2>/dev/null || true

    write_usage_doc "${TOOLCHAIN_DIR}"
    write_build_info "${TOOLCHAIN_DIR}/build-info.json"

    if [[ "${SIGN_TOOLCHAIN}" == "true" ]] && is_macos && command -v codesign >/dev/null 2>&1; then
        sign_tree "${TOOLCHAIN_DIR}"
    fi

    out="${ARTIFACTS_DIR}/${PACKAGE_BASENAME}.tar.xz"
    log "compressing ${out}"
    compress "${WORK_DIR}" "RustToolchain" "${out}"
    out="$( [[ -f "${out}" ]] && echo "${out}" || echo "${out%.xz}.tar.gz" )"
    checksum "${out}"
    log "toolchain: ${out} ($(human_size "${out}"))"
}

# ---------------------------------------------------------------------------
# support libraries (LLVM-On-iOS' CoreCompilerSupportLibs analogue)
# ---------------------------------------------------------------------------

package_support_libs() {
    local llvm libdir out_dir out
    llvm="$(llvm_dir)"
    libdir="$(sysroot_dir)/lib/rustlib/${HOST_TRIPLE}/lib"

    [[ -d "${llvm}/lib" ]] || die "missing iOS LLVM at ${llvm}/lib; run 'build' first"
    [[ -d "${libdir}" ]]   || die "missing std at ${libdir}"

    out_dir="${WORK_DIR}/RustSupportLibs"
    rm -rf "${out_dir}"
    mkdir -p "${out_dir}/llvm/lib" "${out_dir}/rustlib/lib"

    log "collecting iOS LLVM static libraries"
    cp -a "${llvm}/lib/"*.a "${out_dir}/llvm/lib/" 2>/dev/null || true
    cp -a "${llvm}/bin/llvm-config" "${out_dir}/llvm/" 2>/dev/null || true
    cp -a "${libdir}/"*.rlib "${out_dir}/rustlib/lib/" 2>/dev/null || true
    cp -a "$(sysroot_dir)/lib/rustlib/${HOST_TRIPLE}/codegen-backends" \
          "${out_dir}/rustlib/" 2>/dev/null || true

    cat > "${out_dir}/README.md" <<EOF
# RustSupportLibs (${PACKAGE_SUFFIX})

Support libraries produced by rustios (analogue of LLVM-On-iOS'
\`CoreCompilerSupportLibs\`).

* \`llvm/lib/*.a\` - LLVM static libraries built for \`${HOST_TRIPLE}\`
* \`llvm/llvm-config\` - llvm-config for \`${HOST_TRIPLE}\` (not runnable on macOS)
* \`rustlib/lib/*.rlib\` - the Rust standard library for \`${HOST_TRIPLE}\`
* \`rustlib/codegen-backends/*.dylib\` - codegen backends for \`${HOST_TRIPLE}\`

They are useful when linking against \`Rust.xcframework\` manually, or when
rebuilding parts of the toolchain from inside an iOS app.
EOF

    out="${ARTIFACTS_DIR}/RustSupportLibs-${PACKAGE_SUFFIX}-${RUST_VERSION}.tar.xz"
    log "compressing ${out}"
    compress "${WORK_DIR}" "RustSupportLibs" "${out}" 1
    out="$( [[ -f "${out}" ]] && echo "${out}" || echo "${out%.xz}.tar.gz" )"
    checksum "${out}"
    log "support libs: ${out} ($(human_size "${out}"))"
}

# ---------------------------------------------------------------------------
# xcframework (rustc as a static library that can be embedded in an iOS app)
# ---------------------------------------------------------------------------

build_xcframework() {
    local stage1 ios_sysroot work rlib
    stage1="$(stage1_dir)"
    ios_sysroot="$(sysroot_dir)"
    work="${WORK_DIR}/xcframework"

    [[ -x "${stage1}/bin/rustc" ]] || die "missing host compiler at ${stage1}/bin/rustc"
    [[ -d "${ios_sysroot}" ]]      || die "missing iOS sysroot at ${ios_sysroot}"

    shopt -s nullglob
    local driver_rlibs=(
        "${ios_sysroot}"/lib/rustlib/"${HOST_TRIPLE}"/lib/librustc_driver-*.rlib
        "${ios_sysroot}"/lib/librustc_driver-*.rlib
    )
    shopt -u nullglob
    if [[ "${#driver_rlibs[@]}" -eq 0 ]]; then
        # Layout differs between bootstrap versions; fall back to a search.
        local found
        found="$(find "${ios_sysroot}" -name 'librustc_driver-*.rlib' -print -quit 2>/dev/null || true)"
        [[ -n "${found}" ]] && driver_rlibs=("${found}")
    fi
    [[ "${#driver_rlibs[@]}" -gt 0 ]] \
        || die "librustc_driver rlib not found in ${ios_sysroot}; cannot build a driver library"
    rlib="${driver_rlibs[0]}"

    rm -rf "${work}"
    mkdir -p "${work}/Headers" "${work}/sysroot/lib/rustlib"

    # Merged sysroot: the stage1 rustc needs its macOS codegen backend, while
    # std + rustc_private crates for the iOS target come from the freshly
    # produced iOS sysroot.
    ln -sfn "${stage1}/lib/rustlib/${BUILD_TRIPLE}" "${work}/sysroot/lib/rustlib/${BUILD_TRIPLE}"
    ln -sfn "${ios_sysroot}/lib/rustlib/${HOST_TRIPLE}" "${work}/sysroot/lib/rustlib/${HOST_TRIPLE}"

    cp -a "${SCRIPT_DIR}/rustios-driver/rustios_driver.rs" "${work}/"
    cp -a "${SCRIPT_DIR}/rustios-driver/include/rustios.h" "${work}/Headers/"

    log "building librustc_driver static library for ${HOST_TRIPLE}"
    RUSTC_BOOTSTRAP=1 \
    RUSTIOS_VERSION="${RUST_VERSION}" \
    IPHONEOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}" \
        "${stage1}/bin/rustc" \
            --edition 2021 \
            --crate-name rustios_driver \
            --crate-type staticlib \
            --target "${HOST_TRIPLE}" \
            --sysroot "${work}/sysroot" \
            -L "dependency=$(dirname "${rlib}")" \
            -C opt-level=3 \
            -C debuginfo=0 \
            -C panic=unwind \
            -C lto=no \
            -o "${work}/libRustCompiler.a" \
            "${work}/rustios_driver.rs"

    write_build_info "${work}/Headers/build-info.json"

    log "creating Rust.xcframework"
    xcodebuild -create-xcframework \
        -library "${work}/libRustCompiler.a" \
        -headers "${work}/Headers" \
        -output "${work}/Rust.xcframework"

    local out="${ARTIFACTS_DIR}/Rust.xcframework-${PACKAGE_SUFFIX}-${RUST_VERSION}.tar.xz"
    log "compressing ${out}"
    compress "${work}" "Rust.xcframework" "${out}" 1
    out="$( [[ -f "${out}" ]] && echo "${out}" || echo "${out%.xz}.tar.gz" )"
    checksum "${out}"
    log "xcframework: ${out} ($(human_size "${out}"))"
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------

verify() {
    local sysroot rustc
    sysroot="$(sysroot_dir)"
    rustc="${sysroot}/bin/rustc"

    [[ -x "${rustc}" ]] || die "missing ${rustc}"

    log "verifying ${rustc}"
    file "${rustc}" | grep -q 'Mach-O 64-bit executable arm64' \
        || die "rustc is not an arm64 Mach-O executable"
    lipo -archs "${rustc}" | grep -qw 'arm64' \
        || die "rustc does not contain an arm64 slice"

    if command -v vtool >/dev/null 2>&1; then
        log "LC_BUILD_VERSION of rustc:"
        vtool -show-build "${rustc}" | sed 's/^/    /'
        vtool -show-build "${rustc}" | grep -q 'platform IOS' \
            || die "rustc was not linked for the iOS platform"
    fi

    shopt -s nullglob
    local std_rlibs=("${sysroot}/lib/rustlib/${HOST_TRIPLE}"/lib/libstd-*.rlib)
    shopt -u nullglob
    [[ "${#std_rlibs[@]}" -gt 0 ]] || die "std for ${HOST_TRIPLE} is missing"
    [[ -d "${sysroot}/lib/rustlib/${HOST_TRIPLE}/codegen-backends" ]] \
        || die "codegen backends for ${HOST_TRIPLE} are missing"

    log "rustc, std and codegen backends are valid iOS/arm64 artifacts"
}

# ---------------------------------------------------------------------------
# misc
# ---------------------------------------------------------------------------

info() {
    cat <<EOF
rustios build configuration
  rust version          : ${RUST_VERSION} (${RUST_CHANNEL})
  build triple          : ${BUILD_TRIPLE}
  host triple           : ${HOST_TRIPLE}
  target triple         : ${HOST_TRIPLE}
  iOS deployment target : ${IOS_DEPLOYMENT_TARGET}
  LLVM targets          : ${LLVM_TARGETS}
  stage                 : ${STAGE}
  rust source           : ${RUST_SOURCE_DIR}
  build dir             : ${BUILD_DIR}
  artifacts             : ${ARTIFACTS_DIR}
  package               : ${PACKAGE_BASENAME}
  xcframework           : ${BUILD_XCFRAMEWORK}
EOF
}

clean() {
    log "removing ${WORK_DIR} and ${ARTIFACTS_DIR}"
    rm -rf "${WORK_DIR}" "${ARTIFACTS_DIR}"
    log "removing build output (${BUILD_DIR})"
    rm -rf "${BUILD_DIR}"
}

clean_all() {
    clean
    log "removing Rust checkout (${RUST_SOURCE_DIR})"
    rm -rf "${RUST_SOURCE_DIR}"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

case "${1:-}" in
    fetch)        fetch ;;
    configure)    configure ;;
    build)        build ;;
    package)      package_toolchain ;;
    support)      package_support_libs ;;
    xcframework)  build_xcframework ;;
    verify)       verify ;;
    info)         info ;;
    all)
        fetch
        configure
        build
        verify
        package_toolchain
        package_support_libs
        if [[ "${BUILD_XCFRAMEWORK}" == "true" ]]; then
            build_xcframework
        fi
        ;;
    clean)        clean ;;
    clean-all)    clean_all ;;
    ""|-h|--help|help) usage ;;
    *) usage; die "unknown command: $1" ;;
esac
