# Unboxer — AGENTS.md

## Project type
iOS-only SwiftUI app (deployment target 16.0), built via **XcodeGen** from `project.yml`.
`.xcodeproj` is gitignored — always run `xcodegen generate` before `xcodebuild`.

Uses **Nyxian** project format (`NX*` keys in Info.plist, `NXDeploymentTarget = 26.5` = Nyxian SDK version).
No code signing (`CODE_SIGNING_ALLOWED=NO`, empty identity/team).

## Dependencies (all vendored, no SPM/CocoaPods)
- 4 C static libs: `libplist`, `libusbmuxd`, `libimobiledevice-glue`, `libimobiledevice` (under `Unboxer/Dependencies/`)
- `OpenSSL.xcframework`, `RustBridge.xcframework`

## Rust FFI bridge
- Rust crate at `Unboxer/Scripts/RustBridge/` — produces `librust_bridge.a` (staticlib), wrapped into `RustBridge.xcframework`
- `Unboxer/Scripts/build_rust_bridge.sh` runs `make xcframework` (which builds for `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `aarch64-apple-darwin`) then copies to `Unboxer/Dependencies/`
- Swift FFI bindings: `MinimuxerBridge.swift` (low-level), `MinimuxerBridgeIdevice.swift` (high-level yeet/install/remove/apps/debug/profile/DDI)
- Prerequisites for Rust build: `rustup target add aarch64-apple-ios aarch64-apple-ios-sim`

## Entrypoint & architecture
- `UnBoxerApp.swift` → `ContentView` (2 tabs: Dashboard, Settings)
- `PairingManager` (`@StateObject` env object) — manages `pairing_file.plist` import/parse/delete
- `DashboardViewModel` orchestrates: `LockdownEngine.executeNativeEngine()` → `AppDiscoveryEngine.fetchAllApps(udid:)`
- Both engines call Rust via `RustIdevice` static methods

## Build commands
```bash
# Generate Xcode project (after any project.yml change)
xcodegen generate

# Full build (unsigned)
xcodebuild clean build \
  -project Unboxer.xcodeproj \
  -scheme Unboxer \
  -configuration Release \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" EXPANDED_CODE_SIGN_IDENTITY=""

# Rebuild RustBridge.xcframework from Rust source
./Unboxer/Scripts/build_rust_bridge.sh
```

## CI workflows (`.github/workflows/`)
| Workflow | Trigger | Description |
|---|---|---|
| `build.yml` | `workflow_dispatch` (manual, requires version input) | xcodegen → xcodebuild → IPA → GitHub Release |
| `build_unboxer_core.yml` | `workflow_dispatch` (manual only) | Rust build → `RustBridge.xcframework` from source → commit+push |

## Key gotchas
- **macOS + Xcode required** for any build
- Rust rebuild *must* use `libtool -static` to merge — cannot just replace the `.a`
- Pairing file (`.plist`) must be imported via Dashboard before any engine operation works
- Info.plist is Nyxian-format (`NX*` keys); standard Xcode plist keys are inside `NXBundleInfo` dict
- Entitlements are Nyxian-specific (`com.nyxian.pe.*`) — only `get_task_allowed` is true
- No tests, no lint/format/typecheck scripts exist
