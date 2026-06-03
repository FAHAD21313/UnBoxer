TARGET=rust_bridge
RUST_DIR="."

.PHONY: all build rust xcframework clean

# --- Core Build ---

all: build

build: rust

rust:
	@echo "--- Building Rust Bridge (ios-arm64 only) ---"
	cd $(RUST_DIR) && cargo build --target aarch64-apple-ios --release
	cd $(RUST_DIR) && strip -S target/aarch64-apple-ios/release/lib$(TARGET).a
	@echo "--- Stripped debug symbols from librust_bridge.a ---"

# --- XCFramework (single slice, device only) ---

xcframework: rust
	@echo "--- Building RustBridge.xcframework ---"
	rm -rf $(RUST_DIR)/lib/RustBridge.xcframework
	xcodebuild -create-xcframework \
		-library $(RUST_DIR)/target/aarch64-apple-ios/release/lib$(TARGET).a \
		-output $(RUST_DIR)/lib/RustBridge.xcframework
	@echo "--- Done: RustBridge/lib/RustBridge.xcframework (ios-arm64 only) ---"

# --- Cleanup ---

clean:
	@echo "--- Cleaning ---"
	cd $(RUST_DIR) && cargo clean
	rm -rf $(RUST_DIR)/lib
