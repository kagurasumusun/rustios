# rustios - the LLVM-On-iOS product, for two compilers, made for nyxian.
#
# emexlab/nyxian embeds emexlab/LLVM-On-iOS as a submodule and consumes it
# like this (nyxian's Makefile):
#
#     cd LLVM-On-iOS; $(MAKE)          # leaves CoreCompilerSupportLibs/ and
#                                      # LLVM.xcframework/ at the repo root
#     cp -r LLVM-On-iOS/CoreCompilerSupportLibs Frameworks/CoreCompiler/...
#     cp -r LLVM-On-iOS/LLVM.xcframework       Frameworks/CoreCompiler/...
#     cd LLVM-On-iOS; $(MAKE) install-nyxian-swift-toolchain
#                                      # unpacks SwiftToolchain.zip into
#                                      # nyxian's Shared/ (app resources)
#
# This Makefile builds those exact artifacts *and* the Rust counterparts that
# share their LLVM, and after `make` the repository root carries the
# directories nyxian copies, in LLVM-On-iOS' layout plus the Rust ones:
#
#     make            # everything: shared LLVM, Swift toolchain, Rust
#                     # toolchain, and the nyxian root directories
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
#     make nyxian-dirs  # CoreCompilerSupportLibs/ LLVM.xcframework/
#                       # RustSupportLibs/ Rust.xcframework/ at the repo root
#     make install-nyxian  # Shared/SwiftToolchain + Shared/RustToolchain
#                          # (compiler+std sysroot) in the nyxian checkout
#     make clean / clean-all
#
# Everything is implemented in Scripts/build-{swift,rust}-toolchain.sh; this
# Makefile only forwards the configuration and adds a few convenience targets.
# docs/nyxian.md describes the nyxian integration; docs/parity.md maps every
# artifact and build flag to its counterpart.

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
# compilers are built against an LLVM with identical backends. AArch64 is the
# only backend the shipped code emits; compiler-rt's macho_embedded builtins
# (the sole ARM/X86 consumer) are skipped by the Swift side's probe patch.
LLVM_TARGETS          ?= AArch64
JOBS                  ?= $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
BUILD_XCFRAMEWORK     ?= true

RUST_SOURCE_DIR       ?= $(CURDIR)/rust-source
BUILD_DIR             ?= $(RUST_SOURCE_DIR)/build
WORK_DIR              ?= $(CURDIR)/work
ARTIFACTS_DIR         ?= $(CURDIR)/artifacts

# nyxian's Shared/ folder (its Xcode project ships it inside the app as a
# folder reference). Defaults to the parent checkout's Shared/, i.e. correct
# when rustios sits inside nyxian as a submodule or sibling; override with
# NYXIAN_SHARED_DIR=... (docs/nyxian.md).
NYXIAN_SHARED_DIR     ?= $(CURDIR)/../Shared

IOS_DEPLOYMENT_TARGET := $(OS_VER)

# Exported to the scripts.
SWIFT_LLVM_DIR        ?= $(WORK_DIR)/SwiftLLVM

export RUST_VERSION RUST_CHANNEL RUST_LLVM_MODE SWIFT_BRANCH SWIFT_LLVM_DIR \
       IOS_DEPLOYMENT_TARGET HOST_TRIPLE STAGE \
       LLVM_TARGETS JOBS RUST_SOURCE_DIR BUILD_DIR WORK_DIR ARTIFACTS_DIR \
       NYXIAN_SHARED_DIR

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

.PHONY: all swift rust llvm fetch configure build verify package std support xcframework \
        nyxian-dirs nyxian-swift-dirs nyxian-rust-dirs \
        install-nyxian install-nyxian-swift-toolchain install-nyxian-rust-toolchain \
        verify-swift-toolchain info clean clean-all

# The full product: the LLVM-On-iOS Swift artifacts and their Rust
# counterparts, from one shared LLVM, plus the root directories nyxian
# copies into its app (nyxian-dirs, below).
all: swift rust
	@if [ "$(BUILD_XCFRAMEWORK)" = "true" ]; then $(SCRIPT) xcframework; fi
	@$(MAKE) --no-print-directory nyxian-dirs
	@echo
	@echo "rustios: artifacts in $(ARTIFACTS_DIR), nyxian directories at the repository root"
	@ls -lh $(ARTIFACTS_DIR) 2>/dev/null || true

# ---------------------------------------------------------------------------
# nyxian (docs/nyxian.md)
#
# nyxian's Makefile does `cd <this repo>; $(MAKE)` and then `cp -r`s
# CoreCompilerSupportLibs/ and LLVM.xcframework/ out of the repository root -
# exactly how LLVM-On-iOS leaves them there. The Rust directories are placed
# the same way, for Rust support in nyxian. These targets copy the staged
# trees from $(WORK_DIR) to the root; `swift`/`rust` must have run.
# ---------------------------------------------------------------------------

nyxian-dirs: nyxian-swift-dirs nyxian-rust-dirs

nyxian-swift-dirs:
	@test -d $(WORK_DIR)/CoreCompilerSupportLibs || { echo "missing $(WORK_DIR)/CoreCompilerSupportLibs; run 'make swift' first"; exit 1; }
	@test -d $(WORK_DIR)/LLVM.xcframework.build/LLVM.xcframework || { echo "missing $(WORK_DIR)/LLVM.xcframework.build/LLVM.xcframework; run 'make swift' first"; exit 1; }
	rm -rf CoreCompilerSupportLibs LLVM.xcframework
	cp -a $(WORK_DIR)/CoreCompilerSupportLibs CoreCompilerSupportLibs
	cp -a $(WORK_DIR)/LLVM.xcframework.build/LLVM.xcframework LLVM.xcframework
	@echo "nyxian: CoreCompilerSupportLibs/ and LLVM.xcframework/ are at the repository root"

nyxian-rust-dirs:
	@test -d $(WORK_DIR)/RustSupportLibs || { echo "missing $(WORK_DIR)/RustSupportLibs; run 'make rust' first"; exit 1; }
	rm -rf RustSupportLibs Rust.xcframework
	cp -a $(WORK_DIR)/RustSupportLibs RustSupportLibs
	@if [ "$(BUILD_XCFRAMEWORK)" = "true" ]; then \
		test -d $(WORK_DIR)/Rust.xcframework.build/Rust.xcframework || { echo "missing $(WORK_DIR)/Rust.xcframework.build/Rust.xcframework; run 'make xcframework' first"; exit 1; }; \
		cp -a $(WORK_DIR)/Rust.xcframework.build/Rust.xcframework Rust.xcframework; \
		echo "nyxian: RustSupportLibs/ and Rust.xcframework/ are at the repository root"; \
	else \
		echo "nyxian: RustSupportLibs/ is at the repository root (BUILD_XCFRAMEWORK=$(BUILD_XCFRAMEWORK): Rust.xcframework skipped)"; \
	fi

# install-nyxian: the toolchains as nyxian Shared/ resources (its Xcode
# project ships the whole Shared/ folder inside the app). Same target name as
# LLVM-On-iOS' Makefile for the Swift side, so nyxian's recipes keep working
# when its submodule points at rustios; the Rust one installs the merged
# compiler+std sysroot next to it.
install-nyxian: install-nyxian-swift-toolchain install-nyxian-rust-toolchain

install-nyxian-swift-toolchain:
	$(SWIFT_SCRIPT) install-nyxian

install-nyxian-rust-toolchain:
	$(SCRIPT) install-nyxian

verify-swift-toolchain:
	$(SWIFT_SCRIPT) verify-host

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
	rm -rf CoreCompilerSupportLibs LLVM.xcframework RustSupportLibs Rust.xcframework
	$(SCRIPT) clean

clean-all:
	rm -rf CoreCompilerSupportLibs LLVM.xcframework RustSupportLibs Rust.xcframework
	$(SCRIPT) clean-all
