#!/bin/bash
set -e

# build_rust_bridge.sh
# Build RustBridge.xcframework from Rust source and copy to Dependencies/

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
RUST_DIR="$DIR/RustBridge"

echo "➡️ Building RustBridge.xcframework from source..."
cd "$RUST_DIR"

echo "   -> Adding iOS Rust targets..."
rustup target add aarch64-apple-ios
rustup target add aarch64-apple-ios-sim

echo "   -> Running make xcframework..."
make xcframework

echo "➡️ Deploying to Unboxer/Dependencies/RustBridge.xcframework..."
rm -rf "$DIR/../Dependencies/RustBridge.xcframework"
cp -R "$RUST_DIR/lib/RustBridge.xcframework" "$DIR/../Dependencies/RustBridge.xcframework"

echo "✅ Done! RustBridge.xcframework rebuilt and deployed."
