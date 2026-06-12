# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Unboxer is an iOS-only SwiftUI app (deployment target 16.0) that talks to an iOS device's own services (lockdownd, instproxy, house_arrest, AFC) to discover installed apps and back up their containers. It is designed to run sideloaded inside the **Nyxian** environment, connecting through a loopback usbmuxd/VPN proxy rather than USB. There is also an `AGENTS.md` with overlapping guidance — keep the two in sync when architecture changes.

## Build commands

macOS + Xcode are required for any build. There are **no tests and no lint/format/typecheck scripts** in this repo.

```bash
# Generate the Xcode project — REQUIRED first step; Unboxer.xcodeproj is gitignored.
# Re-run after any project.yml change.
xcodegen generate

# Full unsigned build
xcodebuild clean build \
  -project Unboxer.xcodeproj \
  -scheme Unboxer \
  -configuration Release \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" EXPANDED_CODE_SIGN_IDENTITY=""

# Rebuild RustBridge.xcframework from Rust source (needs `rustup target add aarch64-apple-ios`).
# Runs `make xcframework` in Unboxer/Scripts/RustBridge/, copies the result to
# Unboxer/Dependencies/, and thins OpenSSL.xcframework to ios-arm64 only.
./Unboxer/Scripts/build_rust_bridge.sh
```

CI (`.github/workflows/`, both manual `workflow_dispatch` only):

| Workflow | What it does |
|---|---|
| `build.yml` | xcodegen → xcodebuild → package IPA → GitHub Release (requires version input) |
| `build_unboxer_core.yml` | Rust build → `RustBridge.xcframework` + thin `OpenSSL.xcframework` → commit + push to the repo |

## Architecture

Three layers, top to bottom:

1. **SwiftUI UI** — `UnBoxerApp` → `ContentView` with a custom paged `TabView` (3 tabs in `AppTab`: Dashboard, Backups, Settings) and floating `TopTabBarView`. `PairingManager` is the app-wide `@EnvironmentObject`; it imports/parses/deletes `pairing_file.plist` in the app's Documents directory.
2. **Swift service singletons** (`Unboxer/Services/`) — `LockdownEngine` (parses the pairing plist, distinguishes RPPairing files with `private_key` from standard lockdown files with `UDID`, configures the Rust core, tests connectivity), `AppDiscoveryEngine` (fetches installed apps as JSON), `BackupEngine` (per-app backup to `Documents/Backups/<bundleID>_<timestamp>/` with a `metadata.json` per backup, lazy zip extraction).
3. **Rust core** via FFI — all device I/O happens in Rust (`Unboxer/Scripts/RustBridge/`), compiled to a static lib wrapped in `RustBridge.xcframework`.

Main flows:

- **Connect + discover**: `DashboardViewModel.establishLockdownConnection()` → `LockdownEngine.executeNativeEngine()` (sets RPPairing file in Rust if applicable, tests connection, fetches UDID) → `AppDiscoveryEngine.fetchAllApps(udid:)` → JSON array of instproxy app dicts decoded into `AppInfo`.
- **Backup**: `DashboardViewModel`/`BackupViewModel.performBackup()` → `BackupEngine.backupApp()` → `RustIdevice.backupApp()`. On the Rust side (`idevice_support/backup.rs`), house_arrest `vend_container` is tried first ("full" backup) and `vend_documents` is the fallback ("documents"); files are zipped on-device and the result comes back as JSON (`{"status", "zip_path", "backup_type"}`). Browsing a backup extracts the zip via `rust_bridge_extract_zip` into an `extracted/` subdir.

### Swift ↔ Rust FFI conventions

- Bindings use `@_silgen_name` (no bridging headers). Symbol names must match the `#[no_mangle] pub extern "C"` functions in `bridge_idevice.rs`/`bridge.rs` exactly — adding an FFI function means editing both sides **and rebuilding the xcframework** (locally via the script, or via the `build_unboxer_core.yml` workflow).
- `MinimuxerBridge.swift` = low-level handle-based wrappers (device/lockdown/AFC); `MinimuxerBridgeIdevice.swift` = the high-level `RustIdevice` class used by the services (connection test, UDID, install/remove/yeet, JIT/debug, provisioning profiles, DDI mount, app list, backup, zip extract).
- Two error patterns coexist: older functions return a `*mut IdeviceFfiError` (freed with `idevice_error_free`, surfaced as `NSError` by `rustIdeviceThrowIfNeeded`); newer ones (backup, extract) return a JSON string with `"status": "ok" | "error"`. Returned C strings are freed with `rust_bridge_idevice_free_string`.
- Rust crate layout: `bridge.rs` (rusty_libimobiledevice wrappers), `bridge_idevice.rs` (FFI exports), `idevice_support/` (per-feature async implementations: apps, backup, device, install, jit, mounter, provision, rsd), `post17.rs` (lazy tokio `RUNTIME` used to `block_on` the async `idevice` crate), `errors.rs`.

## Dependencies (all vendored — no SPM, no CocoaPods)

- Four C static-lib targets defined in `project.yml`, sources under `Unboxer/Dependencies/`: `libplist`, `libusbmuxd`, `libimobiledevice-glue`, `libimobiledevice`. They build with `-w` and a fixed set of `HAVE_*` preprocessor defines — mirror those settings if adding another C target.
- `OpenSSL.xcframework` and `RustBridge.xcframework`, both thinned to a single `ios-arm64` slice (no simulator/macOS slices — device-only builds). Never hand-edit these; regenerate via `build_rust_bridge.sh` or the CI workflow.

## Nyxian specifics / gotchas

- `Unboxer/Resources/Info.plist` is in Nyxian project format: top-level `NX*` keys, with the standard CFBundle keys nested inside the `NXBundleInfo` dict. `NXDeploymentTarget` (26.5) is the Nyxian SDK version, not the iOS deployment target.
- Entitlements (`Unboxer/Resources/Unboxer.entitlements`) are Nyxian-specific `com.nyxian.pe.*` keys; only `get_task_allowed` is true.
- No code signing anywhere (`CODE_SIGNING_ALLOWED=NO`, empty identity/team).
- At runtime, a pairing `.plist` must be imported via the Dashboard before any engine operation works, and `RustIdevice.testDeviceConnection()` is expected to fail gracefully when the loopback usbmuxd proxy/VPN is not running — code treats that as a normal state, not an error.
- `implementation_plan.md` describes a *proposed* (not implemented) pure Swift/C lockdownd engine; the shipping implementation is the Rust bridge.
