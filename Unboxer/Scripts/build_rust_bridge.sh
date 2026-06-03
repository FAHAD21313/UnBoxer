#!/bin/bash
set -e

echo "🏭 Welcome to the Custom Rust Core Factory!"
echo "➡️ Cloning minimuxer upstream repository..."

# Use jkcoxson/minimuxer or SideStore/minimuxer-ios (whichever the community uses, fallback to jkcoxson)
git clone https://github.com/jkcoxson/minimuxer.git || git clone https://github.com/SideStore/minimuxer-ios.git minimuxer
cd minimuxer

echo "➡️ Injecting CTO Weaponized Custom FFI Bindings..."
# Append the FFI functions at the end of the main library file (typically src/lib.rs or src/ffi.rs)
if [ -f "src/ffi.rs" ]; then
    cat ../minimuxer_ffi.patch >> src/ffi.rs
else
    cat ../minimuxer_ffi.patch >> src/lib.rs
fi

echo "➡️ Building iOS ARM64 target..."
rustup target add aarch64-apple-ios
cargo build --target aarch64-apple-ios --release

echo "➡️ Building iOS Simulator ARM64 target..."
rustup target add aarch64-apple-ios-sim
cargo build --target aarch64-apple-ios-sim --release

echo "➡️ Preparing libraries for XCFramework..."
cp target/aarch64-apple-ios/release/libminimuxer.a target/aarch64-apple-ios/release/librust_bridge.a
cp target/aarch64-apple-ios-sim/release/libminimuxer.a target/aarch64-apple-ios-sim/release/librust_bridge.a

echo "➡️ Assembling RustBridge.xcframework..."
rm -rf RustBridge.xcframework
xcodebuild -create-xcframework \
    -library target/aarch64-apple-ios/release/librust_bridge.a \
    -library target/aarch64-apple-ios-sim/release/librust_bridge.a \
    -output RustBridge.xcframework

echo "✅ Custom RustBridge.xcframework generated successfully!"
