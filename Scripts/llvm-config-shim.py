#!/usr/bin/env python3
"""Write a relocatable `llvm-config` for an LLVM installation.

rustc's build system (compiler/rustc_llvm/build.rs) runs `llvm-config` while it
compiles, so the LLVM that a rustc links against must be described by a program
that can execute on the *build machine*. The LLVM we ship for iOS is an iOS
binary and cannot run there, and the LLVM build trees are not shipped with the
toolchain anyway.

This script captures what a real, host-runnable llvm-config of the same LLVM
source tree reports and writes a POSIX shell implementation of the queries
rustc and bootstrap make. Every path is derived from the shim's own location
(`<prefix>/bin/llvm-config`), so the resulting tree can be moved - e.g. packed
into a CI artifact, downloaded into a different job, and unpacked somewhere
else.

Two flavours are generated:

  --mode host : asked by rustc_llvm when a rustc for the build machine is
                built. Reports the host's system libraries.
  --mode ios  : asked by rustc_llvm when the rustc that runs on iOS is built.
                Reports the iOS libraries; system libraries are omitted (the
                iOS linker takes them from the SDK).

Usage:
  llvm-config-shim.py --source <llvm-config> --mode host|ios \
      --host-target <triple> --out <prefix>/bin/llvm-config
"""

import argparse
import os
import shlex
import pathlib
import subprocess
import sys

PREFIX_PLACEHOLDER = "@PREFIX@"

# Flags that describe the machine the *build tree* was configured for and that
# make no sense for the other architecture. cc-rs (used by rustc_llvm) adds the
# right --target/-isysroot/-m<os>-version-min flags for the target itself.
PATH_FLAGS_WITH_VALUE = ("-arch", "-isysroot", "--sysroot", "-target", "-mllvm")


def run(config, *args):
    out = subprocess.run([config, *args], capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit(f"{config} {' '.join(args)} failed: {out.stderr.strip()}")
    return out.stdout.strip()


def tokens(text):
    return shlex.split(text)


def capture(source):
    """Capture the llvm-config outputs that matter, statically linked."""
    info = {
        "version": run(source, "--version"),
        "components": run(source, "--components"),
        "targets": run(source, "--targets-built"),
        "host_target": run(source, "--host-target"),
        "build_mode": run(source, "--build-mode"),
        "assertion_mode": run(source, "--assertion-mode"),
        "has_rtti": run(source, "--has-rtti"),
        "libdir": run(source, "--libdir"),
        "includedir": run(source, "--includedir"),
        "libs": tokens(run(source, "--link-static", "--libs")),
        "ldflags": tokens(run(source, "--link-static", "--ldflags")),
        "system_libs": tokens(run(source, "--link-static", "--system-libs")),
        "cxxflags": tokens(run(source, "--link-static", "--cxxflags")),
    }
    return info


def rewrite_lib(token):
    """Map one `--libs` entry to a library *name* (resolved at run time)."""
    if token.startswith("-L"):
        return None  # the shim always reports <prefix>/lib
    if token.startswith("-l"):
        return token[2:]
    if token.startswith("-"):
        # Flags such as -framework Foo are not used by LLVM's static build on
        # Darwin, but do not silently drop unknown ones.
        return token
    name = pathlib.Path(token).name
    if name.endswith(".a"):
        return name[3:-2]  # libLLVMCore.a -> LLVMCore
    if name.endswith(".lib"):
        return name[:-4]
    return token


def rewrite_cxxflags(flags, mode):
    """Keep the flags that affect compilation, drop the machine-specific ones."""
    result = []
    skip_next = False
    for flag in flags:
        if skip_next:
            skip_next = False
            continue
        if flag.startswith("-I"):
            continue  # replaced with -I<prefix>/include
        if flag in PATH_FLAGS_WITH_VALUE:
            skip_next = flag != "-mllvm"
            continue
        if flag.startswith(("-mmacosx-version-min", "-mios-version-min",
                            "-mtvos-version-min", "-miphoneos-version-min",
                            "-isysroot", "--sysroot=", "-target=")):
            continue
        if mode == "ios" and flag.startswith("-m") and flag not in ("-mllvm",):
            # build.rs drops these for cross builds anyway.
            continue
        if flag.startswith("-arch="):
            continue
        result.append(flag)
    return result


def shell_quote_list(items):
    return " ".join(shlex.quote(item) for item in items)


def generate(info, mode, host_target, source_desc, prefix_hint=""):
    libs = [name for name in map(rewrite_lib, info["libs"]) if name]
    # `-l` flags from --ldflags are redundant when every library is given by
    # name; keep only the libs from --libs.
    cxxflags = rewrite_cxxflags(info["cxxflags"], mode)
    cxxflags = [f"-I{PREFIX_PLACEHOLDER}/include"] + cxxflags
    if mode == "ios":
        syslibs = []
    else:
        syslibs = [t for t in info["system_libs"] if not t.startswith("-L")]

    lines = [
        "#!/bin/sh",
        "# Generated by rustios Scripts/llvm-config-shim.py - do not edit.",
        f"# LLVM source    : {source_desc}",
        f"# LLVM version   : {info['version']}",
        f"# mode           : {mode}",
        f"# host target    : {host_target}",
        "#",
        "# This is a stand-in for the llvm-config of the LLVM build this",
        "# toolchain ships. Paths are resolved relative to this file, so the",
        "# tree can be relocated (artifacts, different CI job, ...).",
        "set -u",
        "",
        'case "$0" in',
        '  */*) bindir=$(cd "$(dirname "$0")" && pwd) ;;',
        "  *)   bindir=. ;;",
        "esac",
        'PREFIX=$(cd "${bindir}/.." && pwd)',
        "",
        "# Record who asked for what: the Rust build's calls of this file are",
        "# the evidence that rustc used the Swift LLVM (see",
        "# build-rust-toolchain.sh verify_llvm_source).",
        "printf '%s %s\\n' \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" \"$*\" >> \"${PREFIX}/llvm-config.log\" 2>/dev/null || :",
        "",
        f"VERSION={shlex.quote(info['version'])}",
        f"HOST_TARGET={shlex.quote(host_target)}",
        f"TARGETS={shlex.quote(info['targets'])}",
        f"BUILD_MODE={shlex.quote(info['build_mode'])}",
        f"ASSERTION_MODE={shlex.quote(info['assertion_mode'])}",
        f"HAS_RTTI={shlex.quote(info['has_rtti'])}",
        f"COMPONENTS={shlex.quote(info['components'])}",
        f"LIBS={shlex.quote(' '.join(libs))}",
        f"SYSTEM_LIBS={shlex.quote(' '.join(syslibs))}",
        f"CXXFLAGS_RAW={shlex.quote(' '.join(cxxflags))}",
        "",
        f'CXXFLAGS=$(printf %s "$CXXFLAGS_RAW" | sed "s|{PREFIX_PLACEHOLDER}|$PREFIX|g")',
        "",
        "want_libs=0",
        "for arg in \"$@\"; do",
        "  case \"$arg\" in",
        "    --version)        echo \"$VERSION\" ;;",
        "    --prefix)         echo \"$PREFIX\" ;;",
        "    --libdir)         echo \"$PREFIX/lib\" ;;",
        "    --includedir)     echo \"$PREFIX/include\" ;;",
        "    --bindir)         echo \"$bindir\" ;;",
        "    --cmakedir)       echo \"$PREFIX/lib/cmake/llvm\" ;;",
        "    --obj-root|--src-root) echo \"$PREFIX\" ;;",
        "    --components)     echo \"$COMPONENTS\" ;;",
        "    --targets-built)  echo \"$TARGETS\" ;;",
        "    --host-target)    echo \"$HOST_TARGET\" ;;",
        "    --build-mode)     echo \"$BUILD_MODE\" ;;",
        "    --assertion-mode) echo \"$ASSERTION_MODE\" ;;",
        "    --has-rtti)       echo \"$HAS_RTTI\" ;;",
        "    --shared-mode)    echo static ;;",
        "    --cxxflags|--cppflags) echo \"$CXXFLAGS\" ;;",
        "    --ldflags)        echo \"-L${PREFIX}/lib\" ;;",
        "    --system-libs)    [ -n \"$SYSTEM_LIBS\" ] && echo \"$SYSTEM_LIBS\" ;;",
        "    --libs|--libnames|--libfiles) want_libs=1 ;;",
        "    --link-static|--link-shared|--ignore-libllvm|--has-rtti=*) : ;;",
        "    *) : ;;  # component names: we always report every library",
        "  esac",
        "done",
        "",
        "if [ \"$want_libs\" = 1 ]; then",
        "  out=",
        "  for name in $LIBS; do",
        "    case \"$name\" in",
        "      -*) out=\"$out $name\" ;;",
        "      *)  if [ -f \"${PREFIX}/lib/lib${name}.a\" ]; then",
        "            out=\"$out ${PREFIX}/lib/lib${name}.a\"",
        "          else",
        "            out=\"$out -l${name}\"",
        "          fi ;;",
        "    esac",
        "  done",
        "  echo \"${out# }\"",
        "fi",
        "",
    ]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True,
                    help="a host-runnable llvm-config of the same LLVM source tree")
    ap.add_argument("--mode", choices=("host", "ios"), required=True)
    ap.add_argument("--host-target", required=True,
                    help="target triple the generated llvm-config describes")
    ap.add_argument("--out", required=True, help="path of the llvm-config to write")
    ap.add_argument("--description", default="",
                    help="human readable provenance for the header comment")
    args = ap.parse_args()

    source = os.path.abspath(args.source)
    info = capture(source)
    text = generate(info, args.mode, args.host_target, args.description or source)

    out = pathlib.Path(os.path.abspath(args.out))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text)
    out.chmod(0o755)

    # Smoke test: the shim has to answer the queries rustc makes.
    checks = {
        "--version": info["version"],
        "--libdir": str(out.parent.parent / "lib"),
        "--includedir": str(out.parent.parent / "include"),
        "--host-target": args.host_target,
    }
    for flag, expected in checks.items():
        got = subprocess.run([str(out), flag], capture_output=True, text=True).stdout.strip()
        if got != expected:
            raise SystemExit(f"shim {out} reports {flag}={got!r}, expected {expected!r}")
    libs = subprocess.run([str(out), "--link-static", "--libs"], capture_output=True, text=True)
    if libs.returncode != 0 or not libs.stdout.strip():
        raise SystemExit(f"shim {out} cannot report libraries: {libs.stderr}")
    print(f"wrote {out} ({args.mode}, LLVM {info['version']}, "
          f"{len(info['libs'])} library entries)")


if __name__ == "__main__":
    sys.exit(main())
