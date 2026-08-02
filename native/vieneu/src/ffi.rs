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
    /// Mã đuôi của đoạn vừa đọc, để bên gọi truyền sang làm ngữ cảnh cho đoạn
    /// kế. Giữ trong engine thay vì trả kèm mảng mẫu âm cho khỏi phải cấp phát
    /// và giải phóng hai lần mỗi đoạn.
    duoi: Vec<i32>,
}

/// Bao nhiêu khung cuối giữ lại làm ngữ cảnh (12,5 khung = 1 giây).
///
/// 100 khung tức 8 giây, bằng đúng độ dài mã tham chiếu của một mẫu giọng —
/// ngữ cảnh thay chỗ nó nên giữ cùng cỡ thì mô hình nhận được lượng thông tin
/// quen thuộc.
const KHUNG_DUOI: usize = 100;

/// Bao nhiêu khung lặng nối vào cuối đuôi (12,5 khung = 1 giây).
///
/// Không có nó thì mã tham chiếu dừng ngay giữa lúc đang có tiếng, mô hình hiểu
/// là đang NÓI TIẾP chứ không phải BẮT ĐẦU NÓI — mà người nói tiếp thì vào câu
/// nhẹ hơn, nên chữ đầu đoạn sau ra lí nhí. Thêm một quãng lặng vào là mô hình
/// thấy câu trước đã dứt hẳn.
///
/// Lấy lặng từ chỗ im nhất của chính đoạn vừa đọc, không dựng lặng nhân tạo:
/// nó mang đúng nền phòng và đúng giọng, mà cũng khỏi cần bộ mã hoá âm (bộ ấy
/// tải riêng, đường chạy bình thường không có).
const KHUNG_LANG: usize = 5;

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

    Box::into_raw(Box::new(Engine { model, g2p, voices, last_error: None, duoi: Vec::new() }))
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
///
/// [ngu_canh_ptr] là mã đuôi của đoạn đọc ngay trước (lấy bằng [vieneu_duoi]),
/// null nếu đoạn này đứng một mình. Có ngữ cảnh thì giọng không nhảy ở chỗ
/// chuyển đoạn — nhưng cũng có nghĩa cùng một đoạn văn cho ra âm thanh khác
/// nhau tuỳ đoạn đứng trước, nên khoá bộ nhớ đệm phải tính cả nó vào.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_synthesize(
    handle: *mut Engine,
    text: *const c_char,
    voice: *const c_char,
    seed: u64,
    ngu_canh_ptr: *const c_int,
    ngu_canh_len: c_int,
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

    let ngu_canh: Vec<i64> = if ngu_canh_ptr.is_null() || ngu_canh_len <= 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(ngu_canh_ptr, ngu_canh_len as usize) }
            .iter()
            .map(|v| *v as i64)
            .collect()
    };

    let voice = &engine.voices[voice_name];
    let result = match synthesize(&mut engine.model, &phonemes, voice, &Sampling::default(), seed, &ngu_canh) {
        Ok(r) => r,
        Err(e) => return fail(e),
    };

    // Cất đuôi lại cho đoạn kế; bên gọi lấy qua vieneu_duoi.
    let n_vq = engine.model.cfg.n_vq;
    let lay = KHUNG_DUOI.min(result.frames);
    let mut duoi: Vec<i32> = result.codes[(result.frames - lay) * n_vq..].to_vec();

    // Nối thêm quãng lặng — xem KHUNG_LANG.
    let mau_moi_khung = if result.frames > 0 { result.samples.len() / result.frames } else { 0 };
    if result.frames > KHUNG_LANG && mau_moi_khung > 0 {
        let nang_luong: Vec<f32> = (0..result.frames)
            .map(|f| {
                let a = f * mau_moi_khung;
                let b = ((f + 1) * mau_moi_khung).min(result.samples.len());
                result.samples[a..b].iter().map(|v| v * v).sum::<f32>()
            })
            .collect();

        // Cửa sổ KHUNG_LANG khung liền nhau có tổng năng lượng nhỏ nhất, trượt
        // bằng tổng cộng dồn.
        let mut tong: f32 = nang_luong[..KHUNG_LANG].iter().sum();
        let mut it_nhat = tong;
        let mut dau = 0usize;
        for i in 1..=(result.frames - KHUNG_LANG) {
            tong += nang_luong[i + KHUNG_LANG - 1] - nang_luong[i - 1];
            if tong < it_nhat {
                it_nhat = tong;
                dau = i;
            }
        }
        duoi.extend_from_slice(&result.codes[dau * n_vq..(dau + KHUNG_LANG) * n_vq]);
    }
    engine.duoi = duoi;

    let mut samples = result.samples;
    samples.shrink_to_fit();
    if !out_len.is_null() {
        unsafe { *out_len = samples.len() as c_int };
    }
    let ptr = samples.as_mut_ptr();
    std::mem::forget(samples);
    ptr
}

/// Mã đuôi của đoạn vừa đọc, để truyền làm ngữ cảnh cho đoạn kế.
///
/// Con trỏ trỏ vào bộ đệm trong engine — chỉ dùng được tới lần gọi
/// [vieneu_synthesize] tiếp theo, và KHÔNG được giải phóng.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_duoi(handle: *const Engine, out_len: *mut c_int) -> *const c_int {
    if handle.is_null() {
        return ptr::null();
    }
    let engine = unsafe { &*handle };
    if !out_len.is_null() {
        unsafe { *out_len = engine.duoi.len() as c_int };
    }
    engine.duoi.as_ptr()
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

// -- nén file khi xuất --------------------------------------------------------

/// Đặt chuỗi lỗi vào tham số ra. Bên gọi giải phóng bằng `vieneu_string_free`.
#[cfg(not(target_os = "android"))]
fn dat_loi(loi_ra: *mut *mut c_char, message: String) -> c_int {
    if !loi_ra.is_null() {
        if let Ok(s) = CString::new(message) {
            unsafe { *loi_ra = s.into_raw() };
        }
    }
    1
}

/// Nén một file WAV sang Opus, MP3 hoặc AAC. Trả 0 khi xong, 1 khi lỗi.
///
/// [dinh_dang]: 0 = Opus, 1 = MP3, 2 = AAC.
/// [bitrate]: với Opus và AAC tính theo bit/s (32000, 96000), với MP3 theo kbps (128).
///
/// Vào ra bằng đường dẫn file chứ không qua buffer: một file 30 phút là hàng
/// trăm MB, đẩy qua FFI rồi lại copy sang bộ nhớ Dart thì tốn vô ích.
///
/// Ghi vào file tạm rồi đổi tên, nên nếu máy tắt giữa lúc nén thì không để lại
/// một file .opus dở dang mà phần xuất file tưởng là đã xong.
#[cfg(not(target_os = "android"))]
#[unsafe(no_mangle)]
pub extern "C" fn sachnoi_ma_hoa_file(
    wav_path: *const c_char,
    out_path: *const c_char,
    dinh_dang: c_int,
    bitrate: c_int,
    loi_ra: *mut *mut c_char,
) -> c_int {
    if !loi_ra.is_null() {
        unsafe { *loi_ra = ptr::null_mut() };
    }
    let (Some(vao), Some(ra)) = (to_str(wav_path), to_str(out_path)) else {
        return dat_loi(loi_ra, "đường dẫn không đọc được".into());
    };
    if bitrate <= 0 {
        return dat_loi(loi_ra, format!("bitrate không hợp lệ: {bitrate}"));
    }

    let byte = match std::fs::read(vao) {
        Ok(v) => v,
        Err(e) => return dat_loi(loi_ra, format!("không đọc được {vao}: {e}")),
    };
    let (pcm, sr) = match crate::ma_hoa::doc_wav_mono(&byte) {
        Ok(v) => v,
        Err(e) => return dat_loi(loi_ra, e),
    };

    let nen = match dinh_dang {
        0 => crate::ma_hoa::wav_sang_opus(&pcm, sr, bitrate),
        1 => crate::ma_hoa::wav_sang_mp3(&pcm, sr, bitrate as u32),
        2 => crate::ma_hoa::wav_sang_aac(&pcm, sr, bitrate as u32),
        _ => Err(format!("định dạng lạ: {dinh_dang}")),
    };
    let nen = match nen {
        Ok(v) => v,
        Err(e) => return dat_loi(loi_ra, e),
    };

    let tam = format!("{ra}.tmp");
    if let Err(e) = std::fs::write(&tam, &nen) {
        return dat_loi(loi_ra, format!("không ghi được {tam}: {e}"));
    }
    // Windows không cho rename đè lên file đang tồn tại.
    let _ = std::fs::remove_file(ra);
    if let Err(e) = std::fs::rename(&tam, ra) {
        let _ = std::fs::remove_file(&tam);
        return dat_loi(loi_ra, format!("không đổi tên sang {ra}: {e}"));
    }
    0
}

#[cfg(all(test, not(target_os = "android")))]
mod kiem_thu_ma_hoa {
    use super::*;

    fn wav_mot_giay() -> Vec<u8> {
        let mau: Vec<i16> = (0..48_000)
            .map(|i| {
                let t = i as f32 / 48_000.0;
                ((t * 330.0 * std::f32::consts::TAU).sin() * 9000.0) as i16
            })
            .collect();
        let than: Vec<u8> = mau.iter().flat_map(|s| s.to_le_bytes()).collect();
        let mut w = Vec::new();
        w.extend_from_slice(b"RIFF");
        w.extend_from_slice(&(36 + than.len() as u32).to_le_bytes());
        w.extend_from_slice(b"WAVEfmt ");
        w.extend_from_slice(&16u32.to_le_bytes());
        w.extend_from_slice(&1u16.to_le_bytes());
        w.extend_from_slice(&1u16.to_le_bytes());
        w.extend_from_slice(&48_000u32.to_le_bytes());
        w.extend_from_slice(&96_000u32.to_le_bytes());
        w.extend_from_slice(&2u16.to_le_bytes());
        w.extend_from_slice(&16u16.to_le_bytes());
        w.extend_from_slice(b"data");
        w.extend_from_slice(&(than.len() as u32).to_le_bytes());
        w.extend_from_slice(&than);
        w
    }

    /// Gọi đúng qua cổng C như Dart sẽ gọi, kể cả phần chuỗi lỗi.
    fn goi(vao: &str, ra: &str, dinh_dang: c_int, bitrate: c_int) -> Result<(), String> {
        let a = CString::new(vao).unwrap();
        let b = CString::new(ra).unwrap();
        let mut loi: *mut c_char = ptr::null_mut();
        let ma = sachnoi_ma_hoa_file(a.as_ptr(), b.as_ptr(), dinh_dang, bitrate, &mut loi);
        if ma == 0 {
            assert!(loi.is_null(), "thành công thì không được đặt chuỗi lỗi");
            return Ok(());
        }
        assert!(!loi.is_null(), "lỗi thì phải nói lý do");
        let text = unsafe { CStr::from_ptr(loi) }.to_string_lossy().into_owned();
        vieneu_string_free(loi);
        Err(text)
    }

    #[test]
    fn nen_qua_cong_c_ra_ca_ba_dinh_dang() {
        let d = std::env::temp_dir().join("sachluoi_ffi_ma_hoa");
        std::fs::create_dir_all(&d).unwrap();
        let vao = d.join("vao.wav");
        std::fs::write(&vao, wav_mot_giay()).unwrap();

        for (dd, br, ten, dau) in [
            (0, 32_000, "ra.opus", &b"OggS"[..]),
            (1, 128, "ra.mp3", &b"\xff"[..]),
            (2, 96_000, "ra.aac", &b"\xff"[..]),
        ] {
            let ra = d.join(ten);
            goi(vao.to_str().unwrap(), ra.to_str().unwrap(), dd, br).unwrap();
            let byte = std::fs::read(&ra).unwrap();
            assert!(byte.starts_with(dau), "{ten} sai chữ ký đầu file");
            assert!(byte.len() > 1000, "{ten} chỉ có {} byte", byte.len());
            // Không được để lại file tạm.
            assert!(!d.join(format!("{ten}.tmp")).exists(), "còn sót file tạm");
        }
        std::fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn nen_de_len_file_cu_duoc() {
        let d = std::env::temp_dir().join("sachluoi_ffi_de_len");
        std::fs::create_dir_all(&d).unwrap();
        let vao = d.join("vao.wav");
        std::fs::write(&vao, wav_mot_giay()).unwrap();
        let ra = d.join("ra.opus");
        std::fs::write(&ra, b"rac cu").unwrap();

        goi(vao.to_str().unwrap(), ra.to_str().unwrap(), 0, 32_000).unwrap();
        assert!(std::fs::read(&ra).unwrap().starts_with(b"OggS"));
        std::fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn loi_thi_noi_ly_do_chu_khong_sap() {
        let d = std::env::temp_dir().join("sachluoi_ffi_loi");
        std::fs::create_dir_all(&d).unwrap();
        let vao = d.join("vao.wav");
        std::fs::write(&vao, wav_mot_giay()).unwrap();
        let ra = d.join("ra.bin");
        let v = vao.to_str().unwrap();
        let r = ra.to_str().unwrap();

        assert!(goi("khong-co-file-nay.wav", r, 0, 32_000).is_err());
        assert!(goi(v, r, 7, 32_000).unwrap_err().contains("định dạng lạ"));
        assert!(goi(v, r, 0, 0).unwrap_err().contains("bitrate"));
        // WAV hỏng.
        let xau = d.join("xau.wav");
        std::fs::write(&xau, b"khong phai wav").unwrap();
        assert!(goi(xau.to_str().unwrap(), r, 1, 128).is_err());
        std::fs::remove_dir_all(&d).ok();
    }
}
