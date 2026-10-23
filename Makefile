# rustios - the LLVM-On-iOS product, for two compilers.
#
# The same interface as emexlab/LLVM-On-iOS (their `make all` builds the Swift
# toolchain + LLVM.xcframework + CoreCompilerSupportLibs); this Makefile builds
# those exact artifacts *and* the Rust counterparts that share their LLVM:
#
#     make            # everything: shared LLVM, Swift toolchain, Rust toolchain
#     make llvm       # build Swift's LLVM for macOS + iOS (rustc links this one)
#     make swift      # the LLVM-On-iOS Swift artifacts:
#                     #   SwiftToolchain.zip, LLVM.xcframework.tar.xz,
#                     #   CoreCompilerSupportLibs.tar.xz
#     make fetch      # clone the Rust sources + required submodules
#     make configure  # write rust-source/bootstrap.toml
#     make build      # x.py build --stage 2 (host = target = aarch64-apple-ios)
#     make verify     # check the produced rustc/std are iOS arm64 artifacts
#     make package    # RustToolchain.zip        (SwiftToolchain.zip counterpart)
#     make std        # RustStd.tar.xz           (std, apart from the compiler)
#     make support    # RustSupportLibs.tar.xz   (CoreCompilerSupportLibs counterpart)
#     make xcframework  # Rust.xcframework.tar.xz (rust.a <- llvm.a)
#     make clean / clean-all
#
# Everything is implemented in Scripts/build-{swift,rust}-toolchain.sh; this
# Makefile only forwards the configuration and adds a few convenience targets.
# docs/parity.md maps every artifact and build flag to its counterpart.

SHELL := /bin/bash
.DEFAULT_GOAL := all

# ---------------------------------------------------------------------------
# Configuration (override on the command line: make OS_VER=17.0)
# ---------------------------------------------------------------------------

OS_VER                ?= 16.0
APPLE_ARCH            := arm64
TARGET_TRIPLE         := $(APPLE_ARCH)-apple-ios$(OS_VER)
HOST_TRIPLE           ?= aarch64-apple-ios
# The Rust compiler links the LLVM that Swift is built from instead of
# building src/llvm-project. See docs/llvm-sharing.md for why this pairing
# (Rust 1.94.0 expects LLVM 21.1.x, Swift 6.4 ships LLVM 21.1.6).
RUST_VERSION          ?= 1.94.0
RUST_CHANNEL          ?= stable
RUST_LLVM_MODE        ?= swift
SWIFT_BRANCH          ?= swift-6.4.0-RELEASE
STAGE                 ?= 2
# Same target set as `llvm-targets-to-build` in the Swift preset: both
# compilers are built against an LLVM with identical backends (AArch64 for
# the shipped code, ARM/X86 for compiler-rt's embedded builtins).
LLVM_TARGETS          ?= AArch64;ARM;X86
JOBS                  ?= $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
BUILD_XCFRAMEWORK     ?= true

RUST_SOURCE_DIR       ?= $(CURDIR)/rust-source
BUILD_DIR             ?= $(RUST_SOURCE_DIR)/build
WORK_DIR              ?= $(CURDIR)/work
ARTIFACTS_DIR         ?= $(CURDIR)/artifacts

IOS_DEPLOYMENT_TARGET := $(OS_VER)

# Exported to the scripts.
SWIFT_LLVM_DIR        ?= $(WORK_DIR)/SwiftLLVM

export RUST_VERSION RUST_CHANNEL RUST_LLVM_MODE SWIFT_BRANCH SWIFT_LLVM_DIR \
       IOS_DEPLOYMENT_TARGET HOST_TRIPLE STAGE \
       LLVM_TARGETS JOBS RUST_SOURCE_DIR BUILD_DIR WORK_DIR ARTIFACTS_DIR

SCRIPT := $(CURDIR)/Scripts/build-rust-toolchain.sh
SWIFT_SCRIPT := $(CURDIR)/Scripts/build-swift-toolchain.sh

# Artifact names - the Swift ones are exactly LLVM-On-iOS', the Rust ones
# mirror them (docs/parity.md). These variables are informational; the
# scripts compute the same paths themselves.
SWIFT_TOOLCHAIN_ZIP     := $(ARTIFACTS_DIR)/SwiftToolchain.zip
LLVM_XCFRAMEWORK_TARBALL := $(ARTIFACTS_DIR)/LLVM.xcframework.tar.xz
CORE_SUPPORT_TARBALL    := $(ARTIFACTS_DIR)/CoreCompilerSupportLibs.tar.xz
SWIFT_LLVM_TARBALL      := $(ARTIFACTS_DIR)/SwiftLLVM.tar.xz
TOOLCHAIN_ZIP           := $(ARTIFACTS_DIR)/RustToolchain.zip
STD_TARBALL             := $(ARTIFACTS_DIR)/RustStd.tar.xz
SUPPORT_TARBALL         := $(ARTIFACTS_DIR)/RustSupportLibs.tar.xz
XCFRAMEWORK_TARBALL     := $(ARTIFACTS_DIR)/Rust.xcframework.tar.xz

# Serial execution: every step feeds into the next one.
.NOTPARALLEL:

.PHONY: all swift rust llvm fetch configure build verify package std support xcframework info clean clean-all

# The full product: the LLVM-On-iOS Swift artifacts and their Rust
# counterparts, from one shared LLVM.
all: swift rust
	@if [ "$(BUILD_XCFRAMEWORK)" = "true" ]; then $(SCRIPT) xcframework; fi
	@echo
	@echo "rustios: artifacts in $(ARTIFACTS_DIR)"
	@ls -lh $(ARTIFACTS_DIR) 2>/dev/null || true

# Swift's LLVM (macOS + iOS), written to $(SWIFT_LLVM_DIR). The Rust build
# consumes it through [target.*] llvm-config; nothing builds LLVM again.
llvm:
	@if [ "$(RUST_LLVM_MODE)" = "swift" ]; then \
		$(SWIFT_SCRIPT) fetch && $(SWIFT_SCRIPT) llvm && $(SWIFT_SCRIPT) package-llvm; \
	else \
		echo "RUST_LLVM_MODE=$(RUST_LLVM_MODE): bootstrap builds LLVM itself"; \
	fi

# The LLVM-On-iOS Swift artifacts: SwiftToolchain.zip, LLVM.xcframework,
# CoreCompilerSupportLibs (plus SwiftLLVM.tar.xz for the Rust job). `llvm`
# has already run the build; this only collects and packages.
swift: llvm
	$(SWIFT_SCRIPT) install-swift && $(SWIFT_SCRIPT) verify && \
	$(SWIFT_SCRIPT) package && $(SWIFT_SCRIPT) llvm-xcframework && \
	$(SWIFT_SCRIPT) support

# The Rust chain (needs the shared LLVM: configure points bootstrap at it).
rust: support

fetch:
	$(SCRIPT) fetch

configure: fetch
	$(SCRIPT) configure

build: configure
	$(SCRIPT) build

verify: build
	$(SCRIPT) verify

package: verify
	$(SCRIPT) package

std: package
	$(SCRIPT) std

support: std
	$(SCRIPT) support

# The xcframework only needs the built toolchain (stage1 rustc + stage2 sysroot),
# not the packaged archives.
xcframework: verify
	$(SCRIPT) xcframework

info:
	$(SWIFT_SCRIPT) info
	@echo
	$(SCRIPT) info

clean:
	$(SCRIPT) clean

clean-all:
	$(SCRIPT) clean-all
