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
// `idevice` crate (MobileBackup2Client + a BackupDelegate).
//
// Progress: the device reports an overall percentage (0–100) inside the DL
// messages, surfaced through `BackupDelegate::on_progress`. We mirror it into
// process-wide atomics so the Swift side can poll it with
// `rust_bridge_idevice_deep_backup_progress` while the blocking backup call is
// in flight on another thread.

use std::ffi::CString;
use std::future::Future;
use std::io::{Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::pin::Pin;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};

use idevice::mobilebackup2::{
    BackupDelegate, DirEntryInfo, FsBackupDelegate, MobileBackup2Client,
};
use idevice::IdeviceError;
use serde_json::json;

use crate::idevice_support::device::fetch_udid_rppairing;
use crate::idevice_support::rsd::connect_to_rsd_services;

// Device-reported overall percentage ×10 (one decimal of precision); -1 until
// the device sends its first progress message.
static OVERALL_PCT_X10: AtomicI64 = AtomicI64::new(-1);
// bytes_done / file_count reset per upload batch, so completed batches are
// rolled into a *_BASE counter and the live batch value is kept separately.
// Only the single DL-loop thread writes these; readers just need a snapshot.
static BATCH_BYTES: AtomicU64 = AtomicU64::new(0);
static BASE_BYTES: AtomicU64 = AtomicU64::new(0);
static BATCH_FILES: AtomicU64 = AtomicU64::new(0);
static BASE_FILES: AtomicU64 = AtomicU64::new(0);

fn reset_progress() {
    OVERALL_PCT_X10.store(-1, Ordering::Relaxed);
    BATCH_BYTES.store(0, Ordering::Relaxed);
    BASE_BYTES.store(0, Ordering::Relaxed);
    BATCH_FILES.store(0, Ordering::Relaxed);
    BASE_FILES.store(0, Ordering::Relaxed);
}

/// Snapshot of the in-flight deep backup, polled from Swift.
/// `percent` is -1 until the device reports progress.
pub fn deep_backup_progress_json() -> String {
    let pct_x10 = OVERALL_PCT_X10.load(Ordering::Relaxed);
    let percent = if pct_x10 < 0 {
        -1.0
    } else {
        (pct_x10 as f64 / 10.0).min(100.0)
    };
    let bytes = BASE_BYTES.load(Ordering::Relaxed) + BATCH_BYTES.load(Ordering::Relaxed);
    let files = BASE_FILES.load(Ordering::Relaxed) + BATCH_FILES.load(Ordering::Relaxed);
    json!({ "percent": percent, "bytes_done": bytes, "files": files }).to_string()
}

/// `FsBackupDelegate` plus progress mirroring and real free-disk-space
/// reporting (the stock delegate returns 0, which the device may treat as
/// "no room for a backup").
struct ProgressDelegate {
    inner: FsBackupDelegate,
}

impl BackupDelegate for ProgressDelegate {
    fn get_free_disk_space(&self, path: &Path) -> u64 {
        let Ok(cpath) = CString::new(path.as_os_str().as_bytes()) else {
            return 0;
        };
        let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
        if unsafe { libc::statvfs(cpath.as_ptr(), &mut st) } == 0 {
            (st.f_bavail as u64).saturating_mul(st.f_frsize as u64)
        } else {
            0
        }
    }

    fn open_file_read<'a>(
        &'a self,
        path: &'a Path,
    ) -> Pin<Box<dyn Future<Output = Result<Box<dyn Read + Send>, IdeviceError>> + Send + 'a>>
    {
        self.inner.open_file_read(path)
    }

    fn create_file_write<'a>(
        &'a self,
        path: &'a Path,
    ) -> Pin<Box<dyn Future<Output = Result<Box<dyn Write + Send>, IdeviceError>> + Send + 'a>>
    {
        self.inner.create_file_write(path)
    }

    fn create_dir_all<'a>(
        &'a self,
        path: &'a Path,
    ) -> Pin<Box<dyn Future<Output = Result<(), IdeviceError>> + Send + 'a>> {
        self.inner.create_dir_all(path)
    }

    fn remove<'a>(
        &'a self,
        path: &'a Path,
    ) -> Pin<Box<dyn Future<Output = Result<(), IdeviceError>> + Send + 'a>> {
        self.inner.remove(path)
    }

    fn rename<'a>(
        &'a self,
        from: &'a Path,
        to: &'a Path,
    ) -> Pin<Box<dyn Future<Output = Result<(), IdeviceError>> + Send + 'a>> {
        self.inner.rename(from, to)
    }

    fn copy<'a>(
        &'a self,
        src: &'a Path,
        dst: &'a Path,
    ) -> Pin<Box<dyn Future<Output = Result<(), IdeviceError>> + Send + 'a>> {
        self.inner.copy(src, dst)
    }

    fn exists<'a>(&'a self, path: &'a Path) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
        self.inner.exists(path)
    }

    fn is_dir<'a>(&'a self, path: &'a Path) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
        self.inner.is_dir(path)
    }

    fn list_dir<'a>(
        &'a self,
        path: &'a Path,
    ) -> Pin<Box<dyn Future<Output = Result<Vec<DirEntryInfo>, IdeviceError>> + Send + 'a>> {
        self.inner.list_dir(path)
    }

    fn on_file_received(&self, _path: &str, file_count: u32) {
        // file_count is the running total within the current batch; a drop
        // means a new batch started, so fold the finished one into the base.
        let count = file_count as u64;
        let last = BATCH_FILES.swap(count, Ordering::Relaxed);
        if count < last {
            BASE_FILES.fetch_add(last, Ordering::Relaxed);
        }
    }

    fn on_progress(&self, bytes_done: u64, _bytes_total: u64, overall_progress: f64) {
        let last = BATCH_BYTES.swap(bytes_done, Ordering::Relaxed);
        if bytes_done < last {
            BASE_BYTES.fetch_add(last, Ordering::Relaxed);
        }
        if overall_progress >= 0.0 {
            OVERALL_PCT_X10.store((overall_progress * 10.0) as i64, Ordering::Relaxed);
        }
    }
}

pub async fn deep_backup_rppairing(work_dir: &str) -> String {
    match try_deep_backup(work_dir).await {
        Ok(j) => j,
        Err(e) => json!({ "status": "error", "error": e }).to_string(),
    }
}

async fn try_deep_backup(work_dir: &str) -> Result<String, String> {
    reset_progress();

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

    let delegate = ProgressDelegate {
        inner: FsBackupDelegate,
    };
    client
        .backup_from_path(root, Some(udid.as_str()), None, &delegate)
        .await
        .map_err(|e| format!("device backup: {e}"))?;

    Ok(json!({
        "status": "success",
        "backup_root": root.to_string_lossy().into_owned(),
        "source": udid,
    })
    .to_string())
}
