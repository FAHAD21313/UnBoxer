#!/bin/bash
set -e

# build_unboxer_core.sh
# Script to build the UnboxerCore Rust micro-library into an XCFramework

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CORE_DIR="$DIR/UnboxerCore"

echo "➡️ Changing directory to UnboxerCore..."
cd "$CORE_DIR"

echo "➡️ Adding iOS Rust targets..."
rustup target add aarch64-apple-ios
rustup target add aarch64-apple-ios-sim

echo "➡️ Building iOS ARM64 target..."
cargo build --target aarch64-apple-ios --release

echo "➡️ Building iOS Simulator ARM64 target..."
cargo build --target aarch64-apple-ios-sim --release

echo "➡️ Injecting UnboxerCore symbols into the original RustBridge.xcframework..."

# Paths to the original RustBridge frameworks
RUST_BRIDGE_DIR="../../Dependencies/RustBridge.xcframework"

# Merge ARM64 (Device)
echo "   -> Merging for iOS ARM64..."
libtool -static -o $RUST_BRIDGE_DIR/ios-arm64/librust_bridge_merged.a \
    $RUST_BRIDGE_DIR/ios-arm64/librust_bridge.a \
    target/aarch64-apple-ios/release/libunboxer_core.a
mv $RUST_BRIDGE_DIR/ios-arm64/librust_bridge_merged.a $RUST_BRIDGE_DIR/ios-arm64/librust_bridge.a

# Merge ARM64 Simulator
echo "   -> Merging for iOS Simulator ARM64..."
libtool -static -o $RUST_BRIDGE_DIR/ios-arm64-simulator/librust_bridge_merged.a \
    $RUST_BRIDGE_DIR/ios-arm64-simulator/librust_bridge.a \
    target/aarch64-apple-ios-sim/release/libunboxer_core.a
mv $RUST_BRIDGE_DIR/ios-arm64-simulator/librust_bridge_merged.a $RUST_BRIDGE_DIR/ios-arm64-simulator/librust_bridge.a

echo "✅ Sniper Injection Complete! UnboxerCore symbols are now part of RustBridge!"
