# rustios - a Rust toolchain for iOS.
#
# The same interface as emexlab/LLVM-On-iOS:
#
#     make            # everything (fetch, configure, build, verify, package)
#     make fetch      # clone the Rust sources + required submodules
#     make configure  # write rust-source/bootstrap.toml
#     make build      # x.py build --stage 2 (host = target = aarch64-apple-ios)
#     make verify     # check the produced rustc/std are iOS arm64 artifacts
#     make package    # RustToolchain-iphoneos-arm64-<ver>.tar.xz
#     make support    # RustSupportLibs-iphoneos-arm64-<ver>.tar.xz
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
RUST_VERSION          ?= 1.99.1
RUST_CHANNEL          ?= stable
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
export RUST_VERSION RUST_CHANNEL IOS_DEPLOYMENT_TARGET HOST_TRIPLE STAGE \
       LLVM_TARGETS JOBS RUST_SOURCE_DIR BUILD_DIR WORK_DIR ARTIFACTS_DIR

SCRIPT := $(CURDIR)/Scripts/build-rust-toolchain.sh

TOOLCHAIN_TARBALL := $(ARTIFACTS_DIR)/RustToolchain-$(PACKAGE_PREFIX)-$(RUST_VERSION).tar.xz
USR_TARBALL       := $(ARTIFACTS_DIR)/RustToolchain-$(PACKAGE_PREFIX)-$(RUST_VERSION)-usr.tar.xz
SUPPORT_TARBALL   := $(ARTIFACTS_DIR)/RustSupportLibs-$(PACKAGE_PREFIX)-$(RUST_VERSION).tar.xz
XCFRAMEWORK_TARBALL := $(ARTIFACTS_DIR)/Rust.xcframework-$(PACKAGE_PREFIX)-$(RUST_VERSION).tar.xz

# Serial execution: every step feeds into the next one.
.NOTPARALLEL:

.PHONY: all fetch configure build verify package support xcframework info clean clean-all

all: fetch configure build verify package support
	@if [ "$(BUILD_XCFRAMEWORK)" = "true" ]; then $(SCRIPT) xcframework; fi
	@echo
	@echo "rustios: artifacts in $(ARTIFACTS_DIR)"
	@ls -lh $(ARTIFACTS_DIR) 2>/dev/null || true

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

support: package
	$(SCRIPT) support

xcframework: support
	$(SCRIPT) xcframework

info:
	$(SCRIPT) info

clean:
	$(SCRIPT) clean

clean-all:
	$(SCRIPT) clean-all
