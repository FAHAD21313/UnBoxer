use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};

extern "C" {
    fn idevice_new(device: *mut *mut c_void, udid: *const c_char) -> c_int;
    fn idevice_free(device: *mut c_void) -> c_int;
    fn instproxy_client_start_service(
        device: *mut c_void,
        client: *mut *mut c_void,
        label: *const c_char,
    ) -> c_int;
    fn instproxy_browse(
        client: *mut c_void,
        client_options: *mut c_void,
        result: *mut *mut c_void,
    ) -> c_int;
    fn plist_to_json(
        plist: *mut c_void,
        plist_json: *mut *mut c_char,
        length: *mut u32,
        prettify: c_int,
    ) -> c_int;
    fn plist_new_dict() -> *mut c_void;
    fn plist_new_string(val: *const c_char) -> *mut c_void;
    fn plist_dict_set_item(node: *mut c_void, key: *const c_char, item: *mut c_void);
    fn plist_free(plist: *mut c_void);
    fn plist_mem_free(ptr: *mut c_void);
}

#[no_mangle]
pub unsafe extern "C" fn rust_bridge_idevice_fetch_all_apps() -> *mut c_char {
    let mut device: *mut c_void = std::ptr::null_mut();
    if idevice_new(&mut device, std::ptr::null()) != 0 || device.is_null() {
        return std::ptr::null_mut();
    }

    let label = match CString::new("unboxer") {
        Ok(l) => l,
        Err(_) => {
            idevice_free(device);
            return std::ptr::null_mut();
        }
    };

    let mut client: *mut c_void = std::ptr::null_mut();
    if instproxy_client_start_service(device, &mut client, label.as_ptr()) != 0
        || client.is_null()
    {
        idevice_free(device);
        return std::ptr::null_mut();
    }

    let opts = plist_new_dict();
    let has_opts = !opts.is_null();
    if has_opts {
        let app_type_key = CString::new("ApplicationType").unwrap();
        let app_type_val = CString::new("Any").unwrap();
        plist_dict_set_item(opts, app_type_key.as_ptr(), plist_new_string(app_type_val.as_ptr()));
    }

    let mut result: *mut c_void = std::ptr::null_mut();
    if instproxy_browse(client, if has_opts { opts } else { std::ptr::null_mut() }, &mut result) != 0 || result.is_null() {
        if has_opts { plist_free(opts); }
        idevice_free(device);
        return std::ptr::null_mut();
    }
    if has_opts { plist_free(opts); }

    let mut json: *mut c_char = std::ptr::null_mut();
    let mut length: u32 = 0;
    let ret = plist_to_json(result, &mut json, &mut length, 1);
    let output = if ret == 0 && !json.is_null() {
        let s = CStr::from_ptr(json).to_str().unwrap_or("[]").to_string();
        plist_mem_free(json as *mut c_void);
        match CString::new(s) {
            Ok(c) => c.into_raw(),
            Err(_) => CString::new("[]").unwrap().into_raw(),
        }
    } else {
        CString::new("[]").unwrap().into_raw()
    };

    plist_free(result);
    idevice_free(device);

    output
}

#[no_mangle]
pub unsafe extern "C" fn unboxer_core_free_string(s: *mut c_char) {
    if !s.is_null() {
        let _ = CString::from_raw(s);
    }
}

#[no_mangle]
pub unsafe extern "C" fn rust_bridge_idevice_house_arrest_pull(
    _bundle_id: *const c_char,
    _container_path: *const c_char,
    _target_path: *const c_char,
) -> *mut c_char {
    let mock_json = r#"{"status":"success","message":"Mock extracted successfully"}"#;
    let c_str = CString::new(mock_json).unwrap();
    c_str.into_raw()
}
