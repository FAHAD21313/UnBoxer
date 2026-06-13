use std::io::ErrorKind;
use std::io::Write;
use std::path::Path;

use idevice::afc::errors::AfcError;
use idevice::afc::opcode::AfcFopenMode;
use idevice::house_arrest::HouseArrestClient;
use idevice::IdeviceError;
use serde_json::{json, Value};
use tokio::io::AsyncReadExt;

use crate::idevice_support::rsd::connect_to_rsd_services;

pub async fn backup_app_rppairing(bundle_id: &str, output_dir: &str) -> String {
    match try_backup(bundle_id, output_dir).await {
        Ok(json) => json,
        Err(e) => json!({ "status": "error", "error": e }).to_string(),
    }
}

async fn try_backup(bundle_id: &str, output_dir: &str) -> Result<String, String> {
    let ha = connect_to_rsd_services::<HouseArrestClient>()
        .await
        .map_err(|e| format!("{} (connect: {e})", friendly_vend_error(bundle_id, &e)))?;

    // Prefer the full data container; fall back to the documents-only vend.
    let (mut afc, backup_type) = match ha.vend_container(bundle_id).await {
        Ok(c) => (c, "full"),
        Err(e1) => {
            let ha2 = connect_to_rsd_services::<HouseArrestClient>()
                .await
                .map_err(|e2| {
                    format!(
                        "{} (full: {e1}; reconnect: {e2})",
                        friendly_vend_error(bundle_id, &e2)
                    )
                })?;
            match ha2.vend_documents(bundle_id).await {
                Ok(c) => (c, "documents"),
                Err(e2) => {
                    return Err(format!(
                        "{} (full: {e1}; documents: {e2})",
                        friendly_vend_error(bundle_id, &e2)
                    ))
                }
            }
        }
    };

    let out_path = Path::new(output_dir);
    std::fs::create_dir_all(out_path).map_err(|e| format!("create output dir: {e}"))?;

    let zip_path = out_path.join(format!("{bundle_id}.zip"));
    let file = std::fs::File::create(&zip_path).map_err(|e| format!("create zip: {e}"))?;
    let mut zip = zip::ZipWriter::new(file);

    // AFC paths are absolute. A full container vend is rooted at "/", while a
    // documents-only vend can only access "/Documents" (anything else is
    // permission-denied). Seeding with the wrong root yields an empty archive.
    let root = if backup_type == "documents" {
        "/Documents"
    } else {
        "/"
    };

    // We never abort the walk on a per-entry error; we record it and keep going
    // so the backup stays as complete as the device's permissions allow. Only a
    // failed local write (corrupt archive) aborts. Everything skipped is logged
    // in _UnboxerManifest.json so empty folders are explainable.
    let mut stack = vec![root.to_string()];
    let mut total_bytes: i64 = 0;
    let mut file_count: u64 = 0;
    let mut dir_count: u64 = 0;
    let mut symlink_count: u64 = 0;
    let mut skipped_count: u64 = 0;
    let mut incomplete = false;
    let mut skipped: Vec<Value> = Vec::new();
    let mut symlinks: Vec<Value> = Vec::new();

    while let Some(dir) = stack.pop() {
        let entries = match afc.list_dir(&dir).await {
            Ok(e) => e,
            Err(e) => {
                record_skip(
                    &mut skipped,
                    &mut skipped_count,
                    &mut incomplete,
                    dir.trim_start_matches('/'),
                    "dir",
                    afc_skip_reason(&e),
                    e.to_string(),
                );
                continue;
            }
        };

        for entry in &entries {
            if entry == "." || entry == ".." {
                continue;
            }

            let full = if dir == "/" {
                format!("/{entry}")
            } else {
                format!("{dir}/{entry}")
            };

            // Zip entry names must be relative so extraction stays inside the
            // output directory (a leading "/" would make Path::join escape it).
            let rel = full.trim_start_matches('/').to_string();

            let info = match afc.get_file_info(&full).await {
                Ok(i) => i,
                Err(e) => {
                    record_skip(
                        &mut skipped,
                        &mut skipped_count,
                        &mut incomplete,
                        &rel,
                        "entry",
                        afc_skip_reason(&e),
                        e.to_string(),
                    );
                    continue;
                }
            };

            match info.st_ifmt.as_str() {
                "S_IFDIR" => {
                    if let Err(e) =
                        zip.add_directory(&rel, zip::write::SimpleFileOptions::default())
                    {
                        record_skip(
                            &mut skipped,
                            &mut skipped_count,
                            &mut incomplete,
                            &rel,
                            "dir",
                            "zip_error",
                            e.to_string(),
                        );
                        continue;
                    }
                    dir_count += 1;
                    stack.push(full);
                }
                "S_IFREG" => {
                    let mut fh = match afc.open(&full, AfcFopenMode::RdOnly).await {
                        Ok(f) => f,
                        Err(e) => {
                            record_skip(
                                &mut skipped,
                                &mut skipped_count,
                                &mut incomplete,
                                &rel,
                                "file",
                                afc_skip_reason(&e),
                                e.to_string(),
                            );
                            continue;
                        }
                    };

                    if let Err(e) =
                        zip.start_file(&rel, zip::write::SimpleFileOptions::default())
                    {
                        record_skip(
                            &mut skipped,
                            &mut skipped_count,
                            &mut incomplete,
                            &rel,
                            "file",
                            "zip_error",
                            e.to_string(),
                        );
                        continue;
                    }

                    let mut buf = vec![0u8; 65536];
                    let mut read_failed = false;
                    loop {
                        let n = match fh.read(&mut buf).await {
                            Ok(0) => break,
                            Ok(n) => n,
                            Err(e) => {
                                // A read error affects only this one file; record
                                // it (the entry may be partial) and move on.
                                record_skip(
                                    &mut skipped,
                                    &mut skipped_count,
                                    &mut incomplete,
                                    &rel,
                                    "file",
                                    read_skip_reason(&e),
                                    e.to_string(),
                                );
                                read_failed = true;
                                break;
                            }
                        };
                        total_bytes += n as i64;
                        // A local write failure means the archive is corrupt: abort.
                        zip.write_all(&buf[..n])
                            .map_err(|e| format!("zip write {full:?}: {e}"))?;
                    }
                    if !read_failed {
                        file_count += 1;
                    }
                }
                "S_IFLNK" => {
                    // Record the link (and its target) for transparency. We never
                    // follow it, which avoids cycles and sandbox escapes.
                    let target = info.st_link_target.clone().unwrap_or_default();
                    symlinks.push(json!({ "path": rel, "target": target }));
                    symlink_count += 1;
                }
                other => {
                    // Sockets, fifos, devices, etc. — nothing to archive, but log
                    // it so the entry is never silently dropped.
                    record_skip(
                        &mut skipped,
                        &mut skipped_count,
                        &mut incomplete,
                        &rel,
                        "entry",
                        "unsupported",
                        other.to_string(),
                    );
                }
            }
        }
    }

    let manifest = json!({
        "schema_version": 1,
        "bundle_id": bundle_id,
        "backup_type": backup_type,
        "root": root,
        "file_count": file_count,
        "dir_count": dir_count,
        "symlink_count": symlink_count,
        "total_bytes": total_bytes,
        "skipped_count": skipped_count,
        "partial": skipped_count > 0,
        "incomplete": incomplete,
        "skipped": skipped,
        "symlinks": symlinks,
    });
    let manifest_bytes =
        serde_json::to_vec_pretty(&manifest).map_err(|e| format!("manifest encode: {e}"))?;
    zip.start_file("_UnboxerManifest.json", zip::write::SimpleFileOptions::default())
        .map_err(|e| format!("manifest entry: {e}"))?;
    zip.write_all(&manifest_bytes)
        .map_err(|e| format!("manifest write: {e}"))?;

    zip.finish().map_err(|e| format!("zip finish: {e}"))?;

    Ok(json!({
        "status": "success",
        "zip_path": zip_path.to_string_lossy().into_owned(),
        "backup_type": backup_type,
        "total_bytes": total_bytes,
        "file_count": file_count,
        "dir_count": dir_count,
        "symlink_count": symlink_count,
        "skipped_count": skipped_count,
        "partial": skipped_count > 0,
        "incomplete": incomplete,
    })
    .to_string())
}

pub async fn extract_zip_rppairing(zip_path: &str, output_dir: &str) -> String {
    match try_extract(zip_path, output_dir).await {
        Ok(json) => json,
        Err(e) => json!({ "status": "error", "error": e }).to_string(),
    }
}

async fn try_extract(zip_path: &str, output_dir: &str) -> Result<String, String> {
    let out_path = Path::new(output_dir);
    std::fs::create_dir_all(out_path).map_err(|e| format!("create extract dir: {e}"))?;

    let file = std::fs::File::open(zip_path).map_err(|e| format!("open zip: {e}"))?;
    let mut archive = zip::ZipArchive::new(file).map_err(|e| format!("read zip: {e}"))?;

    for i in 0..archive.len() {
        let mut entry = archive
            .by_index(i)
            .map_err(|e| format!("zip entry {i}: {e}"))?;
        let name = entry.name().to_string();
        let target = out_path.join(&name);

        if entry.is_dir() {
            std::fs::create_dir_all(&target).ok();
        } else {
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent)
                    .map_err(|e| format!("create parent dir: {e}"))?;
            }
            let mut out = std::fs::File::create(&target)
                .map_err(|e| format!("create file {name:?}: {e}"))?;
            std::io::copy(&mut entry, &mut out)
                .map_err(|e| format!("extract {name:?}: {e}"))?;
        }
    }

    Ok(r#"{"status":"success"}"#.to_string())
}

/// Records a skipped path in the manifest and bumps the counter. A
/// connection-level reason also flags the whole backup as incomplete.
fn record_skip(
    skipped: &mut Vec<Value>,
    skipped_count: &mut u64,
    incomplete: &mut bool,
    path: &str,
    kind: &str,
    reason: &str,
    detail: String,
) {
    if reason == "connection_lost" {
        *incomplete = true;
    }
    *skipped_count += 1;
    skipped.push(json!({
        "path": path,
        "kind": kind,
        "reason": reason,
        "detail": detail,
    }));
}

/// Classifies an AFC-layer error into a manifest skip reason. AFC-level
/// failures are per-object; a lost socket is the only connection-level case.
fn afc_skip_reason(e: &IdeviceError) -> &'static str {
    match e {
        IdeviceError::Afc(afc) => match afc {
            AfcError::PermDenied => "permission_denied",
            AfcError::ObjectNotFound => "not_found",
            AfcError::OpNotSupported | AfcError::ObjectIsDir => "unsupported",
            // AfcError is #[non_exhaustive]; anything else is still per-object.
            _ => "afc_error",
        },
        IdeviceError::Socket(_) => "connection_lost",
        _ => "unknown",
    }
}

/// Classifies a streaming read error (std::io::Error from AsyncRead).
fn read_skip_reason(e: &std::io::Error) -> &'static str {
    match e.kind() {
        ErrorKind::BrokenPipe
        | ErrorKind::ConnectionReset
        | ErrorKind::ConnectionAborted
        | ErrorKind::NotConnected
        | ErrorKind::UnexpectedEof => "connection_lost",
        _ => "read_error",
    }
}

/// Turns a vend failure into a clear, user-facing message.
fn friendly_vend_error(bundle_id: &str, e: &IdeviceError) -> String {
    match e {
        IdeviceError::UnknownErrorType(s) if s.as_str() == "InstallationLookupFailed" => format!(
            "Could not open the data container for \u{201c}{bundle_id}\u{201d}. \
             The app may be protected, managed by MDM, or has never been launched. \
             Launch the app once, then try backing up again."
        ),
        IdeviceError::Socket(_) => format!(
            "Lost connection to the device while opening \u{201c}{bundle_id}\u{201d}. \
             Reconnect and try again."
        ),
        other => format!("Could not access \u{201c}{bundle_id}\u{201d}: {other}"),
    }
}
