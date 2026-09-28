#!/bin/bash
# Full test gate: ost unit tests, ostmac-core tests, Swift tests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cargo test --manifest-path "$ROOT/rust/ost/Cargo.toml" 2>&1 | grep -E "test result|^error"
cargo test --manifest-path "$ROOT/rust/ostmac-core/Cargo.toml" 2>&1 | grep -E "test result|^error"
cargo build --release --manifest-path "$ROOT/rust/ostmac-core/Cargo.toml" >/dev/null 2>&1
cd "$ROOT/swift" && swift test 2>&1 | grep -E "Executed .* tests|error:"
