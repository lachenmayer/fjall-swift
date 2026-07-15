#!/usr/bin/env bash
# Builds FjallFFI.xcframework containing the Rust static library for Apple
# platforms. Requires macOS with Xcode and a Rust toolchain.
#
# Usage:
#   scripts/build-xcframework.sh            # macOS + iOS (all architectures)
#   scripts/build-xcframework.sh --native   # host architecture only (fast, for CI/local tests)
#
# Output:
#   rust/target/xcframework/FjallFFI.xcframework
#   rust/target/xcframework/FjallFFI.xcframework.zip
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: this script must run on macOS" >&2
  exit 1
fi

NATIVE_ONLY=false
if [[ "${1:-}" == "--native" ]]; then
  NATIVE_ONLY=true
fi

MANIFEST=rust/Cargo.toml
TARGET_DIR=rust/target
STAGING="$TARGET_DIR/xcframework-staging"
OUT_DIR="$TARGET_DIR/xcframework"
rm -rf "$STAGING" "$OUT_DIR"
mkdir -p "$STAGING" "$OUT_DIR"

build() {
  local target=$1
  rustup target add "$target" >/dev/null
  cargo build --manifest-path "$MANIFEST" --release --target "$target"
}

# Each XCFramework library slice needs its own headers directory.
make_headers() {
  local dir=$1
  mkdir -p "$dir"
  cp Sources/CFjallFFI/CFjallFFI.h "$dir/"
  cat > "$dir/module.modulemap" <<'EOF'
module CFjallFFI {
    header "CFjallFFI.h"
    export *
}
EOF
}

LIBRARIES=()

if $NATIVE_ONLY; then
  case "$(uname -m)" in
    arm64) HOST_TARGET="aarch64-apple-darwin" ;;
    *) HOST_TARGET="x86_64-apple-darwin" ;;
  esac
  build "$HOST_TARGET"
  mkdir -p "$STAGING/macos"
  cp "$TARGET_DIR/$HOST_TARGET/release/libfjall_ffi.a" "$STAGING/macos/"
  LIBRARIES+=("$STAGING/macos/libfjall_ffi.a")
else
  # macOS (universal)
  build aarch64-apple-darwin
  build x86_64-apple-darwin
  mkdir -p "$STAGING/macos"
  lipo -create \
    "$TARGET_DIR/aarch64-apple-darwin/release/libfjall_ffi.a" \
    "$TARGET_DIR/x86_64-apple-darwin/release/libfjall_ffi.a" \
    -output "$STAGING/macos/libfjall_ffi.a"
  LIBRARIES+=("$STAGING/macos/libfjall_ffi.a")

  # iOS (device)
  build aarch64-apple-ios
  mkdir -p "$STAGING/ios"
  cp "$TARGET_DIR/aarch64-apple-ios/release/libfjall_ffi.a" "$STAGING/ios/"
  LIBRARIES+=("$STAGING/ios/libfjall_ffi.a")

  # iOS simulator (universal)
  build aarch64-apple-ios-sim
  build x86_64-apple-ios
  mkdir -p "$STAGING/ios-sim"
  lipo -create \
    "$TARGET_DIR/aarch64-apple-ios-sim/release/libfjall_ffi.a" \
    "$TARGET_DIR/x86_64-apple-ios/release/libfjall_ffi.a" \
    -output "$STAGING/ios-sim/libfjall_ffi.a"
  LIBRARIES+=("$STAGING/ios-sim/libfjall_ffi.a")
fi

# Each -library needs its own -headers directory.
ARGS=()
i=0
for lib in "${LIBRARIES[@]}"; do
  headers_dir="$STAGING/headers-$i"
  make_headers "$headers_dir"
  ARGS+=(-library "$lib" -headers "$headers_dir")
  i=$((i + 1))
done

xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT_DIR/FjallFFI.xcframework"

(cd "$OUT_DIR" && ditto -c -k --sequesterRsrc --keepParent FjallFFI.xcframework FjallFFI.xcframework.zip)

echo "Built $OUT_DIR/FjallFFI.xcframework"
echo "Checksum: $(swift package compute-checksum "$OUT_DIR/FjallFFI.xcframework.zip")"
