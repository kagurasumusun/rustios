# rustios - a Rust toolchain for iOS.
#
# The same interface as emexlab/LLVM-On-iOS:
#
#     make            # everything (shared LLVM, fetch, configure, build, verify, package)
#     make llvm       # build Swift's LLVM for macOS + iOS (rustc links this one)
#     make swift      # build the iOS Swift compiler from the same LLVM
#     make fetch      # clone the Rust sources + required submodules
#     make configure  # write rust-source/bootstrap.toml
#     make build      # x.py build --stage 2 (host = target = aarch64-apple-ios)
#     make verify     # check the produced rustc/std are iOS arm64 artifacts
#     make package    # RustToolchain-iphoneos-arm64-<ver>.tar.xz
#     make std        # RustStd-iphoneos-arm64-<ver>.tar.xz (std, apart from the compiler)
#     make xcframework  # Rust.xcframework-iphoneos-arm64-<ver>.tar.xz
#     make clean / clean-all
#
# Everything is implemented in Scripts/build-rust-toolchain.sh; this Makefile
# only forwards the configuration and adds a few convenience targets.

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
LLVM_TARGETS          ?= AArch64
JOBS                  ?= $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
BUILD_XCFRAMEWORK     ?= true

RUST_SOURCE_DIR       ?= $(CURDIR)/rust-source
BUILD_DIR             ?= $(RUST_SOURCE_DIR)/build
WORK_DIR              ?= $(CURDIR)/work
ARTIFACTS_DIR         ?= $(CURDIR)/artifacts

IOS_DEPLOYMENT_TARGET := $(OS_VER)
PACKAGE_PREFIX        := iphoneos-$(APPLE_ARCH)

# Exported to the script.
SWIFT_LLVM_DIR        ?= $(WORK_DIR)/SwiftLLVM

export RUST_VERSION RUST_CHANNEL RUST_LLVM_MODE SWIFT_BRANCH SWIFT_LLVM_DIR \
       IOS_DEPLOYMENT_TARGET HOST_TRIPLE STAGE \
       LLVM_TARGETS JOBS RUST_SOURCE_DIR BUILD_DIR WORK_DIR ARTIFACTS_DIR

SCRIPT := $(CURDIR)/Scripts/build-rust-toolchain.sh
SWIFT_SCRIPT := $(CURDIR)/Scripts/build-swift-toolchain.sh

TOOLCHAIN_TARBALL := $(ARTIFACTS_DIR)/RustToolchain-$(PACKAGE_PREFIX)-$(RUST_VERSION).tar.xz
STD_TARBALL       := $(ARTIFACTS_DIR)/RustStd-$(PACKAGE_PREFIX)-$(RUST_VERSION).tar.xz
XCFRAMEWORK_TARBALL := $(ARTIFACTS_DIR)/Rust.xcframework-$(PACKAGE_PREFIX)-$(RUST_VERSION).tar.xz

# Serial execution: every step feeds into the next one.
.NOTPARALLEL:

.PHONY: all llvm swift fetch configure build verify package std xcframework info clean clean-all

all: llvm fetch configure build verify package std
	@if [ "$(BUILD_XCFRAMEWORK)" = "true" ]; then $(SCRIPT) xcframework; fi
	@echo
	@echo "rustios: artifacts in $(ARTIFACTS_DIR)"
	@ls -lh $(ARTIFACTS_DIR) 2>/dev/null || true

# Swift's LLVM (macOS + iOS), written to $(SWIFT_LLVM_DIR). The Rust build
# consumes it through [target.*] llvm-config; nothing builds LLVM again.
llvm:
	@if [ "$(RUST_LLVM_MODE)" = "swift" ]; then \
		$(SWIFT_SCRIPT) fetch && $(SWIFT_SCRIPT) llvm; \
	else \
		echo "RUST_LLVM_MODE=$(RUST_LLVM_MODE): bootstrap builds LLVM itself"; \
	fi

# The full iOS Swift toolchain (a compiler, not just the LLVM). `llvm` has
# already run the build; this only collects the compiler.
swift: llvm
	$(SWIFT_SCRIPT) install-swift && $(SWIFT_SCRIPT) verify && $(SWIFT_SCRIPT) package

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

# The xcframework only needs the built toolchain (stage1 rustc + stage2 sysroot),
# not the packaged std archive.
xcframework: verify
	$(SCRIPT) xcframework

info:
	$(SCRIPT) info

clean:
	$(SCRIPT) clean

clean-all:
	$(SCRIPT) clean-all
