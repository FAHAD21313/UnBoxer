#!/bin/bash
set -e

# build_rust_bridge.sh
# Build RustBridge.xcframework from Rust source, strip to ios-arm64 only,
# thin OpenSSL.xcframework to ios-arm64 only, and deploy to Dependencies/

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
RUST_DIR="$DIR/RustBridge"
DEPS_DIR="$DIR/../Unboxer/Dependencies"

echo "➡️ Building RustBridge.xcframework from source..."
cd "$RUST_DIR"

echo "   -> Adding iOS Rust target..."
rustup target add aarch64-apple-ios

echo "   -> Running make xcframework (builds ios-arm64 + strip)..."
make xcframework

echo "➡️ Deploying RustBridge.xcframework..."
rm -rf "$DEPS_DIR/RustBridge.xcframework"
cp -R "$RUST_DIR/lib/RustBridge.xcframework" "$DEPS_DIR/RustBridge.xcframework"
echo "   ✅ RustBridge: 124 MB → $(du -sh "$DEPS_DIR/RustBridge.xcframework" | cut -f1)"

echo "➡️ Thinning OpenSSL.xcframework to ios-arm64 only..."
OPENSSL_DIR="$DEPS_DIR/OpenSSL.xcframework"

# Remove all non-iOS slices
rm -rf "$OPENSSL_DIR/ios-arm64_x86_64-simulator"
rm -rf "$OPENSSL_DIR/ios-arm64_x86_64-maccatalyst"
rm -rf "$OPENSSL_DIR/tvos-arm64"
rm -rf "$OPENSSL_DIR/tvos-arm64_x86_64-simulator"
rm -rf "$OPENSSL_DIR/watchos-arm64_arm64_32_armv7k"
rm -rf "$OPENSSL_DIR/watchos-arm64_x86_64-simulator"
rm -rf "$OPENSSL_DIR/macos-arm64_x86_64"
rm -rf "$OPENSSL_DIR/xros-arm64"
rm -rf "$OPENSSL_DIR/xros-arm64_x86_64-simulator"

# Rewrite Info.plist with only ios-arm64 entry
cat > "$OPENSSL_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>OpenSSL.framework/OpenSSL</string>
			<key>LibraryIdentifier</key>
			<string>ios-arm64</string>
			<key>LibraryPath</key>
			<string>OpenSSL.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
PLIST

echo "   ✅ OpenSSL: 95 MB → $(du -sh "$OPENSSL_DIR" | cut -f1)"

echo "✅ Done! Both XCFrameworks deployed and thinned."
