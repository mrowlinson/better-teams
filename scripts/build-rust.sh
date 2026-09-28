#!/bin/sh
# Build vendored ost + ostmac-core staticlib (release).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Pin the macOS deployment target to Package.swift's `.macOS(.v26)`. Without it,
# rustc/cc default to the host SDK version (macOS 27 on the build Mac), so every
# Swift link warns "object file was built for newer macOS version" and the app
# will not run on older hosts. Keep this in sync with Package.swift platforms.
export MACOSX_DEPLOYMENT_TARGET=26.0
# Do not strip host build artifacts (proc-macro dylibs, build scripts). rustc's
# release default `strip = "debuginfo"` runs the Xcode 27 `strip`, which leaves a
# mis-aligned LINKEDIT string pool that dyld refuses to load, so every proc-macro
# crate fails with E0463 "can't find crate" on a clean build.
export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP=none
cargo build --release --manifest-path "$ROOT/rust/ost/Cargo.toml"
cargo build --release --manifest-path "$ROOT/rust/ostmac-core/Cargo.toml"
ls -lh "$ROOT/rust/ost/target/release/teams-cli" \
       "$ROOT/rust/ostmac-core/target/release/libostmac_core.a"
