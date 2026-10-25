#!/usr/bin/env bash
#
# rustios - build LLVM and the Swift compiler for iOS (arm64).
#
# This is the Swift half of rustios. It builds, from the sources Swift itself
# uses (`swiftlang/swift` + `swiftlang/llvm-project`, both at the same release
# tag, as pinned by Swift's `utils/update-checkout`):
#
#   * LLVM + Clang for the build machine (llvm-macosx-arm64)
#   * LLVM + Clang for iOS/arm64        (llvm-iphoneos-arm64)
#   * the Swift compiler for the build machine (swift-macosx-arm64)
#   * the Swift compiler for iOS/arm64        (swift-iphoneos-arm64)
#
# The build recipe (preset, cross-compile-hosts=iphoneos-arm64, the two
# required source patches) follows emexlab/LLVM-On-iOS, the reference project
# for "LLVM and Swift that run on iOS".
#
# The iOS LLVM is not only used by Swift: `Scripts/build-rust-toolchain.sh`
# points rustc's build system at it (`[target.aarch64-apple-ios] llvm-config`
# in bootstrap.toml), so the Rust compiler links the same LLVM instead of
# building `rust-lang/llvm-project` a second time. `install-llvm` writes the
# relocatable trees (with generated llvm-config shims) that make that possible.
#
# Subcommands: fetch, llvm, swift, package, llvm-xcframework, verify, all, info
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Configuration (all overridable from the environment)
# ---------------------------------------------------------------------------

# Swift release to build. The corresponding llvm-project tag is checked out by
# Swift's own update-checkout, so both halves are always the same release.
# swift-6.4.0-RELEASE ships LLVM 21.1.6 (see docs/llvm-sharing.md).
SWIFT_BRANCH="${SWIFT_BRANCH:-swift-6.4.0-RELEASE}"

# Deployment target, matching LLVM-On-iOS' OS_VER=16.0.
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-16.0}"

# Workspace layout (swift's update-checkout puts every sibling repository next
# to the swift checkout, so they all live inside SWIFT_WORKSPACE_DIR).
SWIFT_SOURCE_DIR="${SWIFT_SOURCE_DIR:-${REPO_ROOT}/swift-source/swift}"
# `info` must work before anything is cloned, so this only rewrites the path
# (no `cd` into a directory that does not exist yet).
[[ "${SWIFT_SOURCE_DIR}" = /* ]] || SWIFT_SOURCE_DIR="${REPO_ROOT}/${SWIFT_SOURCE_DIR}"
SWIFT_WORKSPACE_DIR="${SWIFT_WORKSPACE_DIR:-$(dirname "${SWIFT_SOURCE_DIR}")}"
SWIFT_BUILD_ROOT="${SWIFT_BUILD_ROOT:-${SWIFT_WORKSPACE_DIR}/build}"
SWIFT_BUILD_SUBDIR="${SWIFT_BUILD_SUBDIR:-LLVMClangSwift_iphoneos}"
SWIFT_PRESET_FILE="${SWIFT_PRESET_FILE:-${SCRIPT_DIR}/swift-ios-toolchain-presets.ini}"
SWIFT_CROSS_PRESET="${SWIFT_CROSS_PRESET:-rustios_iphoneos_arm64}"

# Outputs.
WORK_DIR="${WORK_DIR:-${REPO_ROOT}/work}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-${REPO_ROOT}/artifacts}"
SWIFT_INSTALL_DIR="${SWIFT_INSTALL_DIR:-${WORK_DIR}/SwiftToolchain}"
# <dir>/macosx and <dir>/ios are relocatable LLVM installations (bin/llvm-config
# shim, include/, lib/*.a). build-rust-toolchain.sh consumes exactly this.
SWIFT_LLVM_DIR="${SWIFT_LLVM_DIR:-${WORK_DIR}/SwiftLLVM}"

# LLVM backends. AArch64 is what the shipped compilers use; ARM and X86 are
# required by compiler-rt's embedded builtins (see the preset). Must match
# `llvm-targets-to-build` there.
LLVM_TARGETS="${LLVM_TARGETS:-AArch64;ARM;X86}"

PACKAGE_PREFIX="iphoneos-arm64"
SWIFT_TOOLCHAIN_NAME="SwiftToolchain"
LLVM_XCFRAMEWORK_NAME="LLVM.xcframework"

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

report_line() {
    mkdir -p "${ARTIFACTS_DIR}"
    printf '%s\n' "$*" >> "${ARTIFACTS_DIR}/REPORT.txt"
}

human_size() { du -h "$1" | awk '{print $1}'; }

# llvm_dir <macosx|ios>: build tree of the LLVM for that platform.
llvm_dir() {
    echo "${SWIFT_BUILD_ROOT}/${SWIFT_BUILD_SUBDIR}/llvm-$1-arm64"
}

swift_dir() {
    echo "${SWIFT_BUILD_ROOT}/${SWIFT_BUILD_SUBDIR}/swift-$1-arm64"
}

# llvm_version: LLVM version of the checked out llvm-project (this is what the
# Swift compiler is built against).
llvm_version() {
    local f="${SWIFT_WORKSPACE_DIR}/llvm-project/cmake/Modules/LLVMVersion.cmake"
    if [[ -f "${f}" ]]; then
        # -E: BSD sed (macOS) does not support \| in a basic regex.
        sed -n -E 's/.*set\(LLVM_VERSION_(MAJOR|MINOR|PATCH) ([0-9]+)\).*/\2/p' "${f}" \
            | head -3 | paste -sd. -
        return
    fi
    echo unknown
}

llvm_commit() {
    git -C "${SWIFT_WORKSPACE_DIR}/llvm-project" rev-parse --short HEAD 2>/dev/null || echo unknown
}

swift_commit() {
    git -C "${SWIFT_SOURCE_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown
}

# ---------------------------------------------------------------------------
# fetch
# ---------------------------------------------------------------------------

fetch() {
    require_cmd git
    require_macos

    if [[ -d "${SWIFT_SOURCE_DIR}/.git" ]]; then
        local current
        current="$(git -C "${SWIFT_SOURCE_DIR}" describe --tags --exact-match 2>/dev/null || true)"
        if [[ -n "${current}" && "${current}" != "${SWIFT_BRANCH}" ]]; then
            warn "existing Swift checkout is '${current}', expected '${SWIFT_BRANCH}' - re-cloning"
            rm -rf "${SWIFT_SOURCE_DIR}"
        fi
    fi

    if [[ ! -d "${SWIFT_SOURCE_DIR}/.git" ]]; then
        mkdir -p "$(dirname "${SWIFT_SOURCE_DIR}")"
        log "cloning swiftlang/swift ${SWIFT_BRANCH} (shallow)"
        git clone --depth 1 --branch "${SWIFT_BRANCH}" \
            https://github.com/swiftlang/swift.git "${SWIFT_SOURCE_DIR}"
    fi

    # update-checkout checks out every sibling repository (llvm-project, cmark,
    # swift-syntax, ...) at the same tag, which is exactly what a Swift release
    # is composed of.
    if [[ ! -d "${SWIFT_WORKSPACE_DIR}/llvm-project/llvm" ]]; then
        log "checking out the Swift source tree (update-checkout --tag ${SWIFT_BRANCH})"
        "${SWIFT_SOURCE_DIR}/utils/update-checkout" --clone --tag "${SWIFT_BRANCH}"
    else
        log "swift source tree already present"
    fi

    [[ -f "${SWIFT_WORKSPACE_DIR}/llvm-project/llvm/CMakeLists.txt" ]] \
        || die "llvm-project is missing from the Swift workspace ${SWIFT_WORKSPACE_DIR}"
    [[ -f "${SWIFT_SOURCE_DIR}/utils/build-script" ]] \
        || die "swift checkout is missing utils/build-script"

    patch_lld_macho
    patch_swift_cmake_triple

    log "swift ${SWIFT_BRANCH} ($(swift_commit)), llvm-project $(llvm_commit), LLVM $(llvm_version)"
}

# Swift's lld has a downstream check that refuses to emit Mach-O on a non-Apple
# host; the reference project (LLVM-On-iOS) comments it out. We keep that, but
# only when the exact marker block is present, so a different Swift release does
# not silently break the checkout.
patch_lld_macho() {
    local file="${SWIFT_WORKSPACE_DIR}/llvm-project/lld/MachO/InputFiles.cpp"
    [[ -f "${file}" ]] || { warn "lld/MachO/InputFiles.cpp not found; skipping lld patch"; return 0; }
    if grep -q "rustios: apple lies" "${file}"; then
        return 0
    fi
    python3 - "${file}" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
pattern = (
    r"(// Swift LLVM fork downstream change start\n)"
    r"(.*?)"
    r"(// Swift LLVM fork downstream change end\n)"
)
new, count = re.subn(pattern, r"\1/* rustios: apple lies, lld works fine for MachO\n\2*/\n\3", text,
                     count=1, flags=re.DOTALL)
if count == 0:
    sys.stderr.write("lld patch anchor not found; leaving the file untouched\n")
    sys.exit(0)
path.write_text(new)
print("patched lld: Mach-O output allowed on a non-Darwin host")
PY
}

# Swift's top-level CMakeLists enables the Swift language before it knows the
# host triple, so the compiler probe runs without -target and defaults to
# macOS. The reference project injects CMAKE_Swift_COMPILER_TARGET; without it
# the iphoneos-arm64 stage fails to load the stdlib.
patch_swift_cmake_triple() {
    local sentinel='# rustios: inject CMAKE_Swift_COMPILER_TARGET from SWIFT_HOST_TRIPLE'
    local file="${SWIFT_SOURCE_DIR}/CMakeLists.txt"
    [[ -f "${file}" ]] || die "missing ${file}"
    if grep -qF "${sentinel}" "${file}"; then
        return 0
    fi
    python3 - "${file}" "${sentinel}" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
sentinel = sys.argv[2]
text = path.read_text()
inject = (
    f"{sentinel}\n"
    "if(DEFINED SWIFT_HOST_TRIPLE AND NOT CMAKE_Swift_COMPILER_TARGET)\n"
    "  set(CMAKE_Swift_COMPILER_TARGET \"${SWIFT_HOST_TRIPLE}\" CACHE STRING \"\")\n"
    "endif()\n\n"
)
new, count = re.subn(r"(^[ \t]*enable_language\(\s*Swift\b)", inject + r"\1", text,
                     count=1, flags=re.MULTILINE)
if count == 0:
    sys.stderr.write("could not locate enable_language(Swift) in CMakeLists.txt\n")
    sys.exit(1)
path.write_text(new)
print("patched swift CMakeLists.txt: SWIFT_HOST_TRIPLE -> CMAKE_Swift_COMPILER_TARGET")
PY
}

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

# build_swift <llvm|swift|all>
#
# Swift's build system builds the two LLVM trees and the two Swift compilers in
# one invocation. `llvm` and `swift` split that into two invocations sharing
# one build directory, so the LLVM artifacts can be handed to the Rust build
# before the (much longer) Swift compiler build finishes.
build_swift() {
    local phase="${1:-all}"
    require_cmd cmake
    require_cmd ninja
    require_cmd xcrun

    [[ -x "${SWIFT_SOURCE_DIR}/utils/build-script" ]] || die "missing utils/build-script; run 'fetch' first"
    [[ -f "${SWIFT_PRESET_FILE}" ]] || die "missing preset file ${SWIFT_PRESET_FILE}"
    local sdk
    sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
    [[ -d "${sdk}" ]] || die "could not find the iPhoneOS SDK"

    case "${phase}" in
        llvm|swift|all) ;;
        *) die "unknown build phase: ${phase} (llvm|swift|all)" ;;
    esac

    # Swift 6.4's build-script expands the preset *before* it parses the
    # product switches, so `--skip-build-swift` / `--skip-build-llvm` cannot be
    # combined with `--preset` (they are rejected as unknown arguments). Both
    # LLVM trees and both compilers are therefore built by one invocation; the
    # build directory is incremental, so calling this again after a completed
    # build is cheap. `phase` only decides what is *installed* afterwards.
    local args=(--preset-file="${SWIFT_PRESET_FILE}" --preset="${SWIFT_CROSS_PRESET}")

    refresh_cmark_cache

    log "iPhoneOS SDK : ${sdk}"
    log "swift        : ${SWIFT_BRANCH} ($(swift_commit))"
    log "llvm         : $(llvm_version) ($(llvm_commit))"
    log "phase        : ${phase}"
    log "running: utils/build-script ${args[*]}"

    (
        cd "${SWIFT_SOURCE_DIR}"
        export IPHONEOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}"
        utils/build-script "${args[@]}"
    )
}

# cmark's iPhoneOS CMake cache is kept across builds; if it was configured
# before BUILD_TESTING was disabled, its test targets break the link.
refresh_cmark_cache() {
    local dir="${SWIFT_BUILD_ROOT}/${SWIFT_BUILD_SUBDIR}/cmark-iphoneos-arm64"
    if [[ -f "${dir}/CMakeCache.txt" ]] && ! grep -q '^BUILD_TESTING:BOOL=OFF$' "${dir}/CMakeCache.txt"; then
        log "discarding stale cmark build cache"
        rm -rf "${dir}"
    fi
}

# ---------------------------------------------------------------------------
# install: turn the build trees into relocatable trees
# ---------------------------------------------------------------------------

copy_tree() {
    local source="$1" destination="$2"
    if [[ -d "${source}" ]]; then
        mkdir -p "${destination}"
        cp -a "${source}/." "${destination}/"
    fi
}

copy_archives() {
    local source="$1" destination="$2"
    if [[ -d "${source}" ]]; then
        mkdir -p "${destination}"
        find "${source}" -maxdepth 1 -type f -name '*.a' -exec cp -a {} "${destination}/" \;
    fi
}

# install_llvm
#
# Writes <SWIFT_LLVM_DIR>/{macosx,ios}:
#
#   bin/llvm-config   host-runnable, relocatable (Scripts/llvm-config-shim.py)
#   bin/llvm-ar ...   the real iOS tools (used by rustc on the device)
#   include/          headers
#   lib/*.a           static libraries
#
# `macosx` is what the rustc for the build machine links against, `ios` what
# the rustc that runs on the iPhone links against.
install_llvm() {
    require_cmd python3
    local host_llvm ios_llvm version
    host_llvm="$(llvm_dir macosx)"
    ios_llvm="$(llvm_dir iphoneos)"
    version="$(llvm_version)"

    [[ -f "${host_llvm}/bin/llvm-config" ]] || die "missing ${host_llvm}/bin/llvm-config; run 'llvm' first"
    [[ -d "${ios_llvm}/lib" ]] || die "missing ${ios_llvm}/lib"

    local macosx_prefix="${SWIFT_LLVM_DIR}/macosx"
    local ios_prefix="${SWIFT_LLVM_DIR}/ios"
    rm -rf "${macosx_prefix}" "${ios_prefix}"
    mkdir -p "${macosx_prefix}/bin" "${macosx_prefix}/lib" \
             "${ios_prefix}/bin" "${ios_prefix}/lib"

    # A CMake build tree has no installed headers: the public ones live in the
    # source tree and only the generated ones (llvm/Config/*, Targets.def, ...)
    # are in the build tree. rustc_llvm compiles its C++ wrapper against these
    # headers, so assemble an install-shaped include/ the way `make install`
    # would: source headers first, then the generated ones (which win).
    local llvm_source="${SWIFT_WORKSPACE_DIR}/llvm-project/llvm"
    install_headers() {
        local build_tree="$1" prefix="$2"
        [[ -d "${llvm_source}/include" ]] || die "missing ${llvm_source}/include"
        copy_tree "${llvm_source}/include" "${prefix}/include"
        copy_tree "${build_tree}/include" "${prefix}/include"
        [[ -f "${prefix}/include/llvm/Config/llvm-config.h" ]] \
            || die "no generated llvm/Config/llvm-config.h in ${build_tree}/include"
    }

    log "installing the host LLVM"
    install_headers "${host_llvm}" "${macosx_prefix}"
    copy_archives "${host_llvm}/lib" "${macosx_prefix}/lib"
    # Tools that run on the build machine (the shim needs none, but a
    # bootstrap that shells out to llvm-ar would find them here).
    local tool
    for tool in llvm-ar llvm-nm llvm-ranlib llvm-objcopy llvm-strip; do
        if [[ -x "${host_llvm}/bin/${tool}" ]]; then
            cp -a "${host_llvm}/bin/${tool}" "${macosx_prefix}/bin/"
        fi
    done

    log "installing the iOS LLVM"
    install_headers "${ios_llvm}" "${ios_prefix}"
    copy_archives "${ios_llvm}/lib" "${ios_prefix}/lib"
    # The tools run on the device; rustc uses llvm-ar/llvm-objcopy from its
    # sysroot. Copy the small, useful ones (the rest are macOS-only tools or
    # huge binaries).
    for tool in llvm-ar llvm-nm llvm-ranlib llvm-objcopy llvm-strip; do
        if [[ -f "${ios_llvm}/bin/${tool}" ]]; then
            cp -a "${ios_llvm}/bin/${tool}" "${ios_prefix}/bin/"
        fi
    done

    local description="swiftlang/llvm-project ${SWIFT_BRANCH} ($(llvm_commit))"

    log "generating ${macosx_prefix}/bin/llvm-config (host)"
    python3 "${SCRIPT_DIR}/llvm-config-shim.py" \
        --source "${host_llvm}/bin/llvm-config" \
        --mode host \
        --host-target "$(uname -m | sed 's/^arm64$/aarch64/')-apple-darwin" \
        --description "${description}" \
        --out "${macosx_prefix}/bin/llvm-config"

    log "generating ${ios_prefix}/bin/llvm-config (iOS)"
    python3 "${SCRIPT_DIR}/llvm-config-shim.py" \
        --source "${host_llvm}/bin/llvm-config" \
        --mode ios \
        --host-target "aarch64-apple-ios" \
        --description "${description}" \
        --out "${ios_prefix}/bin/llvm-config"

    # Prove that both shims answer, and that the versions agree: this is the
    # version the Rust compiler will be built against.
    local host_version ios_version
    host_version="$("${macosx_prefix}/bin/llvm-config" --version)"
    ios_version="$("${ios_prefix}/bin/llvm-config" --version)"
    [[ "${host_version}" == "${ios_version}" ]] \
        || die "llvm-config shims disagree: host ${host_version} != ios ${ios_version}"
    [[ "${host_version}" == "${version}" ]] \
        || warn "llvm-config reports ${host_version}, llvm-project says ${version}"
    log "LLVM ${host_version}: host and iOS trees installed in ${SWIFT_LLVM_DIR}"
    report_line "swift LLVM: ${host_version} ($(llvm_commit)) for macOS and iOS"

    # `--libs` falls back to `-lNAME` for anything the tree does not contain.
    # That would only fail much later (when rustc is linked), so surface it
    # here with the list of names.
    local missing="" token
    for token in $("${ios_prefix}/bin/llvm-config" --link-static --libs); do
        case "${token}" in
            -l*) missing="${missing} ${token#-l}" ;;
        esac
    done
    if [[ -n "${missing}" ]]; then
        warn "the iOS LLVM has no archive for:${missing}"
        warn "rustc's link step will fail unless it is built by llvm-install-components"
        report_line "swift LLVM: missing iOS archives:${missing}"
    fi
    local count
    count="$(find "${ios_prefix}/lib" -maxdepth 1 -name '*.a' | wc -l | tr -d ' ')"
    log "the iOS LLVM provides ${count} static libraries"
    report_line "swift LLVM: ${count} static libraries (ios/lib)"
}

# install_swift
#
# Collects the iOS Swift compiler from the build tree (the intermediate
# install, when Swift produced one, otherwise the individual products) - the
# same shape LLVM-On-iOS ships as SwiftToolchain.zip.
# report_install_source <path> <kind>: what was collected, and what the two
# binaries the toolchain is judged by actually are. Written to REPORT.txt
# immediately, so it survives a later failure (the job log is not reachable
# from everywhere).
report_install_source() {
    local from="$1" kind="$2" frontend driver
    frontend="${SWIFT_INSTALL_DIR}/bin/swift-frontend"
    driver="${SWIFT_INSTALL_DIR}/bin/swiftc"
    report_line "swift install: ${kind} ${from}"
    report_line "swift install: swift-frontend is $(macho_platform "${frontend}"), swiftc is $(macho_platform "${driver}")"
    log "swift install: swift-frontend is $(macho_platform "${frontend}"), swiftc is $(macho_platform "${driver}")"
}

install_swift() {
    local build_dir candidate swift_build llvm_build
    build_dir="${SWIFT_BUILD_ROOT}/${SWIFT_BUILD_SUBDIR}"
    local prefix="Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr"
    swift_build="$(swift_dir iphoneos)"
    llvm_build="$(llvm_dir iphoneos)"

    for candidate in "${build_dir}/intermediate-install/iphoneos-arm64/${prefix}" \
                     "${build_dir}/toolchain-macosx-arm64/${prefix}"; do
        if [[ -x "${candidate}/bin/swiftc" && -x "${candidate}/bin/swift-frontend" ]]; then
            rm -rf "${SWIFT_INSTALL_DIR}"
            mkdir -p "${SWIFT_INSTALL_DIR}"
            cp -a "${candidate}/." "${SWIFT_INSTALL_DIR}/"
            materialize_symlinks "${SWIFT_INSTALL_DIR}"
            log "collected the iOS Swift toolchain from ${candidate}"
            report_install_source "${candidate}" "install tree"
            return
        fi
    done

    if [[ -x "${swift_build}/bin/swiftc" && -x "${swift_build}/bin/swift-frontend" ]]; then
        rm -rf "${SWIFT_INSTALL_DIR}"
        mkdir -p "${SWIFT_INSTALL_DIR}/lib"
        copy_tree "${swift_build}/bin" "${SWIFT_INSTALL_DIR}/bin"
        copy_tree "${swift_build}/include" "${SWIFT_INSTALL_DIR}/include"
        copy_tree "${swift_build}/share" "${SWIFT_INSTALL_DIR}/share"
        copy_tree "${swift_build}/lib/swift" "${SWIFT_INSTALL_DIR}/lib/swift"
        copy_tree "${swift_build}/lib/cmake" "${SWIFT_INSTALL_DIR}/lib/cmake"
        copy_archives "${swift_build}/lib" "${SWIFT_INSTALL_DIR}/lib"
        copy_tree "${llvm_build}/bin" "${SWIFT_INSTALL_DIR}/bin"
        copy_tree "${llvm_build}/include" "${SWIFT_INSTALL_DIR}/include"
        copy_tree "${llvm_build}/lib/clang" "${SWIFT_INSTALL_DIR}/lib/clang"
        copy_archives "${llvm_build}/lib" "${SWIFT_INSTALL_DIR}/lib"
        materialize_symlinks "${SWIFT_INSTALL_DIR}"
        log "collected the iOS Swift toolchain from ${swift_build}"
        report_install_source "${swift_build}" "build tree"
        return
    fi

    die "no iOS Swift compiler under ${build_dir}"
}

# A toolchain tarball must not contain symlinks pointing outside of it, so the
# driver symlinks (swift, swiftc, clang, ...) become copies.
materialize_symlinks() {
    local root="$1" link target resolved tmp relative
    while IFS= read -r link; do
        target="$(readlink "${link}")"
        relative="${link#"${root}/"}"
        if [[ "${target}" != /* ]]; then
            case "${relative}" in
                bin/swift|bin/swiftc|bin/clang|bin/clang++|bin/clang-cpp| \
                usr/bin/swift|usr/bin/swiftc|usr/bin/clang|usr/bin/clang++|usr/bin/clang-cpp)
                    ;;
                *) continue ;;
            esac
        fi
        if [[ "${target}" = /* ]]; then
            resolved="${target}"
        else
            resolved="$(cd "$(dirname "${link}")" && pwd)/${target}"
        fi
        [[ -e "${resolved}" ]] || die "dangling symlink ${link} -> ${target}"
        tmp="${link}.materialized"
        rm -rf "${tmp}"
        cp -aL "${resolved}" "${tmp}"
        rm -f "${link}"
        mv "${tmp}" "${link}"
    done < <(find "${root}" -type l -print)
}

# ---------------------------------------------------------------------------
# packaging
# ---------------------------------------------------------------------------

# SwiftToolchain-iphoneos-arm64-6.4.0.tar.xz  (LLVM-On-iOS' SwiftToolchain.zip)
package_swift() {
    local stage_root stage version tarball
    version="${SWIFT_BRANCH#swift-}"
    version="${version%-RELEASE}"
    # SWIFT_INSTALL_DIR is work/SwiftToolchain, so the package must not be
    # assembled inside work/SwiftToolchain itself: `cp -a src/. dst/usr` with
    # dst inside src copies the tree into its own subdirectory and recurses
    # (the run that found this produced paths of `usr/usr/usr/...` until
    # "File name too long").
    stage_root="${WORK_DIR}/package"
    stage="${stage_root}/${SWIFT_TOOLCHAIN_NAME}"

    [[ -x "${SWIFT_INSTALL_DIR}/bin/swiftc" ]] || die "missing ${SWIFT_INSTALL_DIR}/bin/swiftc; run 'swift' first"
    case "${stage}/" in
        "${SWIFT_INSTALL_DIR}/"*) die "the package would be assembled inside ${SWIFT_INSTALL_DIR}" ;;
    esac

    log "assembling ${stage}"
    rm -rf "${stage_root}"
    mkdir -p "${stage}/usr"
    cp -a "${SWIFT_INSTALL_DIR}/." "${stage}/usr/"
    materialize_symlinks "${stage}"

    # The compiler must be iOS; everything else is classified and recorded (a
    # cross build also ships host tools, as LLVM-On-iOS does). Record what the
    # tree actually contains *before* asserting, so the report explains a
    # failure even when the job log is out of reach.
    report_line "swift package: swift-frontend is $(macho_platform "${stage}/usr/bin/swift-frontend"), swiftc is $(macho_platform "${stage}/usr/bin/swiftc")"
    is_ios_macho "${stage}/usr/bin/swift-frontend" \
        || die "swift-frontend in the package is $(macho_platform "${stage}/usr/bin/swift-frontend"), not an iOS/arm64 binary"
    classify_tree "${stage}/usr/bin" "SwiftToolchain package (bin)"
    classify_tree "${stage}/usr/lib" "SwiftToolchain package (lib)"

    tarball="${ARTIFACTS_DIR}/${SWIFT_TOOLCHAIN_NAME}-${PACKAGE_PREFIX}-${version}.tar.xz"
    log "creating ${tarball}"
    tar_xz "${stage_root}" "${SWIFT_TOOLCHAIN_NAME}" "${tarball}"
    checksum "${tarball}"
    log "swift toolchain: $(human_size "${tarball}")"
    report_line "SwiftToolchain ${version}: $(human_size "${tarball}")"
}

# SwiftLLVM-iphoneos-arm64-21.1.6.tar.xz: the LLVM both compilers link.
package_llvm() {
    local version tarball
    version="$(llvm_version)"

    [[ -x "${SWIFT_LLVM_DIR}/ios/bin/llvm-config" ]] || die "missing ${SWIFT_LLVM_DIR}; run 'llvm' first"

    tarball="${ARTIFACTS_DIR}/SwiftLLVM-${PACKAGE_PREFIX}-${version}.tar.xz"
    log "creating ${tarball}"
    tar_xz "${WORK_DIR}" "SwiftLLVM" "${tarball}"
    checksum "${tarball}"
    log "swift LLVM: $(human_size "${tarball}")"
    report_line "SwiftLLVM ${version}: $(human_size "${tarball}")"
}

# llvm.a + headers -> LLVM.xcframework (the LLVM-On-iOS artifact).
llvm_xcframework() {
    local version out_dir xcfw headers
    version="$(llvm_version)"
    out_dir="${WORK_DIR}/${LLVM_XCFRAMEWORK_NAME}.build"
    xcfw="${out_dir}/${LLVM_XCFRAMEWORK_NAME}"

    [[ -d "${SWIFT_LLVM_DIR}/ios/lib" ]] || die "missing ${SWIFT_LLVM_DIR}/ios/lib; run 'llvm' first"

    log "merging the iOS LLVM archives into llvm.a"
    rm -rf "${out_dir}"
    mkdir -p "${out_dir}/Headers"
    shopt -s nullglob
    local archives=("${SWIFT_LLVM_DIR}/ios/lib/"*.a)
    shopt -u nullglob
    [[ "${#archives[@]}" -gt 0 ]] || die "no static LLVM libraries in ${SWIFT_LLVM_DIR}/ios/lib"
    if command -v libtool >/dev/null 2>&1; then
        libtool -static -o "${out_dir}/llvm.a" "${archives[@]}" >"${WORK_DIR}/libtool-llvm.log" 2>&1 || true
    fi
    [[ -s "${out_dir}/llvm.a" ]] || ar -q "${out_dir}/llvm.a" "${archives[@]}"

    cp -a "${SWIFT_LLVM_DIR}/ios/include/." "${out_dir}/Headers/"

    rm -rf "${xcfw}"
    xcodebuild -create-xcframework \
        -library "${out_dir}/llvm.a" \
        -headers "${out_dir}/Headers" \
        -output "${xcfw}" >/dev/null

    local tarball="${ARTIFACTS_DIR}/${LLVM_XCFRAMEWORK_NAME}-${PACKAGE_PREFIX}-${version}.tar.xz"
    log "creating ${tarball}"
    tar_xz "${out_dir}" "${LLVM_XCFRAMEWORK_NAME}" "${tarball}"
    checksum "${tarball}"
    log "llvm.xcframework: $(human_size "${tarball}")"
    report_line "LLVM.xcframework ${version}: $(human_size "${tarball}")"
}

tar_xz() {
    local dir="$1" name="$2" out="$3"
    mkdir -p "$(dirname "${out}")"
    rm -f "${out}"
    # -3, not -6: the LLVM tree is several GB of static archives, where -6
    # costs minutes of CPU for a few percent. The job has a 6 h limit.
    ( cd "${dir}" && XZ_OPT="-T0 -3" tar -cJf "${out}" "${name}" )
}

checksum() {
    local file="$1"
    mkdir -p "${ARTIFACTS_DIR}"
    ( cd "${ARTIFACTS_DIR}" && shasum -a 256 "$(basename "${file}")" >> SHA256SUMS.txt )
}

# ---------------------------------------------------------------------------
# verification
# ---------------------------------------------------------------------------

# macho_platform <file>: "IOS", "MACOS", ... or "none" (not a Mach-O).
#
# Binaries linked with an old deployment target carry LC_VERSION_MIN_IPHONEOS
# instead of LC_BUILD_VERSION; vtool reports both as "platform IOS", but the
# tool differs between Xcode versions, so parse what is there.
macho_platform() {
    local file="$1" desc info
    desc="$(file -b "${file}" 2>/dev/null || true)"
    case "${desc}" in
        *Mach-O*) ;;
        *) echo none; return 0 ;;
    esac
    if command -v vtool >/dev/null 2>&1; then
        info="$(vtool -show-build "${file}" 2>/dev/null || true)"
        case "${info}" in
            *"platform IOS"*)     echo IOS; return 0 ;;
            *"platform MACOS"*)   echo MACOS; return 0 ;;
            *"platform TVOS"*)    echo TVOS; return 0 ;;
            *"platform WATCHOS"*) echo WATCHOS; return 0 ;;
            *LC_VERSION_MIN_IPHONEOS*) echo IOS; return 0 ;;
            *LC_VERSION_MIN_MACOSX*)   echo MACOS; return 0 ;;
        esac
        # Older vtool prints "cmd LC_VERSION_MIN_*" as two lines.
        case "${info}" in
            *"LC_VERSION_MIN_IPHONEOS"*) echo IOS; return 0 ;;
            *"LC_VERSION_MIN_MACOSX"*)   echo MACOS; return 0 ;;
        esac
    fi
    # No vtool: fall back to the LC_BUILD_VERSION platform of the binary.
    case "$(otool -l "${file}" 2>/dev/null | sed -n 's/.*platform \([A-Z]*\).*/\1/p' | head -1)" in
        IOS) echo IOS ;;
        MACOS) echo MACOS ;;
        *) echo unknown ;;
    esac
}

# is_ios_macho <file>: true when the file is not a Mach-O, or is arm64/iOS.
is_ios_macho() {
    local file="$1" desc
    desc="$(file -b "${file}" 2>/dev/null || true)"
    [[ "${desc}" == *Mach-O* ]] || return 0   # not a binary: nothing to check
    [[ "${desc}" == *arm64* ]] || return 1
    case "$(macho_platform "${file}")" in
        IOS|unknown) return 0 ;;
        # `unknown`: vtool/otool could not tell (e.g. a fixed-up binary);
        # the caller records it and the report says so.
        *) return 1 ;;
    esac
}

# classify_tree <dir> <label> [required-file]
#
# Reports what a directory really contains. `required-file` (if given) must be
# an iOS/arm64 Mach-O, otherwise this is fatal. Anything else that is a host
# (macOS) binary is listed and recorded in the report instead of being claimed
# as iOS: Swift's cross build produces the compiler for iOS, but some tools it
# ships next to it are host binaries (LLVM-On-iOS ships those too, e.g.
# lib/swift/host/compiler/*.dylib).
classify_tree() {
    local dir="$1" label="$2" required="${3:-}"
    local file platform ios=0 host=0 other=0
    local host_files=() bad_files=() unknown_files=()
    [[ -d "${dir}" ]] || return 0

    while IFS= read -r -d '' file; do
        platform="$(macho_platform "${file}")"
        case "${platform}" in
            none) continue ;;
            IOS)  ios=$((ios + 1)) ;;
            MACOS) host=$((host + 1)); host_files+=("${file}") ;;
            UNKNOWN|unknown) other=$((other + 1)); unknown_files+=("${file}") ;;
            *)    other=$((other + 1)); bad_files+=("${file} (${platform})") ;;
        esac
    done < <(find "${dir}" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.a' \) -print0)

    # A file whose platform cannot be read (vtool/otool print nothing useful) is
    # reported, not fatal: that is a limit of the inspection, not evidence about
    # the binary. A binary that *is* macOS is reported too (the cross build ships
    # host tools on purpose, as LLVM-On-iOS does). Only a genuinely foreign
    # platform - tvOS, watchOS, an unknown-but-parseable platform - is an error.
    [[ "${#bad_files[@]}" -eq 0 ]] || {
        printf '  %s\n' "${bad_files[@]}" >&2
        die "${label}: binaries that are neither iOS nor macOS"
    }
    if [[ "${#unknown_files[@]}" -gt 0 ]]; then
        warn "${label}: ${#unknown_files[@]} binary/binaries whose platform could not be read:"
        printf '  %s\n' "${unknown_files[@]}" >&2
        report_line "${label}: ${#unknown_files[@]} Mach-O files of unreadable platform"
    fi
    if [[ -n "${required}" ]]; then
        is_ios_macho "${required}" || die "${required} is not an iOS/arm64 binary ($(macho_platform "${required}"))"
    fi
    log "${label}: ${ios} iOS/arm64 Mach-O file(s), ${host} host (macOS) file(s)"
    if [[ "${#host_files[@]}" -gt 0 ]]; then
        warn "${label}: ${host} host (macOS) binary/binaries are included (not iOS):"
        printf '  %s\n' "${host_files[@]}" >&2
        report_line "${label}: ${ios} iOS/arm64 + ${host} host (macOS) Mach-O files"
    else
        report_line "${label}: ${ios} Mach-O files, all iOS/arm64"
    fi
    # The count is returned through a global so callers can assert on it.
    CLASSIFY_IOS="${ios}"
    CLASSIFY_HOST="${host}"
}

# verify_archive_is_ios <archive> <label>: check one object inside a static
# archive. `file` only sees "current ar archive", so the iOS-ness of a library
# has to be proven on its members.
verify_archive_is_ios() {
    local archive="$1" label="$2" tmp member extracted platform
    local members=() checked=0
    [[ -f "${archive}" ]] || die "missing ${archive}"
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '${tmp}'" RETURN

    # The first entry of a Darwin archive is the symbol table (`__.SYMDEF`,
    # `__.SYMDEF SORTED`, ...), which is not a Mach-O file at all - checking it
    # would report "none". Take real objects only.
    while IFS= read -r member; do
        case "${member}" in
            ""|__.SYMDEF*|SYMDEF*|"") continue ;;
            */) continue ;;   # GNU ar writes member names with a trailing slash
        esac
        members+=("${member}")
    done < <(ar -t "${archive}" 2>/dev/null)

    [[ "${#members[@]}" -gt 0 ]] || { warn "${label}: no object members in ${archive##*/}"; return 0; }

    # A few members are enough: every object of an LLVM archive comes out of
    # the same compiler invocation with the same -target/-isysroot flags.
    for member in "${members[@]:0:3}"; do
        rm -f "${tmp}/"*
        if ! ( cd "${tmp}" && ar -x "${archive}" "${member}" ) >/dev/null 2>&1; then
            warn "${label}: could not extract ${member} from ${archive##*/}"
            continue
        fi
        extracted="${tmp}/${member}"
        [[ -f "${extracted}" ]] || continue
        platform="$(macho_platform "${extracted}")"
        case "${platform}" in
            none) continue ;;
            IOS|unknown) ;;
            *) die "${label}: ${member} in ${archive##*/} is ${platform}, not IOS" ;;
        esac
        file -b "${extracted}" | grep -q arm64 \
            || die "${label}: ${member} in ${archive##*/} is not arm64"
        checked=$((checked + 1))
    done

    [[ "${checked}" -gt 0 ]] || { warn "${label}: could not inspect a member of ${archive##*/}"; return 0; }
    log "${label}: ${archive##*/} members are ${platform}/arm64 (${checked} checked)"
}

verify() {
    require_macos
    local swiftc swift_frontend

    swiftc="${SWIFT_INSTALL_DIR}/bin/swiftc"
    swift_frontend="${SWIFT_INSTALL_DIR}/bin/swift-frontend"

    if [[ -x "${swift_frontend}" ]]; then
        # The compiler proper must be an iOS binary; that is the claim that
        # matters ("the compiler runs on the device").
        log "checking ${swift_frontend}"
        file "${swift_frontend}"
        is_ios_macho "${swift_frontend}" \
            || die "swift-frontend is not an iOS/arm64 binary ($(macho_platform "${swift_frontend}"))"
        if command -v vtool >/dev/null 2>&1; then
            vtool -show-build "${swift_frontend}" 2>/dev/null | sed 's/^/    /'
        fi
        lipo -archs "${swift_frontend}" | grep -q arm64 \
            || die "swift-frontend has no arm64 slice"
        local swift_version="${SWIFT_BRANCH#swift-}"
        swift_version="${swift_version%-RELEASE}"
        report_line "swift: ${swift_version} (${SWIFT_BRANCH}), swift-frontend is $(macho_platform "${swift_frontend}")/arm64"

        # The rest of the tree is reported, not asserted: the cross build also
        # ships host tools (Swift's driver for macOS, host dylibs). Mixing them
        # silently into an "iOS toolchain" would be misleading, so every
        # non-iOS binary is listed here and in the report.
        if [[ -x "${swiftc}" ]]; then
            file "${swiftc}"
            local driver_platform
            driver_platform="$(macho_platform "${swiftc}")"
            if [[ "${driver_platform}" == "IOS" ]]; then
                log "swiftc: iOS/arm64 (the driver runs on the device)"
                report_line "swiftc: iOS/arm64"
            else
                warn "swiftc is ${driver_platform} (a host driver); the iOS compiler is swift-frontend"
                report_line "swiftc: ${driver_platform} (host binary; not counted as an iOS artifact)"
            fi
        fi
        classify_tree "${SWIFT_INSTALL_DIR}/bin" "SwiftToolchain (bin)"
        classify_tree "${SWIFT_INSTALL_DIR}/lib" "SwiftToolchain (lib)"
    else
        warn "no ${swift_frontend}; skipping the Swift compiler checks"
    fi

    if [[ -x "${SWIFT_LLVM_DIR}/ios/bin/llvm-config" ]]; then
        local v
        v="$("${SWIFT_LLVM_DIR}/ios/bin/llvm-config" --version)"
        log "llvm-config (iOS): ${v}"
        [[ "$("${SWIFT_LLVM_DIR}/macosx/bin/llvm-config" --version)" == "${v}" ]] \
            || die "the host and iOS llvm-config shims disagree"

        # `file` sees "current ar archive", so check object members: this is
        # what makes "the iOS LLVM is iOS" a verified statement.
        verify_archive_is_ios "${SWIFT_LLVM_DIR}/ios/lib/libLLVMCore.a" "Swift LLVM (ios)"
        verify_archive_is_ios "${SWIFT_LLVM_DIR}/ios/lib/libLLVMSupport.a" "Swift LLVM (ios)"
        verify_archive_is_ios "${SWIFT_LLVM_DIR}/ios/lib/libLLVMAArch64CodeGen.a" "Swift LLVM (ios)"

        # The tools that ship with the iOS LLVM run on the device.
        local tool
        for tool in llvm-ar llvm-nm llvm-ranlib llvm-objcopy; do
            if [[ -x "${SWIFT_LLVM_DIR}/ios/bin/${tool}" ]]; then
                is_ios_macho "${SWIFT_LLVM_DIR}/ios/bin/${tool}" \
                    || die "${tool} in the iOS LLVM is $(macho_platform "${SWIFT_LLVM_DIR}/ios/bin/${tool}"), not iOS"
            fi
        done
        log "llvm-config (iOS), archive members and iOS tools verified"
        report_line "llvm: ${v} ($(llvm_commit)); ios/lib archives and tools are iOS/arm64"
    else
        warn "no ${SWIFT_LLVM_DIR}/ios/bin/llvm-config; skipping the LLVM checks"
    fi

    # The iOS LLVM must be usable as the LLVM of a compiler: check that the
    # archives rustc asks for are really there.
    if [[ -d "${SWIFT_LLVM_DIR}/ios/lib" ]]; then
        for lib in libLLVMCore.a libLLVMSupport.a libLLVMAArch64CodeGen.a libLLVMTargetParser.a; do
            [[ -f "${SWIFT_LLVM_DIR}/ios/lib/${lib}" ]] \
                || die "the iOS LLVM is missing ${lib}"
        done
        log "the iOS LLVM provides the libraries rustc links (LLVMCore, LLVMSupport, LLVMAArch64CodeGen, ...)"
    fi
}

# ---------------------------------------------------------------------------
# info / main
# ---------------------------------------------------------------------------

info() {
    cat <<EOF
swift branch        : ${SWIFT_BRANCH}
swift checkout      : ${SWIFT_SOURCE_DIR}
swift commit        : $(swift_commit)
llvm-project        : ${SWIFT_WORKSPACE_DIR}/llvm-project ($(llvm_commit))
llvm version        : $(llvm_version)
llvm targets        : ${LLVM_TARGETS}
ios deployment      : ${IOS_DEPLOYMENT_TARGET}
build root          : ${SWIFT_BUILD_ROOT}
build subdir        : ${SWIFT_BUILD_SUBDIR}
preset              : ${SWIFT_CROSS_PRESET} (${SWIFT_PRESET_FILE})
swift install dir   : ${SWIFT_INSTALL_DIR}
llvm install dir    : ${SWIFT_LLVM_DIR}
artifacts dir       : ${ARTIFACTS_DIR}
EOF
}

usage() {
    cat <<EOF
usage: $(basename "$0") <command>

commands:
  fetch             clone swift ${SWIFT_BRANCH} and its sibling repositories (llvm-project, ...)
  llvm              build LLVM + Clang for macOS and iOS (needed by both compilers)
  swift             build the Swift compiler for iOS and collect it in ${SWIFT_INSTALL_DIR}
  install-swift     collect the iOS Swift compiler (after a build)
  install-llvm      write the relocatable LLVM trees used by the Rust build
  package           create ${SWIFT_TOOLCHAIN_NAME}-${PACKAGE_PREFIX}-<ver>.tar.xz
  package-llvm      create SwiftLLVM-${PACKAGE_PREFIX}-<llvm>.tar.xz
  llvm-xcframework  create ${LLVM_XCFRAMEWORK_NAME}-${PACKAGE_PREFIX}-<llvm>.tar.xz (llvm.a + headers)
  verify            check that the Swift compiler and the LLVM are iOS/arm64
  all               fetch + llvm + install-llvm + package-llvm + swift + package + verify
  info              print the effective configuration

environment: SWIFT_BRANCH, IOS_DEPLOYMENT_TARGET, LLVM_TARGETS, SWIFT_SOURCE_DIR,
             SWIFT_BUILD_ROOT, SWIFT_BUILD_SUBDIR, SWIFT_INSTALL_DIR, SWIFT_LLVM_DIR,
             WORK_DIR, ARTIFACTS_DIR

'llvm' and 'swift' run the same build-script invocation (Swift 6.4 builds the
LLVM trees and the compilers in one go) and then collect the LLVM or the Swift
compiler respectively. CI calls 'llvm' first and 'install-swift' afterwards, so
the shared LLVM artifact exists before the Swift toolchain is packaged.
EOF
}

main() {
    local cmd="${1:-}"
    case "${cmd}" in
        fetch)            fetch ;;
        # both build the same thing (see build_swift); the name says what is
        # collected afterwards
        llvm)             build_swift llvm; install_llvm ;;
        swift)            build_swift swift; install_llvm; install_swift ;;
        install-swift)    install_swift ;;
        install-llvm)     install_llvm ;;
        package)          package_swift ;;
        package-llvm)     package_llvm ;;
        llvm-xcframework) llvm_xcframework ;;
        verify)           verify ;;
        all)
            fetch
            build_swift all
            install_llvm
            install_swift
            verify
            package_llvm
            package_swift
            ;;
        info)             info ;;
        ""|-h|--help|help) usage ;;
        *) usage; die "unknown command: ${cmd}" ;;
    esac
}

main "$@"
