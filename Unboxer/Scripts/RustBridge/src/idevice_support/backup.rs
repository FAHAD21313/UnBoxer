use std::io::Write;
use std::path::Path;

use idevice::afc::opcode::AfcFopenMode;
use idevice::house_arrest::HouseArrestClient;
use tokio::io::AsyncReadExt;

use crate::idevice_support::rsd::connect_to_rsd_services;

pub async fn backup_app_rppairing(bundle_id: &str, output_dir: &str) -> String {
    match try_backup(bundle_id, output_dir).await {
        Ok(json) => json,
        Err(e) => format!(r#"{{"status":"error","error":"{}"}}"#, escape_json(&e)),
    }
}

async fn try_backup(bundle_id: &str, output_dir: &str) -> Result<String, String> {
    let ha = connect_to_rsd_services::<HouseArrestClient>()
        .await
        .map_err(|e| format!("house_arrest connect: {e}"))?;

    let (mut afc, backup_type) = match ha.vend_container(bundle_id).await {
        Ok(c) => (c, "full"),
        Err(e1) => {
            let ha2 = connect_to_rsd_services::<HouseArrestClient>()
                .await
                .map_err(|e2| {
                    format!(
                        "backup failed for '{bundle_id}': \
                         vend_container: {e1}; \
                         then reconnect for fallback failed: {e2}"
                    )
                })?;
            match ha2.vend_documents(bundle_id).await {
                Ok(c) => (c, "documents"),
                Err(e2) => {
                    return Err(format!(
                        "backup failed for '{bundle_id}': \
                         vend_container: {e1}; \
                         vend_documents: {e2}"
                    ))
                }
            }
        }
    };

    let out_path = Path::new(output_dir);
    std::fs::create_dir_all(out_path)
        .map_err(|e| format!("create output dir: {e}"))?;

    let zip_path = out_path.join(format!("{bundle_id}.zip"));
    let file = std::fs::File::create(&zip_path)
        .map_err(|e| format!("create zip: {e}"))?;
    let mut zip = zip::ZipWriter::new(file);

    let mut stack = vec![String::new()];
    let mut total_bytes: i64 = 0;

    while let Some(dir) = stack.pop() {
        let entries = afc
            .list_dir(&dir)
            .await
            .map_err(|e| format!("list_dir {dir:?}: {e}"))?;

        for entry in &entries {
            if entry == "." || entry == ".." {
                continue;
            }

            let full = if dir.is_empty() {
                entry.clone()
            } else {
                format!("{dir}/{entry}")
            };

            let info = afc
                .get_file_info(&full)
                .await
                .map_err(|e| format!("get_file_info {full:?}: {e}"))?;

            match info.st_ifmt.as_str() {
                "S_IFDIR" => {
                    zip.add_directory(&full, zip::write::SimpleFileOptions::default())
                        .map_err(|e| format!("zip dir {full:?}: {e}"))?;
                    stack.push(full);
                }
                "S_IFREG" => {
                    let mut fh = afc
                        .open(&full, AfcFopenMode::RdOnly)
                        .await
                        .map_err(|e| format!("open {full:?}: {e}"))?;

                    zip.start_file(&full, zip::write::SimpleFileOptions::default())
                        .map_err(|e| format!("zip file {full:?}: {e}"))?;

                    let mut buf = vec![0u8; 65536];
                    loop {
                        let n = fh
                            .read(&mut buf)
                            .await
                            .map_err(|e| format!("read {full:?}: {e}"))?;
                        if n == 0 {
                            break;
                        }
                        total_bytes += n as i64;
                        zip.write_all(&buf[..n])
                            .map_err(|e| format!("zip write {full:?}: {e}"))?;
                    }
                }
                _ => {}
            }
        }
    }

    zip.finish()
        .map_err(|e| format!("zip finish: {e}"))?;

    let z = zip_path.to_string_lossy();
    Ok(format!(
        r#"{{"status":"success","zip_path":"{}","total_bytes":{},"backup_type":"{}"}}"#,
        escape_json(&z),
        total_bytes,
        backup_type,
    ))
}

pub async fn extract_zip_rppairing(zip_path: &str, output_dir: &str) -> String {
    match try_extract(zip_path, output_dir).await {
        Ok(json) => json,
        Err(e) => format!(r#"{{"status":"error","error":"{}"}}"#, escape_json(&e)),
    }
}

async fn try_extract(zip_path: &str, output_dir: &str) -> Result<String, String> {
    let out_path = Path::new(output_dir);
    std::fs::create_dir_all(out_path)
        .map_err(|e| format!("create extract dir: {e}"))?;

    let file =
        std::fs::File::open(zip_path).map_err(|e| format!("open zip: {e}"))?;
    let mut archive =
        zip::ZipArchive::new(file).map_err(|e| format!("read zip: {e}"))?;

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

fn escape_json(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
        .replace('\r', "\\r")
        .replace('\t', "\\t")
}
