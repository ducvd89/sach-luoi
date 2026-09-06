//! Cổng C cho engine Matcha-TTS.
//!
//! Tách khỏi `ffi.rs` và `ffi_v2.rs` cùng một lý do như v2: ba engine không
//! dùng chung gì ngoài hai hàm giải phóng bộ nhớ. Bên Dart cứ gọi
//! `vieneu_samples_free` và `vieneu_string_free` cho cả ba — cùng crate nên
//! cùng bộ cấp phát.
//!
//! Không có hàm nào về giọng: Matcha là mô hình **một người nói**, không có hồ
//! sơ giọng để liệt kê và không nhân bản giọng được. Danh sách giọng dựng thẳng
//! bên `matcha_engine.dart`.

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_float, c_int};
use std::path::Path;
use std::ptr;

use crate::matcha::{EngineMatcha, SAMPLE_RATE_MATCHA};

pub struct MatchaHandle {
    engine: EngineMatcha,
    last_error: Option<CString>,
}

fn to_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}

/// Mở engine. Trả null khi hỏng, kèm thông báo qua [error_out] — lúc này chưa
/// có handle nào để hỏi `matcha_last_error`.
///
/// Chuỗi trả qua [error_out] do bên gọi giải phóng bằng `vieneu_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn matcha_open(
    encoder_path: *const c_char,
    decoder_path: *const c_char,
    vocoder_path: *const c_char,
    symbols_path: *const c_char,
    threads: c_int,
    error_out: *mut *mut c_char,
) -> *mut MatchaHandle {
    let fail = |message: String| -> *mut MatchaHandle {
        if !error_out.is_null() {
            let text = CString::new(message).unwrap_or_default();
            unsafe { *error_out = text.into_raw() };
        }
        ptr::null_mut()
    };

    let (Some(enc), Some(dec), Some(voc), Some(sym)) = (
        to_str(encoder_path),
        to_str(decoder_path),
        to_str(vocoder_path),
        to_str(symbols_path),
    ) else {
        return fail("thiếu đường dẫn".into());
    };

    match EngineMatcha::open(
        Path::new(enc),
        Path::new(dec),
        Path::new(voc),
        Path::new(sym),
        threads.max(1) as usize,
    ) {
        Ok(engine) => Box::into_raw(Box::new(MatchaHandle { engine, last_error: None })),
        Err(e) => fail(e),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn matcha_close(handle: *mut MatchaHandle) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

/// Vocos dựng 22 050 Hz — khác 48 kHz của v3 và 24 kHz của v2, bên Dart phải
/// hỏi chứ đừng gán cứng.
#[unsafe(no_mangle)]
pub extern "C" fn matcha_sample_rate() -> c_int {
    SAMPLE_RATE_MATCHA as c_int
}

/// Đọc một đoạn. Trả mảng mẫu âm float32, số phần tử ghi vào [out_len].
///
/// Giải phóng bằng `vieneu_samples_free` — chung với hai engine kia.
///
/// [toc_do] đi vào bộ đoán độ dài chứ không lấy mẫu lại, nên cao độ giữ nguyên.
#[unsafe(no_mangle)]
pub extern "C" fn matcha_synthesize(
    handle: *mut MatchaHandle,
    text: *const c_char,
    toc_do: c_float,
    seed: u32,
    // Mã yêu cầu, để `matcha_huy` cắt được. 0 nghĩa là không huỷ được.
    ma: u64,
    out_len: *mut c_int,
) -> *mut c_float {
    if handle.is_null() {
        return ptr::null_mut();
    }
    let h = unsafe { &mut *handle };
    h.last_error = None;

    let Some(text) = to_str(text) else {
        h.last_error = CString::new("thiếu văn bản").ok();
        return ptr::null_mut();
    };

    let mut samples = match h.engine.doc(text, toc_do, seed, ma) {
        Ok(s) => s,
        Err(e) => {
            h.last_error = CString::new(e).ok();
            return ptr::null_mut();
        }
    };

    samples.shrink_to_fit();
    if !out_len.is_null() {
        unsafe { *out_len = samples.len() as c_int };
    }
    let ptr = samples.as_mut_ptr();
    std::mem::forget(samples);
    ptr
}

/// Bỏ mọi yêu cầu đọc có mã ≤ [den_ma] (người dùng tua).
///
/// **Không nhận handle, có chủ ý** — cùng lý do như `vieneu_v2_huy`: cờ nằm ở
/// phạm vi tiến trình nên gọi được từ isolate giao diện ngay cả khi isolate giữ
/// engine đang kẹt giữa một lượt đọc.
#[unsafe(no_mangle)]
pub extern "C" fn matcha_huy(den_ma: u64) {
    crate::matcha::huy_toi(den_ma);
}

/// Thông báo lỗi của lần gọi gần nhất, null nếu không có.
///
/// Giải phóng bằng `vieneu_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn matcha_last_error(handle: *const MatchaHandle) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    match unsafe { &*handle }.last_error.as_ref() {
        Some(text) => text.clone().into_raw(),
        None => ptr::null_mut(),
    }
}
