use std::ffi::{CStr, CString};
use std::os::raw::c_char;

/// MOCK implementation of fetch_all_apps
/// This will be called by Swift via `@_silgen_name("rust_bridge_idevice_fetch_all_apps")`
#[no_mangle]
pub unsafe extern "C" fn rust_bridge_idevice_fetch_all_apps() -> *mut c_char {
    let mock_json = r#"[{"Name":"MockApp","BundleID":"com.mock","Version":"1.0","Path":"/var/containers/Bundle/Application/MockApp.app"}]"#;
    let c_str = CString::new(mock_json).unwrap();
    c_str.into_raw() // Hand over pointer to Swift
}

/// A dedicated deallocation function that MUST be called by Swift via `defer`
/// to safely free the memory allocated by `CString::into_raw()`.
#[no_mangle]
pub unsafe extern "C" fn unboxer_core_free_string(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    // Take ownership back and drop it immediately
    let _ = CString::from_raw(s);
}

#[no_mangle]
pub unsafe extern "C" fn rust_bridge_idevice_house_arrest_pull(
    bundle_id: *const c_char,
    container_path: *const c_char,
    target_path: *const c_char,
) -> *mut c_char {
    let mock_json = r#"{"status":"success","message":"Mock extracted successfully"}"#;
    let c_str = CString::new(mock_json).unwrap();
    c_str.into_raw()
}
