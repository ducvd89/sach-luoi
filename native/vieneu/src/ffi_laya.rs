//! Cổng C cho Laya (chọn người nói, đoán giới tính). Tách khỏi `ffi.rs` cùng lý do với v2 và
//! Matcha: không dùng chung gì với engine đọc ngoài hai hàm giải phóng bộ nhớ — bên Dart cứ
//! gọi `vieneu_string_free` cho chuỗi trả về, vì cùng crate nên cùng bộ cấp phát.
//!
//! Tiền tố `laya_` — nếu sau này dựng cho iOS thì nhớ thêm vào exported_symbols.txt (xem CLAUDE.md:
//! danh sách lọc theo TIỀN TỐ).

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::path::Path;
use std::ptr;

use crate::laya::{Laya, LuaChon, TrangThai};

pub struct LayaHandle {
    laya: Laya,
    last_error: Option<CString>,
}

fn to_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}

fn chuoi_ra(s: String) -> *mut c_char {
    CString::new(s).map(CString::into_raw).unwrap_or(ptr::null_mut())
}

/// Mở Laya từ thư mục có `laya.onnx`, `tokenizer.json`, `rl_agent_config.json`. Trả null khi hỏng
/// kèm thông báo qua [error_out] (giải phóng bằng `vieneu_string_free`).
#[unsafe(no_mangle)]
pub extern "C" fn laya_open(
    thu_muc: *const c_char,
    threads: c_int,
    error_out: *mut *mut c_char,
) -> *mut LayaHandle {
    let fail = |m: String| -> *mut LayaHandle {
        if !error_out.is_null() {
            unsafe { *error_out = chuoi_ra(m) };
        }
        ptr::null_mut()
    };
    let Some(thu_muc) = to_str(thu_muc) else {
        return fail("thiếu đường dẫn".into());
    };
    match Laya::mo(Path::new(thu_muc), threads.max(1) as usize) {
        Ok(laya) => Box::into_raw(Box::new(LayaHandle { laya, last_error: None })),
        Err(e) => fail(e),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn laya_close(handle: *mut LayaHandle) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

/// Hỏi một câu. [thoai] null = câu hỏi không có "quote" (đoán giới tính). [lua_chon_json] là
/// mảng `[{"nhan": "...", "mo_ta": "..."}, ...]`. Trả JSON `{"xac_suat":[...],"chon":i}`
/// (giải phóng bằng `vieneu_string_free`), hoặc null — lúc đó hỏi `laya_last_error`.
///
/// Mọi lượt gọi vào một handle phải đi qua MỘT luồng tại một thời điểm: `chon` lấy `&mut`
/// trên phiên ONNX mà không khoá.
#[unsafe(no_mangle)]
pub extern "C" fn laya_predict(
    handle: *mut LayaHandle,
    doan: *const c_char,
    thoai: *const c_char,
    huong_dan: *const c_char,
    lua_chon_json: *const c_char,
) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    let h = unsafe { &mut *handle };
    h.last_error = None;
    let mut loi = |m: String| -> *mut c_char {
        h.last_error = CString::new(m).ok();
        ptr::null_mut()
    };
    let (Some(doan), Some(huong_dan), Some(lc)) = (to_str(doan), to_str(huong_dan), to_str(lua_chon_json))
    else {
        return loi("thiếu đoạn văn, hướng dẫn hoặc lựa chọn".into());
    };
    let lua: Vec<LuaChon> = match serde_json::from_str::<Vec<serde_json::Value>>(lc) {
        Ok(v) => v
            .iter()
            .map(|x| LuaChon {
                nhan: x["nhan"].as_str().unwrap_or("").to_string(),
                mo_ta: x["mo_ta"].as_str().unwrap_or("").to_string(),
            })
            .collect(),
        Err(e) => return loi(format!("lựa chọn không phải JSON: {e}")),
    };
    let tt = TrangThai { doan, thoai: to_str(thoai) };
    match h.laya.chon(huong_dan, &tt, &lua) {
        Ok(p) => {
            let chon = p
                .iter()
                .enumerate()
                .max_by(|a, b| a.1.total_cmp(b.1))
                .map(|(i, _)| i)
                .unwrap_or(0);
            chuoi_ra(serde_json::json!({ "xac_suat": p, "chon": chon }).to_string())
        }
        Err(e) => loi(e),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn laya_last_error(handle: *const LayaHandle) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    match unsafe { &*handle }.last_error.as_ref() {
        Some(e) => chuoi_ra(e.to_string_lossy().into_owned()),
        None => ptr::null_mut(),
    }
}
