//! Cổng C: Dart mở mô hình một lần rồi gọi đọc từng đoạn.
//!
//! Mọi thứ nặng nằm sau con trỏ này — mô hình, bộ chuyển âm vị, danh sách giọng
//! — nên bên Dart không phải biết gì về ONNX hay âm vị.

use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_float, c_int};
use std::path::Path;
use std::ptr;

use crate::engine::synthesize;
use crate::model::{Model, Sampling, Voice, SAMPLE_RATE};

pub struct Engine {
    model: Model,
    g2p: sea_g2p_rs::ffi::SeaG2p,
    voices: HashMap<String, Voice>,
    last_error: Option<CString>,
}

fn to_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}

/// Đọc hồ sơ giọng đã tính sẵn (giong.json do nap_giong.py sinh ra).
fn load_voices(path: &Path) -> Result<HashMap<String, Voice>, String> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("không đọc được {}: {e}", path.display()))?;
    let json: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("giong.json hỏng: {e}"))?;

    let presets = json
        .get("presets")
        .and_then(|v| v.as_object())
        .ok_or("giong.json thiếu mục presets")?;

    let mut out = HashMap::new();
    for (name, value) in presets {
        let speaker_emb: Vec<f32> = value
            .get("speaker_emb")
            .and_then(|v| v.as_array())
            .map(|a| a.iter().filter_map(|x| x.as_f64()).map(|x| x as f32).collect())
            .unwrap_or_default();

        // codes là ma trận [số khung x 16], làm phẳng nhưng giữ số khung.
        let mut ref_codes = Vec::new();
        let mut ref_frames = 0usize;
        if let Some(rows) = value.get("codes").and_then(|v| v.as_array()) {
            ref_frames = rows.len();
            for row in rows {
                if let Some(cols) = row.as_array() {
                    ref_codes.extend(cols.iter().filter_map(|x| x.as_i64()));
                }
            }
        }

        out.insert(
            name.clone(),
            Voice {
                speaker_emb,
                ref_codes,
                ref_frames,
                style: value
                    .get("style")
                    .and_then(|v| v.as_str())
                    .unwrap_or("tu_nhien")
                    .to_string(),
            },
        );
    }
    Ok(out)
}

/// Mở mô hình. Trả về null nếu hỏng — gọi [vieneu_last_error] để biết vì sao.
///
/// Con trỏ lỗi trả về là một chuỗi tĩnh cho lần mở đầu tiên, vì lúc đó chưa có
/// đối tượng nào để cất lỗi vào.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_open(
    model_dir: *const c_char,
    codec_dir: *const c_char,
    dict_path: *const c_char,
    voices_path: *const c_char,
    threads: c_int,
    error_out: *mut *mut c_char,
) -> *mut Engine {
    let mut fail = |message: String| -> *mut Engine {
        if !error_out.is_null() {
            if let Ok(s) = CString::new(message) {
                unsafe { *error_out = s.into_raw() };
            }
        }
        ptr::null_mut()
    };

    let (Some(model_dir), Some(codec_dir), Some(dict_path), Some(voices_path)) = (
        to_str(model_dir),
        to_str(codec_dir),
        to_str(dict_path),
        to_str(voices_path),
    ) else {
        return fail("thiếu đường dẫn".into());
    };

    let model = match Model::load(Path::new(model_dir), Path::new(codec_dir), threads.max(0) as usize) {
        Ok(m) => m,
        Err(e) => return fail(e),
    };
    let voices = match load_voices(Path::new(voices_path)) {
        Ok(v) => v,
        Err(e) => return fail(e),
    };
    let g2p = match sea_g2p_rs::ffi::SeaG2p::open(dict_path, "vi") {
        Ok(g) => g,
        Err(e) => return fail(e),
    };

    Box::into_raw(Box::new(Engine { model, g2p, voices, last_error: None }))
}

#[unsafe(no_mangle)]
pub extern "C" fn vieneu_close(handle: *mut Engine) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

/// Tần số lấy mẫu của âm thanh trả về.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_sample_rate() -> c_int {
    SAMPLE_RATE as c_int
}

/// Số giọng đang có.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_voice_count(handle: *const Engine) -> c_int {
    if handle.is_null() {
        return 0;
    }
    unsafe { &*handle }.voices.len() as c_int
}

/// Tên giọng thứ [index], hoặc null nếu vượt quá.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_voice_name(handle: *const Engine, index: c_int) -> *mut c_char {
    if handle.is_null() || index < 0 {
        return ptr::null_mut();
    }
    let engine = unsafe { &*handle };
    let mut names: Vec<&String> = engine.voices.keys().collect();
    names.sort();
    match names.get(index as usize) {
        Some(name) => CString::new(name.as_str()).map(|s| s.into_raw()).unwrap_or(ptr::null_mut()),
        None => ptr::null_mut(),
    }
}

/// Đọc một đoạn văn bản. Trả về con trỏ tới mảng mẫu âm float32, số phần tử ghi
/// vào [out_len]. Null nghĩa là lỗi.
///
/// [seed] cố định để cùng một đoạn luôn cho cùng kết quả — bộ nhớ đệm của ứng
/// dụng dựa vào điều đó.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_synthesize(
    handle: *mut Engine,
    text: *const c_char,
    voice: *const c_char,
    seed: u64,
    out_len: *mut c_int,
) -> *mut c_float {
    if handle.is_null() {
        return ptr::null_mut();
    }
    let engine = unsafe { &mut *handle };
    engine.last_error = None;

    let mut fail = |message: String| -> *mut c_float {
        engine.last_error = CString::new(message).ok();
        ptr::null_mut()
    };

    let (Some(text), Some(voice_name)) = (to_str(text), to_str(voice)) else {
        return fail("thiếu văn bản hoặc tên giọng".into());
    };
    if !engine.voices.contains_key(voice_name) {
        return fail(format!("không có giọng '{voice_name}'"));
    }

    // Chữ -> âm vị -> sóng âm.
    let phonemes = match engine.g2p.phonemize(text, false) {
        Ok(p) => p,
        Err(e) => return fail(format!("lỗi chuyển âm vị: {e}")),
    };
    if phonemes.trim().is_empty() {
        return fail("không tạo được âm vị nào từ văn bản".into());
    }

    let voice = &engine.voices[voice_name];
    let result = match synthesize(&mut engine.model, &phonemes, voice, &Sampling::default(), seed) {
        Ok(r) => r,
        Err(e) => return fail(e),
    };

    let mut samples = result.samples;
    samples.shrink_to_fit();
    if !out_len.is_null() {
        unsafe { *out_len = samples.len() as c_int };
    }
    let ptr = samples.as_mut_ptr();
    std::mem::forget(samples);
    ptr
}

/// Trả lại mảng mẫu âm do [vieneu_synthesize] cấp phát.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_samples_free(data: *mut c_float, len: c_int) {
    if !data.is_null() && len > 0 {
        drop(unsafe { Vec::from_raw_parts(data, len as usize, len as usize) });
    }
}

/// Thông báo lỗi của lần gọi gần nhất, null nếu không có.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_last_error(handle: *const Engine) -> *mut c_char {
    if handle.is_null() {
        return ptr::null_mut();
    }
    match &unsafe { &*handle }.last_error {
        Some(message) => message.clone().into_raw(),
        None => ptr::null_mut(),
    }
}

/// Phép thử liên kết: gọi được nghĩa là thư viện nạp xong.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_abi_version() -> c_int {
    crate::ABI_VERSION
}

/// Phiên bản ONNX Runtime đang dùng — trên Android đây là chỗ hay hỏng nhất.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_onnx_version() -> *mut c_char {
    match CString::new(ort::info().to_string()) {
        Ok(s) => s.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn vieneu_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}

// -- thêm và xoá giọng --------------------------------------------------------

/// Nhân bản một giọng mới từ file .wav rồi ghi vào hồ sơ.
///
/// [speaker_encoder] và [codec_encoder] là hai file .onnx chỉ cần cho việc này,
/// tải riêng chứ không nằm trong bộ mô hình chính.
///
/// Trả về 0 nếu xong, khác 0 là lỗi — gọi [vieneu_last_error] để biết vì sao.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_add_voice(
    handle: *mut Engine,
    name: *const c_char,
    wav_path: *const c_char,
    speaker_encoder: *const c_char,
    codec_encoder: *const c_char,
    voices_path: *const c_char,
) -> c_int {
    if handle.is_null() {
        return 1;
    }
    let engine = unsafe { &mut *handle };
    engine.last_error = None;

    let mut fail = |message: String| -> c_int {
        engine.last_error = CString::new(message).ok();
        1
    };

    let (Some(name), Some(wav), Some(spk), Some(codec), Some(voices)) = (
        to_str(name),
        to_str(wav_path),
        to_str(speaker_encoder),
        to_str(codec_encoder),
        to_str(voices_path),
    ) else {
        return fail("thiếu tham số".into());
    };
    if name.trim().is_empty() {
        return fail("tên giọng không được để trống".into());
    }

    let enrolled = match crate::enroll::enroll(Path::new(wav), Path::new(spk), Path::new(codec)) {
        Ok(v) => v,
        Err(e) => return fail(e),
    };

    let width = engine.model.cfg.n_vq;
    let voice = Voice {
        speaker_emb: enrolled.speaker_emb.clone(),
        ref_codes: enrolled.codes.clone(),
        ref_frames: enrolled.frames,
        // Giọng tự thêm mặc định lấy phong cách kể chuyện — hợp sách nói nhất.
        style: "doc_truyen".to_string(),
    };
    if voice.ref_codes.len() < voice.ref_frames * width {
        return fail("mã tham chiếu không đủ — mẫu ghi âm quá ngắn".into());
    }

    if let Err(e) = save_voice(Path::new(voices), name, &enrolled, width) {
        return fail(e);
    }
    engine.voices.insert(name.to_string(), voice);
    0
}

/// Xoá một giọng khỏi hồ sơ. Chỉ xoá được giọng do người dùng thêm.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_remove_voice(
    handle: *mut Engine,
    name: *const c_char,
    voices_path: *const c_char,
) -> c_int {
    if handle.is_null() {
        return 1;
    }
    let engine = unsafe { &mut *handle };
    engine.last_error = None;

    let (Some(name), Some(voices)) = (to_str(name), to_str(voices_path)) else {
        engine.last_error = CString::new("thiếu tham số").ok();
        return 1;
    };

    match remove_voice_from_file(Path::new(voices), name) {
        Ok(()) => {
            engine.voices.remove(name);
            0
        }
        Err(e) => {
            engine.last_error = CString::new(e).ok();
            1
        }
    }
}

fn read_profiles(path: &Path) -> serde_json::Value {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_else(|| serde_json::json!({"presets": {}}))
}

fn write_profiles(path: &Path, value: &serde_json::Value) -> Result<(), String> {
    // Ghi qua file tạm rồi đổi tên: mất điện giữa chừng không hỏng danh sách cũ.
    let temp = path.with_extension("json.part");
    std::fs::write(&temp, serde_json::to_string(value).map_err(|e| e.to_string())?)
        .map_err(|e| format!("không ghi được hồ sơ giọng: {e}"))?;
    std::fs::rename(&temp, path).map_err(|e| format!("không lưu được hồ sơ giọng: {e}"))
}

fn save_voice(
    path: &Path,
    name: &str,
    enrolled: &crate::enroll::Enrolled,
    width: usize,
) -> Result<(), String> {
    let mut root = read_profiles(path);
    let rows: Vec<Vec<i64>> = enrolled
        .codes
        .chunks(width)
        .take(enrolled.frames)
        .map(|c| c.to_vec())
        .collect();

    root["presets"][name] = serde_json::json!({
        "description": "Giọng bạn tự thêm",
        "gender": "",
        "style": "doc_truyen",
        // Đánh dấu để giao diện biết giọng nào xoá được.
        "source": "nguoi-dung",
        "speaker_emb": enrolled.speaker_emb,
        "codes": rows,
    });
    write_profiles(path, &root)
}

fn remove_voice_from_file(path: &Path, name: &str) -> Result<(), String> {
    let mut root = read_profiles(path);
    let presets = root
        .get_mut("presets")
        .and_then(|v| v.as_object_mut())
        .ok_or("hồ sơ giọng hỏng")?;

    let entry = presets.get(name).ok_or_else(|| format!("không có giọng '{name}'"))?;
    if entry.get("source").and_then(|v| v.as_str()) != Some("nguoi-dung") {
        return Err("chỉ xoá được giọng bạn tự thêm".into());
    }
    presets.remove(name);
    write_profiles(path, &root)
}
