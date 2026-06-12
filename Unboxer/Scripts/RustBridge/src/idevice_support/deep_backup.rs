// Deep, whole-device backup via the com.apple.mobilebackup2 service — the same
// mechanism iTunes/Finder uses. This is the ONLY way to read the full data
// container (Library + Documents) of a production App Store app, because
// house_arrest's VendContainer is gated on the app being debuggable.
//
// mobilebackup2 always snapshots the whole device; there is no per-app filter
// in the protocol (files are stored by hash and only mapped to an app via
// Manifest.db at the end). So the flow is: run a device backup into a working
// directory, then the Swift layer parses Manifest.db and extracts only the
// requested AppDomain. The heavy DeviceLink protocol loop lives entirely in the
// `idevice` crate (MobileBackup2Client + FsBackupDelegate).

use std::path::Path;

use idevice::mobilebackup2::{FsBackupDelegate, MobileBackup2Client};
use serde_json::json;

use crate::idevice_support::device::fetch_udid_rppairing;
use crate::idevice_support::rsd::connect_to_rsd_services;

pub async fn deep_backup_rppairing(work_dir: &str) -> String {
    match try_deep_backup(work_dir).await {
        Ok(j) => j,
        Err(e) => json!({ "status": "error", "error": e }).to_string(),
    }
}

async fn try_deep_backup(work_dir: &str) -> Result<String, String> {
    // The backup is written under work_dir/<source>/ — pass the device UDID as
    // the source so the Swift side knows where to find Manifest.db.
    let udid = fetch_udid_rppairing()
        .await
        .map_err(|e| format!("fetch udid: {e}"))?;

    let mut client = connect_to_rsd_services::<MobileBackup2Client>()
        .await
        .map_err(|e| format!("mobilebackup2 connect: {e}"))?;

    // We can only read an unencrypted backup. If the device (or an MDM profile)
    // forces encryption, bail with a clear message rather than producing an
    // unreadable archive.
    if let Ok(true) = client.check_backup_encryption().await {
        return Err(
            "This device is set to encrypt its backups, so Unboxer cannot read \
             the app data. Turn off \u{201c}Encrypt local backup\u{201d} for this \
             device (or remove the managing profile) and try again."
                .to_string(),
        );
    }

    let root = Path::new(work_dir);
    std::fs::create_dir_all(root).map_err(|e| format!("create work dir: {e}"))?;

    client
        .backup_from_path(root, Some(udid.as_str()), None, &FsBackupDelegate)
        .await
        .map_err(|e| format!("device backup: {e}"))?;

    Ok(json!({
        "status": "success",
        "backup_root": root.to_string_lossy().into_owned(),
        "source": udid,
    })
    .to_string())
}
