//! Cổng C cho sea-g2p, để gọi được từ Dart trên Android/iOS.
//!
//! Bản gốc chỉ có binding PyO3, mà điện thoại thì không có Python. Phần này bọc
//! đúng chuỗi việc mà `SEAPipeline.run` làm bên Python — chuẩn hoá văn bản rồi
//! chuyển sang âm vị — sau một mặt tiếp xúc C tối giản.
//!
//! Quy ước bộ nhớ: mọi chuỗi trả về đều do Rust cấp phát, bên gọi phải trả lại
//! bằng `sea_g2p_string_free`. Chuỗi vào là UTF-8 kết thúc bằng NUL.

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::ptr;

use crate::g2p::G2PEngine;
use crate::vi_normalizer::Normalizer;

/// Giữ cả bộ chuẩn hoá lẫn bộ chuyển âm vị: bên gọi chỉ cần một con trỏ.
pub struct SeaG2p {
    normalizer: Normalizer,
    engine: G2PEngine,
}

impl SeaG2p {
    /// Dùng trực tiếp từ Rust, không qua cổng C. Crate suy luận VieNeu gọi lối
    /// này để khỏi phải chuyển chuỗi qua lại hai lần.
    pub fn open(dict_path: &str, lang: &str) -> Result<Self, String> {
        let engine = G2PEngine::new(dict_path)
            .map_err(|e| format!("không mở được từ điển âm vị {dict_path}: {e}"))?;
        Ok(SeaG2p { normalizer: Normalizer::new(lang), engine })
    }

    pub fn phonemize(&self, text: &str, punc_norm: bool) -> Result<String, String> {
        let normalized = self.normalizer.normalize(text, punc_norm);
        Ok(self.engine.phonemize(&normalized))
    }
}

fn to_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}

fn to_c_string(value: String) -> *mut c_char {
    match CString::new(value) {
        Ok(s) => s.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

/// Mở bộ từ điển nhị phân (`sea_g2p.bin`) và dựng engine.
///
/// Trả về null nếu không mở được file — bên gọi phải kiểm tra.
#[unsafe(no_mangle)]
pub extern "C" fn sea_g2p_new(dict_path: *const c_char, lang: *const c_char) -> *mut SeaG2p {
    let Some(path) = to_str(dict_path) else {
        return ptr::null_mut();
    };
    let lang = to_str(lang).unwrap_or("vi");

    match G2PEngine::new(path) {
        Ok(engine) => Box::into_raw(Box::new(SeaG2p {
            normalizer: Normalizer::new(lang),
            engine,
        })),
        Err(_) => ptr::null_mut(),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn sea_g2p_free(handle: *mut SeaG2p) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

/// Chuẩn hoá rồi chuyển sang âm vị — đúng những gì `SEAPipeline.run` làm.
///
/// [punc_norm] khác 0 thì chốt dấu câu cuối trong bước chuẩn hoá.
#[unsafe(no_mangle)]
pub extern "C" fn sea_g2p_phonemize(
    handle: *mut SeaG2p,
    text: *const c_char,
    punc_norm: c_int,
) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    let Some(text) = to_str(text) else {
        return ptr::null_mut();
    };
    let this = unsafe { &*handle };

    let normalized = this.normalizer.normalize(text, punc_norm != 0);
    to_c_string(this.engine.phonemize(&normalized))
}

/// Chỉ chuẩn hoá văn bản, không chuyển âm vị.
#[unsafe(no_mangle)]
pub extern "C" fn sea_g2p_normalize(
    handle: *mut SeaG2p,
    text: *const c_char,
    punc_norm: c_int,
) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    let Some(text) = to_str(text) else {
        return ptr::null_mut();
    };
    let this = unsafe { &*handle };
    to_c_string(this.normalizer.normalize(text, punc_norm != 0))
}

/// Chốt dấu câu cuối, không cần engine.
#[unsafe(no_mangle)]
pub extern "C" fn sea_g2p_punc_norm(text: *const c_char) -> *mut c_char {
    let Some(text) = to_str(text) else {
        return ptr::null_mut();
    };
    to_c_string(crate::punc::apply_punc_norm(text))
}

/// Trả lại chuỗi do các hàm trên cấp phát.
#[unsafe(no_mangle)]
pub extern "C" fn sea_g2p_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}

/// Phiên bản của lớp bọc, để bên Dart biết mình đang nói chuyện với bản nào.
#[unsafe(no_mangle)]
pub extern "C" fn sea_g2p_abi_version() -> c_int {
    1
}
