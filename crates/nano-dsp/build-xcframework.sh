#!/usr/bin/env bash
# Build nano-dsp's C-ABI staticlib for iOS device + simulator and assemble NanoDSP.xcframework
# (using the committed include/ header + modulemap). Run from anywhere:
#   ./crates/nano-dsp/build-xcframework.sh
set -euo pipefail
cd "$(dirname "$0")/../.."   # workspace root

CRATE_DIR="crates/nano-dsp"
OUT="${CRATE_DIR}/NanoDSP.xcframework"
HEADERS="${CRATE_DIR}/include"   # committed: nano_dsp.h + module.modulemap

echo "==> [1/3] Ensure the iOS targets are installed"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim

echo "==> [2/3] Build the staticlib for device + simulator (arm64), ffi feature on"
cargo build -p nano-dsp --features ffi --release --target aarch64-apple-ios
cargo build -p nano-dsp --features ffi --release --target aarch64-apple-ios-sim

echo "==> [3/3] Assemble the xcframework"
rm -rf "${OUT}"
xcodebuild -create-xcframework \
  -library "target/aarch64-apple-ios/release/libnano_dsp.a"     -headers "${HEADERS}" \
  -library "target/aarch64-apple-ios-sim/release/libnano_dsp.a" -headers "${HEADERS}" \
  -output "${OUT}"

echo "Done: ${OUT}"
