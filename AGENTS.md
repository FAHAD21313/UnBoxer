# Unboxer — AGENTS.md

## Project type
iOS-only SwiftUI app (deployment target 16.0), built via **XcodeGen** from `project.yml`.
`.xcodeproj` is gitignored — always run `xcodegen generate` before `xcodebuild`.

Uses **Nyxian** project format (`NX*` keys in Info.plist, `NXDeploymentTarget = 26.5` = Nyxian SDK version).
No code signing (`CODE_SIGNING_ALLOWED=NO`, empty identity/team).

## Dependencies (all vendored, no SPM/CocoaPods)
- 4 C static libs: `libplist`, `libusbmuxd`, `libimobiledevice-glue`, `libimobiledevice` (under `Unboxer/Dependencies/`)
- `OpenSSL.xcframework` (thinned to ios-arm64 only), `RustBridge.xcframework` (ios-arm64 only)

## Rust FFI bridge
- Rust crate at `Unboxer/Scripts/RustBridge/` — produces `librust_bridge.a` (staticlib), wrapped into single-slice `RustBridge.xcframework`
- `Unboxer/Scripts/build_rust_bridge.sh` runs `make xcframework` (builds for `aarch64-apple-ios` + `strip -S`), then copies to `Unboxer/Dependencies/` and thins `OpenSSL.xcframework`
- Swift FFI bindings: `MinimuxerBridge.swift` (low-level), `MinimuxerBridgeIdevice.swift` (high-level yeet/install/remove/apps/debug/profile/DDI)
- Prerequisites for Rust build: `rustup target add aarch64-apple-ios`

## Entrypoint & architecture
- `UnBoxerApp.swift` → `ContentView` (3 tabs: Dashboard, Backups, Settings)
- `PairingManager` (`@StateObject` env object) — manages `pairing_file.plist` import/parse/delete
- `DashboardViewModel` orchestrates: `LockdownEngine.executeNativeEngine()` → `AppDiscoveryEngine.fetchAllApps(udid:)`
- `BackupEngine` backs up app containers via house_arrest (`vend_container`, falls back to `vend_documents`) into `Documents/Backups/`
- All engines call Rust via `RustIdevice` static methods

See `CLAUDE.md` for the full architecture reference — keep both files in sync.

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
| `build_unboxer_core.yml` | `workflow_dispatch` (manual only) | Rust build → `RustBridge.xcframework` (ios-arm64) + thin `OpenSSL.xcframework` → commit+push |

## Key gotchas
- **macOS + Xcode required** for any build
- Rust rebuild builds ios-arm64 only — no simulator/macOS slices; `strip -S` removes debug symbols
- Pairing file (`.plist`) must be imported via Dashboard before any engine operation works
- Info.plist is Nyxian-format (`NX*` keys); standard Xcode plist keys are inside `NXBundleInfo` dict
- Entitlements are Nyxian-specific (`com.nyxian.pe.*`) — only `get_task_allowed` is true
- No tests, no lint/format/typecheck scripts exist
