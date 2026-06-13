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
use std::fs::{File, OpenOptions};
use std::future::Future;
use std::io::{Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::pin::Pin;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use idevice::heartbeat::HeartbeatClient;
use idevice::mobilebackup2::{
    BackupDelegate, DirEntryInfo, FsBackupDelegate, MobileBackup2Client,
};
use idevice::{HeartbeatError, IdeviceError};
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

// ---------------------------------------------------------------------------
// Diagnostic tracer
//
// Phase 1 of the space-saving redesign: before doctoring Manifest.db to drive a
// selective incremental backup, we must observe the EXACT host-side filesystem
// sequence the device drives over mobilebackup2 on this specific iOS version —
// which files it downloads back from us at the start, and the precise
// CopyItem/MoveFiles/RemoveFiles "Snapshot" dance. This delegate records every
// operation to a log without changing behavior. Blob writes (the device
// uploading hashed file content) are counted, not logged line-by-line, so the
// trace stays readable on a full backup.
// ---------------------------------------------------------------------------

struct Tracer {
    file: Mutex<Option<File>>,
    blob_writes: AtomicU64,
}

impl Tracer {
    fn create(path: &Path) -> Self {
        let file = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(path)
            .ok();
        Tracer {
            file: Mutex::new(file),
            blob_writes: AtomicU64::new(0),
        }
    }

    fn log(&self, line: &str) {
        let ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        if let Ok(mut g) = self.file.lock() {
            if let Some(f) = g.as_mut() {
                let _ = writeln!(f, "{ms} {line}");
                let _ = f.flush();
            }
        }
    }
}

/// A hashed blob (40+ hex filename) = device file content, as opposed to a
/// metadata file (Status.plist, Manifest.db, Info.plist, Manifest.plist).
fn is_blob_path(path: &Path) -> bool {
    path.file_name()
        .and_then(|n| n.to_str())
        .map(|n| n.len() >= 40 && n.bytes().all(|b| b.is_ascii_hexdigit()))
        .unwrap_or(false)
}

fn rel(path: &Path) -> String {
    // Keep the last two components for readability (e.g. "ab/abcdef...").
    let comps: Vec<_> = path.components().collect();
    let n = comps.len();
    let start = n.saturating_sub(2);
    comps[start..]
        .iter()
        .map(|c| c.as_os_str().to_string_lossy())
        .collect::<Vec<_>>()
        .join("/")
}

fn ok_err<T>(r: &Result<T, IdeviceError>) -> String {
    match r {
        Ok(_) => "ok".to_string(),
        Err(e) => format!("ERR({})", describe_err(e)),
    }
}

/// Wraps any delegate, mirroring every call into a `Tracer`.
struct TracingDelegate<'t, D: BackupDelegate> {
    inner: D,
    tracer: &'t Tracer,
}

impl<'t, D: BackupDelegate> BackupDelegate for TracingDelegate<'t, D> {
    fn get_free_disk_space(&self, path: &Path) -> u64 {
        let v = self.inner.get_free_disk_space(path);
        self.tracer.log(&format!("get_free_disk_space {} = {v}", rel(path)));
        v
    }

    fn open_file_read<'a>(
        &'a self,
        path: &'a Path,
    ) -> Pin<Box<dyn Future<Output = Result<Box<dyn Read + Send>, IdeviceError>> + Send + 'a>>
    {
        // Device downloading a file FROM the host — the key incremental signal.
        let tracer = self.tracer;
        let p = rel(path);
        let fut = self.inner.open_file_read(path);
        Box::pin(async move {
            let r = fut.await;
            tracer.log(&format!("DOWNLOAD(open_read) {p} = {}", ok_err(&r)));
            r
        })
    }

    fn create_file_write<'a>(
        &'a self,
        path: &'a Path,
    ) -> Pin<Box<dyn Future<Output = Result<Box<dyn Write + Send>, IdeviceError>> + Send + 'a>>
    {
        let tracer = self.tracer;
        let blob = is_blob_path(path);
        let p = rel(path);
        let fut = self.inner.create_file_write(path);
        Box::pin(async move {
            let r = fut.await;
            if blob {
                let n = tracer.blob_writes.fetch_add(1, Ordering::Relaxed) + 1;
                if n <= 3 || n % 5000 == 0 {
                    tracer.log(&format!("UPLOAD(blob #{n}) {p} = {}", ok_err(&r)));
                }
            } else {
                tracer.log(&format!("UPLOAD(meta) {p} = {}", ok_err(&r)));
            }
            r
        })
    }

    fn create_dir_all<'a>(
        &'a self,
        path: &'a Path,
    ) -> Pin<Box<dyn Future<Output = Result<(), IdeviceError>> + Send + 'a>> {
        let tracer = self.tracer;
        let p = rel(path);
        let fut = self.inner.create_dir_all(path);
        Box::pin(async move {
            let r = fut.await;
            if !is_blob_path(Path::new(&p)) {
                tracer.log(&format!("create_dir_all {p} = {}", ok_err(&r)));
            }
            r
        })
    }

    fn remove<'a>(
        &'a self,
        path: &'a Path,
    ) -> Pin<Box<dyn Future<Output = Result<(), IdeviceError>> + Send + 'a>> {
        let tracer = self.tracer;
        let p = rel(path);
        let blob = is_blob_path(path);
        let fut = self.inner.remove(path);
        Box::pin(async move {
            let r = fut.await;
            if !blob {
                tracer.log(&format!("REMOVE {p} = {}", ok_err(&r)));
            }
            r
        })
    }

    fn rename<'a>(
        &'a self,
        from: &'a Path,
        to: &'a Path,
    ) -> Pin<Box<dyn Future<Output = Result<(), IdeviceError>> + Send + 'a>> {
        let tracer = self.tracer;
        let (f, t) = (rel(from), rel(to));
        let fut = self.inner.rename(from, to);
        Box::pin(async move {
            let r = fut.await;
            tracer.log(&format!("RENAME {f} -> {t} = {}", ok_err(&r)));
            r
        })
    }

    fn copy<'a>(
        &'a self,
        src: &'a Path,
        dst: &'a Path,
    ) -> Pin<Box<dyn Future<Output = Result<(), IdeviceError>> + Send + 'a>> {
        let tracer = self.tracer;
        let (s, d) = (rel(src), rel(dst));
        let fut = self.inner.copy(src, dst);
        Box::pin(async move {
            let r = fut.await;
            tracer.log(&format!("COPY {s} -> {d} = {}", ok_err(&r)));
            r
        })
    }

    fn exists<'a>(&'a self, path: &'a Path) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
        let tracer = self.tracer;
        let p = rel(path);
        let blob = is_blob_path(path);
        let fut = self.inner.exists(path);
        Box::pin(async move {
            let r = fut.await;
            if !blob {
                tracer.log(&format!("exists {p} = {r}"));
            }
            r
        })
    }

    fn is_dir<'a>(&'a self, path: &'a Path) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
        let tracer = self.tracer;
        let p = rel(path);
        let fut = self.inner.is_dir(path);
        Box::pin(async move {
            let r = fut.await;
            tracer.log(&format!("is_dir {p} = {r}"));
            r
        })
    }

    fn list_dir<'a>(
        &'a self,
        path: &'a Path,
    ) -> Pin<Box<dyn Future<Output = Result<Vec<DirEntryInfo>, IdeviceError>> + Send + 'a>> {
        let tracer = self.tracer;
        let p = rel(path);
        let fut = self.inner.list_dir(path);
        Box::pin(async move {
            let r = fut.await;
            let n = r.as_ref().map(|v| v.len()).unwrap_or(0);
            tracer.log(&format!("list_dir {p} = {} ({n} entries)", ok_err(&r)));
            r
        })
    }

    fn on_file_received(&self, path: &str, file_count: u32) {
        self.inner.on_file_received(path, file_count);
    }

    fn on_progress(&self, bytes_done: u64, bytes_total: u64, overall_progress: f64) {
        self.inner.on_progress(bytes_done, bytes_total, overall_progress);
    }
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
    // The trace log lives next to (not inside) the work dir, which Swift wipes
    // between runs, so it survives for the user to retrieve and send back.
    let trace_path = Path::new(work_dir)
        .parent()
        .unwrap_or_else(|| Path::new(work_dir))
        .join("DeepBackupTrace.log");
    let trace_str = trace_path.to_string_lossy().into_owned();
    let tracer = Tracer::create(&trace_path);
    tracer.log(&format!("=== deep backup start; work_dir={work_dir} ==="));

    let out = match try_deep_backup(work_dir, &tracer).await {
        Ok(mut val) => {
            val["trace_log"] = json!(trace_str);
            val.to_string()
        }
        Err(e) => json!({ "status": "error", "error": e, "trace_log": trace_str }).to_string(),
    };
    tracer.log("=== deep backup end ===");
    out
}

/// `IdeviceError::Socket`'s Display hides the inner io::Error ("device socket
/// io failed"), which is useless for diagnosing tunnel drops — surface it.
fn describe_err(e: &IdeviceError) -> String {
    match e {
        IdeviceError::Socket(io) => format!("socket I/O failed: {io} [{:?}]", io.kind()),
        _ => e.to_string(),
    }
}

enum BackupFailure {
    /// Device enforces encrypted backups — user-facing message, never retried.
    Encrypted(String),
    /// Tunnel/socket-level failure — worth one retry over a fresh tunnel.
    Transport(String),
    Other(String),
}

impl BackupFailure {
    fn into_message(self) -> String {
        match self {
            Self::Encrypted(m) | Self::Transport(m) | Self::Other(m) => m,
        }
    }
}

fn classify(stage: &str, e: &IdeviceError) -> BackupFailure {
    let desc = format!("{stage}: {}", describe_err(e));
    match e {
        IdeviceError::Socket(_) => BackupFailure::Transport(desc),
        _ => BackupFailure::Other(desc),
    }
}

async fn try_deep_backup(work_dir: &str, tracer: &Tracer) -> Result<serde_json::Value, String> {
    reset_progress();

    // The backup is written under work_dir/<source>/ — pass the device UDID as
    // the source so the Swift side knows where to find Manifest.db.
    let udid = fetch_udid_rppairing()
        .await
        .map_err(|e| format!("fetch udid: {}", describe_err(&e)))?;
    tracer.log(&format!("udid={udid}"));

    let root = Path::new(work_dir);
    std::fs::create_dir_all(root).map_err(|e| format!("create work dir: {e}"))?;

    // A transport drop (loopback VPN hiccup, tunnel reset) gets one retry; the
    // dead cached tunnel fails its liveness probe and is rebuilt automatically.
    if let Err(failure) = run_device_backup(root, &udid, tracer).await {
        match failure {
            BackupFailure::Transport(desc) => {
                log::warn!("deep backup transport failure ({desc}); retrying over a fresh tunnel");
                tracer.log(&format!("RETRY after transport failure: {desc}"));
                reset_progress();
                run_device_backup(root, &udid, tracer)
                    .await
                    .map_err(|e| format!("device backup (after retry): {}", e.into_message()))?;
            }
            other => return Err(format!("device backup: {}", other.into_message())),
        }
    }

    Ok(json!({
        "status": "success",
        "backup_root": root.to_string_lossy().into_owned(),
        "source": udid,
    }))
}

async fn run_device_backup(root: &Path, udid: &str, tracer: &Tracer) -> Result<(), BackupFailure> {
    let mut client = connect_to_rsd_services::<MobileBackup2Client>()
        .await
        .map_err(|e| classify("mobilebackup2 connect", &e))?;

    // We can only read an unencrypted backup. If the device (or an MDM profile)
    // forces encryption, bail with a clear message rather than producing an
    // unreadable archive.
    if let Ok(true) = client.check_backup_encryption().await {
        return Err(BackupFailure::Encrypted(
            "This device is set to encrypt its backups, so Unboxer cannot read \
             the app data. Turn off \u{201c}Encrypt local backup\u{201d} for this \
             device (or remove the managing profile) and try again."
                .to_string(),
        ));
    }

    // Keepalive: a backup goes silent for long stretches (passcode entry,
    // on-device snapshot preparation) and the loopback VPN/proxy can drop the
    // idle tunnel underneath us. Answering the device's Marco pings on a
    // parallel stream keeps real traffic flowing over the same tunnel for the
    // whole backup. Best effort — the backup proceeds without it.
    let heartbeat = match connect_to_rsd_services::<HeartbeatClient>().await {
        Ok(mut hb) => Some(crate::post17::RUNTIME.spawn(async move {
            let mut wait = 15u64;
            loop {
                match hb.get_marco(wait + 10).await {
                    Ok(interval) => {
                        wait = interval.max(5);
                        if hb.send_polo().await.is_err() {
                            break;
                        }
                    }
                    // A quiet stretch is fine; keep listening.
                    Err(IdeviceError::Heartbeat(HeartbeatError::Timeout)) => continue,
                    Err(_) => break,
                }
            }
        })),
        Err(e) => {
            log::warn!("heartbeat unavailable ({e}); deep backup may drop on an idle tunnel");
            None
        }
    };

    let delegate = TracingDelegate {
        inner: ProgressDelegate {
            inner: FsBackupDelegate,
        },
        tracer,
    };
    let result = client
        .backup_from_path(root, Some(udid), None, &delegate)
        .await;

    if let Some(hb) = heartbeat {
        hb.abort();
    }
    let status = result.map_err(|e| classify("device backup", &e))?;

    // The DL loop returns the device's final status dictionary as Ok even when
    // it carries a failure (cancelled, out of space, ...) — check it ourselves.
    if let Some(dict) = status {
        let code = dict
            .get("ErrorCode")
            .and_then(|v| v.as_signed_integer())
            .unwrap_or(0);
        if code != 0 {
            let desc = dict
                .get("ErrorDescription")
                .and_then(|v| v.as_string())
                .unwrap_or("no description");
            return Err(BackupFailure::Other(format!(
                "the device reported backup error {code}: {desc}"
            )));
        }
    }
    Ok(())
}
