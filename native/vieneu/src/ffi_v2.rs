//! Cổng C cho engine VieNeu v2.
//!
//! Tách khỏi `ffi.rs` vì hai engine không dùng chung thứ gì: khác mô hình, khác
//! runtime, khác codec, khác cả cách mô tả một giọng. Nhét chung một `Engine`
//! rồi phân nhánh sẽ thành một mớ `Option` mà nửa số trường luôn rỗng.
//!
//! Hai hàm giải phóng bộ nhớ thì KHÔNG nhân đôi: `vieneu_samples_free` và
//! `vieneu_string_free` bên `ffi.rs` dùng được nguyên vì cùng crate nên cùng bộ
//! cấp phát. Bên Dart cứ gọi đúng hai hàm ấy cho cả hai engine.

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_float, c_int};
use std::path::Path;
use std::ptr;

use crate::v2::{EngineV2, SAMPLE_RATE_V2};

pub struct EngineV2Handle {
    engine: EngineV2,
    g2p: sea_g2p_rs::ffi::SeaG2p,
    names: Vec<String>,
    last_error: Option<CString>,
}

fn to_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}

/// Mở engine v2. Trả null khi hỏng, kèm thông báo qua [error_out] — lúc này chưa
/// có handle nào để hỏi `last_error`, nên phải trả lỗi ra ngoài luôn.
///
/// Chuỗi trả qua [error_out] do bên gọi giải phóng bằng `vieneu_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_v2_open(
    gguf_path: *const c_char,
    codec_path: *const c_char,
    voices_path: *const c_char,
    extra_voices_path: *const c_char,
    user_voices_path: *const c_char,
    dict_path: *const c_char,
    threads: c_int,
    error_out: *mut *mut c_char,
) -> *mut EngineV2Handle {
    let fail = |message: String| -> *mut EngineV2Handle {
        if !error_out.is_null() {
            let text = CString::new(message).unwrap_or_default();
            unsafe { *error_out = text.into_raw() };
        }
        ptr::null_mut()
    };

    let (Some(gguf), Some(codec), Some(voices), Some(extra_voices), Some(user_voices), Some(dict)) = (
        to_str(gguf_path),
        to_str(codec_path),
        to_str(voices_path),
        to_str(extra_voices_path),
        to_str(user_voices_path),
        to_str(dict_path),
    ) else {
        return fail("thiếu đường dẫn".into());
    };

    let g2p = match sea_g2p_rs::ffi::SeaG2p::open(dict, "vi") {
        Ok(g) => g,
        Err(e) => return fail(format!("không mở được từ điển âm vị: {e:?}")),
    };

    let engine = match EngineV2::open(
        Path::new(gguf),
        Path::new(codec),
        Path::new(voices),
        Path::new(extra_voices),
        Path::new(user_voices),
        threads.max(1),
        &g2p,
    ) {
        Ok(e) => e,
        Err(e) => return fail(e),
    };

    let names = engine.voice_names();
    Box::into_raw(Box::new(EngineV2Handle {
        engine,
        g2p,
        names,
        last_error: None,
    }))
}

#[unsafe(no_mangle)]
pub extern "C" fn vieneu_v2_close(handle: *mut EngineV2Handle) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

/// NeuCodec dựng 24 kHz — KHÁC 48 kHz của v3, bên Dart phải hỏi chứ đừng gán cứng.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_v2_sample_rate() -> c_int {
    SAMPLE_RATE_V2 as c_int
}

#[unsafe(no_mangle)]
pub extern "C" fn vieneu_v2_voice_count(handle: *const EngineV2Handle) -> c_int {
    if handle.is_null() {
        return 0;
    }
    unsafe { &*handle }.names.len() as c_int
}

#[unsafe(no_mangle)]
pub extern "C" fn vieneu_v2_voice_name(
    handle: *const EngineV2Handle,
    index: c_int,
) -> *mut c_char {
    if handle.is_null() || index < 0 {
        return ptr::null_mut();
    }
    let h = unsafe { &*handle };
    match h.names.get(index as usize) {
        Some(name) => CString::new(name.as_str())
            .map(|s| s.into_raw())
            .unwrap_or(ptr::null_mut()),
        None => ptr::null_mut(),
    }
}

/// Mô tả giọng ("Thanh Bình (nam miền Bắc)") để hiện dưới tên trong Cài đặt.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_v2_voice_description(
    handle: *const EngineV2Handle,
    index: c_int,
) -> *mut c_char {
    if handle.is_null() || index < 0 {
        return ptr::null_mut();
    }
    let h = unsafe { &*handle };
    let Some(name) = h.names.get(index as usize) else {
        return ptr::null_mut();
    };
    let mo_ta = h.engine.voice(name).map(|v| v.description.as_str()).unwrap_or("");
    CString::new(mo_ta)
        .map(|s| s.into_raw())
        .unwrap_or(ptr::null_mut())
}

/// Đọc một đoạn. Trả mảng mẫu âm float32 24 kHz, số phần tử ghi vào [out_len].
///
/// Giải phóng bằng `vieneu_samples_free` — chung với v3.
///
/// Không có tham số ngữ cảnh như v3: v2 nối giọng bằng mã tham chiếu cố định của
/// giọng chứ không bằng đuôi của đoạn trước, nên cùng một đoạn văn luôn cho ra
/// cùng âm thanh. Khoá bộ nhớ đệm bên Dart nhờ vậy đơn giản hơn.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_v2_synthesize(
    handle: *mut EngineV2Handle,
    text: *const c_char,
    voice: *const c_char,
    seed: u32,
    out_len: *mut c_int,
) -> *mut c_float {
    if handle.is_null() {
        return ptr::null_mut();
    }
    let h = unsafe { &mut *handle };
    h.last_error = None;

    macro_rules! fail {
        ($msg:expr) => {{
            h.last_error = CString::new($msg).ok();
            return ptr::null_mut();
        }};
    }

    let (Some(text), Some(voice_name)) = (to_str(text), to_str(voice)) else {
        fail!("thiếu văn bản hoặc tên giọng");
    };

    let phonemes = match h.g2p.phonemize(text, false) {
        Ok(p) => p,
        Err(e) => fail!(format!("lỗi chuyển âm vị: {e:?}")),
    };
    if phonemes.trim().is_empty() {
        fail!("không tạo được âm vị nào từ văn bản");
    }

    let mut samples = match h.engine.synthesize(&phonemes, voice_name, seed) {
        Ok(s) => s,
        Err(e) => fail!(e),
    };

    samples.shrink_to_fit();
    if !out_len.is_null() {
        unsafe { *out_len = samples.len() as c_int };
    }
    let ptr = samples.as_mut_ptr();
    std::mem::forget(samples);
    ptr
}

/// Giọng thứ [index] có phải do người dùng tự thêm không (1 có, 0 không).
///
/// Giao diện dùng để quyết định có hiện nút xoá — giọng dựng sẵn xoá đi thì lần
/// nạp sau `voices.json` lại đưa nó về, nút xoá chỉ là hứa hão.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_v2_voice_tu_them(handle: *const EngineV2Handle, index: c_int) -> c_int {
    if handle.is_null() || index < 0 {
        return 0;
    }
    let h = unsafe { &*handle };
    let Some(name) = h.names.get(index as usize) else {
        return 0;
    };
    match h.engine.voice(name) {
        Some(v) if v.tu_them => 1,
        _ => 0,
    }
}

/// Nhân bản một giọng từ file ghi âm kèm LỜI của đúng đoạn ấy.
///
/// Trả 0 nếu xong, khác 0 thì hỏi `vieneu_v2_last_error`.
///
/// Khác `vieneu_add_voice` của v3 ở chỗ bắt buộc có [text]: v2 không dùng vector
/// đặc trưng người nói mà nhận thẳng cặp mã tham chiếu + lời tương ứng.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_v2_add_voice(
    handle: *mut EngineV2Handle,
    name: *const c_char,
    wav_path: *const c_char,
    text: *const c_char,
    encoder_path: *const c_char,
    user_voices_path: *const c_char,
) -> c_int {
    if handle.is_null() {
        return 1;
    }
    let h = unsafe { &mut *handle };
    h.last_error = None;

    let (Some(name), Some(wav), Some(text), Some(encoder), Some(user_voices)) = (
        to_str(name),
        to_str(wav_path),
        to_str(text),
        to_str(encoder_path),
        to_str(user_voices_path),
    ) else {
        h.last_error = CString::new("thiếu tham số").ok();
        return 1;
    };

    match h.engine.add_voice(
        name,
        Path::new(wav),
        text,
        Path::new(encoder),
        Path::new(user_voices),
        &h.g2p,
    ) {
        Ok(()) => {
            h.names = h.engine.voice_names();
            0
        }
        Err(e) => {
            h.last_error = CString::new(e).ok();
            1
        }
    }
}

/// Xoá một giọng tự thêm. Trả 0 nếu xong.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_v2_remove_voice(
    handle: *mut EngineV2Handle,
    name: *const c_char,
    user_voices_path: *const c_char,
) -> c_int {
    if handle.is_null() {
        return 1;
    }
    let h = unsafe { &mut *handle };
    h.last_error = None;

    let (Some(name), Some(user_voices)) = (to_str(name), to_str(user_voices_path)) else {
        h.last_error = CString::new("thiếu tham số").ok();
        return 1;
    };

    match h.engine.remove_voice(name, Path::new(user_voices)) {
        Ok(()) => {
            h.names = h.engine.voice_names();
            0
        }
        Err(e) => {
            h.last_error = CString::new(e).ok();
            1
        }
    }
}

/// Thông báo lỗi của lần gọi gần nhất, null nếu không có.
///
/// Giải phóng bằng `vieneu_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_v2_last_error(handle: *const EngineV2Handle) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    match unsafe { &*handle }.last_error.as_ref() {
        Some(text) => text.clone().into_raw(),
        None => ptr::null_mut(),
    }
}
