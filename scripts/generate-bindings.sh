#!/usr/bin/env bash
# Regenerates the UniFFI Swift bindings in Sources/FjallFFI and
# Sources/CFjallFFI from the Rust crate. Run after changing rust/src/lib.rs.
set -euo pipefail
cd "$(dirname "$0")/.."

cargo build --manifest-path rust/Cargo.toml

case "$(uname -s)" in
  Darwin) LIB="rust/target/debug/libfjall_ffi.dylib" ;;
  *) LIB="rust/target/debug/libfjall_ffi.so" ;;
esac

OUT=rust/target/uniffi-bindings
cargo run --manifest-path rust/Cargo.toml --bin uniffi-bindgen -- \
  generate --library "$LIB" --language swift --out-dir "$OUT"

mkdir -p Sources/FjallFFI Sources/CFjallFFI
cp "$OUT/FjallFFI.swift" Sources/FjallFFI/FjallFFI.swift
cp "$OUT/CFjallFFI.h" Sources/CFjallFFI/CFjallFFI.h

echo "Bindings updated:"
echo "  Sources/FjallFFI/FjallFFI.swift"
echo "  Sources/CFjallFFI/CFjallFFI.h"
