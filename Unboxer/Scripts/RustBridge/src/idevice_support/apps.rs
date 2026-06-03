use idevice::installation_proxy::InstallationProxyClient;
use idevice::IdeviceError;
use plist::{Dictionary, Value};

use crate::idevice_support::rsd::connect_to_rsd_services;

pub async fn fetch_all_apps_rppairing() -> Result<String, IdeviceError> {
    let mut client = connect_to_rsd_services::<InstallationProxyClient>().await?;

    let mut opts = Dictionary::new();
    opts.insert("ApplicationType".into(), "User".into());

    let attrs: Vec<Value> = vec![
        "CFBundleIdentifier",
        "CFBundleDisplayName",
        "CFBundleName",
        "CFBundleShortVersionString",
        "BundlePath",
    ]
    .into_iter()
    .map(Value::from)
    .collect();
    opts.insert("ReturnAttributes".into(), Value::Array(attrs));

    let apps = client.browse(Some(Value::Dictionary(opts))).await?;

    let json = serde_json::to_string(&apps).unwrap_or_else(|_| "[]".to_string());
    Ok(json)
}
