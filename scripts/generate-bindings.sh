#!/usr/bin/env bash
# Regenerates the UniFFI Swift bindings in Sources/FjallFFI and
# Sources/CFjallFFI from the Rust crate. Run after changing rust/src/lib.rs.
set -euo pipefail
cd "$(dirname "$0")/.."

cargo build --manifest-path rust/Cargo.toml

case "$(uname -s)" in
  Darwin) LIB="target/debug/libfjall_ffi.dylib" ;;
  *) LIB="target/debug/libfjall_ffi.so" ;;
esac

# uniffi-bindgen resolves the crate via `cargo metadata`, so it must run
# from inside the crate directory.
(
  cd rust
  cargo run --bin uniffi-bindgen -- \
    generate --library "$LIB" --language swift --out-dir target/uniffi-bindings
)

OUT=rust/target/uniffi-bindings
mkdir -p Sources/FjallFFI Sources/CFjallFFI
cp "$OUT/FjallFFI.swift" Sources/FjallFFI/FjallFFI.swift
cp "$OUT/CFjallFFI.h" Sources/CFjallFFI/CFjallFFI.h

echo "Bindings updated:"
echo "  Sources/FjallFFI/FjallFFI.swift"
echo "  Sources/CFjallFFI/CFjallFFI.h"
