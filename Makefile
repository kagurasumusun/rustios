# rustios - build a Rust toolchain that runs on iOS.
#
# Mirrors the layout of https://github.com/emexlab/LLVM-On-iOS:
#   make all  ->  RustToolchain + support libraries + Rust.xcframework
#
# Everything is implemented in Scripts/build-rust-toolchain.sh; this Makefile
# only wires the steps together.

SHELL := /bin/bash
ROOT  := $(CURDIR)

OS_VER        ?= 16.0
RUST_VERSION  ?= 1.99.1
# Empty = let Scripts/build-rust-toolchain.sh derive it from RUST_VERSION
# (stable for release tags, nightly for nightly-* tags).
RUST_CHANNEL  ?=
APPLE_ARCH    := arm64
TARGET_TRIPLE := $(APPLE_ARCH)-apple-ios$(OS_VER)
HOST_TRIPLE   ?= aarch64-apple-ios
STAGE         ?= 2
LLVM_TARGETS  ?= AArch64
JOBS          ?= $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
BUILD_XCFRAMEWORK ?= true

SCRIPT        := $(ROOT)/Scripts/build-rust-toolchain.sh
ARTIFACTS_DIR ?= $(ROOT)/artifacts

IOS_DEPLOYMENT_TARGET := $(OS_VER)

export RUST_VERSION RUST_CHANNEL IOS_DEPLOYMENT_TARGET HOST_TRIPLE STAGE \
       LLVM_TARGETS JOBS BUILD_XCFRAMEWORK ARTIFACTS_DIR

TOOLCHAIN_ARCHIVE := $(ARTIFACTS_DIR)/RustToolchain-iphoneos-arm64-$(RUST_VERSION).tar.xz
SUPPORT_ARCHIVE   := $(ARTIFACTS_DIR)/RustSupportLibs-iphoneos-arm64-$(RUST_VERSION).tar.xz
XCFRAMEWORK       := $(ARTIFACTS_DIR)/Rust.xcframework-iphoneos-arm64-$(RUST_VERSION).tar.xz

.PHONY: all fetch configure build verify package toolchain support xcframework info clean clean-all

.NOTPARALLEL:

# One recipe, so the steps always run in this order (the individual targets
# below stay available for partial rebuilds).
all:
	$(SCRIPT) all
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

toolchain: package

support: build
	$(SCRIPT) support

xcframework: build
	$(SCRIPT) xcframework

info:
	$(SCRIPT) info

clean:
	$(SCRIPT) clean

clean-all:
	$(SCRIPT) clean-all
