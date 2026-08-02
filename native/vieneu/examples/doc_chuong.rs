//! Đọc thử nhiều đoạn nối tiếp (một chương), nối ngữ cảnh giữa các đoạn giống
//! hệt đường chạy thật trong `ffi.rs::vieneu_synthesize`, rồi ghép thành một
//! WAV liền mạch.
//!
//! Vào là một file text, các đoạn ngăn cách bằng dòng `---` (đúng định dạng
//! `app/tool/chunk_for_test.dart` xuất ra — dùng chunker/normalizer thật của
//! ứng dụng để tách đoạn và chuẩn hoá số/viết tắt trước khi tới đây).
//!
//! ```
//! set ORT_DYLIB_PATH=...\onnxruntime.dll
//! cargo run --release --example doc_chuong -- <model_dir> <codec_dir> <dict> <voices.json> <ten_giong> <chunks.txt> <ra.wav>
//! ```
//!
//! Cùng biến môi trường `VIENEU_TEMPERATURE`/`VIENEU_TOP_K`/`VIENEU_TOP_P`/
//! `VIENEU_REP_PENALTY` như `thu_doc` để A/B test tham số lấy mẫu.

use std::io::Write;
use std::path::Path;
use std::time::Instant;

use sachnoi_vieneu::engine::synthesize;
use sachnoi_vieneu::model::{Model, Sampling, Voice, SAMPLE_RATE};

/// Xem KHUNG_DUOI/KHUNG_LANG trong native/vieneu/src/ffi.rs — giữ đúng số để
/// ngữ cảnh mô phỏng khớp hệt đường chạy thật.
const KHUNG_DUOI: usize = 100;
const KHUNG_LANG: usize = 5;

fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 8 {
        return Err(
            "cần: <model_dir> <codec_dir> <dict.bin> <giong.json> <tên giọng> <chunks.txt> <ra.wav>"
                .into(),
        );
    }

    println!("Đang nạp mô hình...");
    let started = Instant::now();
    let mut model = Model::load(Path::new(&args[1]), Path::new(&args[2]), 4)?;
    println!("  nạp xong sau {:.1}s", started.elapsed().as_secs_f32());

    let g2p = sea_g2p_rs::ffi::SeaG2p::open(&args[3], "vi")?;
    let voices = load_voices(Path::new(&args[4]))?;
    let voice = voices.get(&args[5]).ok_or(format!("không có giọng '{}'", args[5]))?;

    let chunks_text = std::fs::read_to_string(&args[6]).map_err(|e| e.to_string())?;
    let chunks: Vec<&str> = chunks_text
        .split("\n---\n")
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();
    println!("{} đoạn", chunks.len());

    let sampling = sampling_from_env();
    println!(
        "Lấy mẫu: temperature={} top_k={} top_p={} repetition_penalty={}",
        sampling.temperature, sampling.top_k, sampling.top_p, sampling.repetition_penalty
    );

    // VIENEU_NO_CONTEXT=1: mỗi đoạn đứng một mình (dùng mẫu tham chiếu gốc),
    // không nối đuôi đoạn trước — để so sánh có/không ngữ cảnh trên cùng văn
    // bản, cùng tham số lấy mẫu.
    let khong_ngu_canh = std::env::var("VIENEU_NO_CONTEXT").map(|v| v == "1").unwrap_or(false);

    let n_vq = model.cfg.n_vq;
    let mut ngu_canh: Vec<i64> = Vec::new();
    let mut toan_bo_mau: Vec<f32> = Vec::new();

    for (i, chunk) in chunks.iter().enumerate() {
        let phonemes = g2p.phonemize(chunk, false)?;
        if phonemes.trim().is_empty() {
            continue;
        }

        // Hạt giống y hệt _seedOf trong vieneu_engine.dart (Dart) — để tái hiện
        // đúng bit-for-bit âm thanh mà ứng dụng thật đã sinh ra cho đoạn này.
        let seed = seed_of(&format!("{}|{}", args[5], chunk));

        let started = Instant::now();
        let ctx_dung: &[i64] = if khong_ngu_canh { &[] } else { &ngu_canh };
        let result = synthesize(&mut model, &phonemes, voice, &sampling, seed, ctx_dung)?;
        let seconds = result.samples.len() as f32 / SAMPLE_RATE as f32;
        println!(
            "  đoạn {}/{}: {:.2}s âm thanh trong {:.2}s",
            i + 1,
            chunks.len(),
            seconds,
            started.elapsed().as_secs_f32()
        );

        // Cất đuôi cho đoạn kế — giống hệt vieneu_synthesize trong ffi.rs.
        let lay = KHUNG_DUOI.min(result.frames);
        let mut duoi: Vec<i64> =
            result.codes[(result.frames - lay) * n_vq..].iter().map(|v| *v as i64).collect();

        let mau_moi_khung = if result.frames > 0 { result.samples.len() / result.frames } else { 0 };
        if result.frames > KHUNG_LANG && mau_moi_khung > 0 {
            let nang_luong: Vec<f32> = (0..result.frames)
                .map(|f| {
                    let a = f * mau_moi_khung;
                    let b = ((f + 1) * mau_moi_khung).min(result.samples.len());
                    result.samples[a..b].iter().map(|v| v * v).sum::<f32>()
                })
                .collect();

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
            duoi.extend(
                result.codes[dau * n_vq..(dau + KHUNG_LANG) * n_vq].iter().map(|v| *v as i64),
            );
        }
        ngu_canh = duoi;

        toan_bo_mau.extend_from_slice(&result.samples);
    }

    write_wav(Path::new(&args[7]), &toan_bo_mau)?;
    println!(
        "Đã ghi {} ({:.1}s âm thanh)",
        args[7],
        toan_bo_mau.len() as f32 / SAMPLE_RATE as f32
    );
    Ok(())
}

fn load_voices(path: &Path) -> Result<std::collections::HashMap<String, Voice>, String> {
    let text = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    let json: serde_json::Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let presets = json.get("presets").and_then(|v| v.as_object()).ok_or("thiếu presets")?;

    let mut out = std::collections::HashMap::new();
    for (name, value) in presets {
        let speaker_emb = value["speaker_emb"]
            .as_array()
            .map(|a| a.iter().filter_map(|x| x.as_f64()).map(|x| x as f32).collect())
            .unwrap_or_default();
        let rows = value["codes"].as_array().cloned().unwrap_or_default();
        let mut ref_codes = Vec::new();
        for row in &rows {
            if let Some(cols) = row.as_array() {
                ref_codes.extend(cols.iter().filter_map(|x| x.as_i64()));
            }
        }
        out.insert(
            name.clone(),
            Voice {
                speaker_emb,
                ref_codes,
                ref_frames: rows.len(),
                style: value["style"].as_str().unwrap_or("tu_nhien").to_string(),
            },
        );
    }
    Ok(out)
}

/// Y hệt `_seedOf` trong app/lib/services/tts/vieneu_engine.dart (FNV-1a 64
/// bit trên UTF-16 code unit của chuỗi) — để seed khớp bit-for-bit với app thật.
fn seed_of(key: &str) -> u64 {
    let mut hash: u64 = 0xcbf29ce484222325;
    for c in key.chars() {
        hash ^= c as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

/// Đọc đè tham số lấy mẫu từ biến môi trường, giữ mặc định cho phần không đặt.
fn sampling_from_env() -> Sampling {
    fn env_f32(key: &str, default: f32) -> f32 {
        std::env::var(key).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
    }
    fn env_usize(key: &str, default: usize) -> usize {
        std::env::var(key).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
    }
    let base = Sampling::default();
    Sampling {
        temperature: env_f32("VIENEU_TEMPERATURE", base.temperature),
        top_k: env_usize("VIENEU_TOP_K", base.top_k),
        top_p: env_f32("VIENEU_TOP_P", base.top_p),
        repetition_penalty: env_f32("VIENEU_REP_PENALTY", base.repetition_penalty),
        ..base
    }
}

fn write_wav(path: &Path, samples: &[f32]) -> Result<(), String> {
    let mut file = std::fs::File::create(path).map_err(|e| e.to_string())?;
    let bytes = samples.len() * 2;
    let header: Vec<u8> = {
        let mut h = Vec::with_capacity(44);
        h.extend(b"RIFF");
        h.extend(((36 + bytes) as u32).to_le_bytes());
        h.extend(b"WAVEfmt ");
        h.extend(16u32.to_le_bytes());
        h.extend(1u16.to_le_bytes()); // PCM
        h.extend(1u16.to_le_bytes()); // mono
        h.extend(SAMPLE_RATE.to_le_bytes());
        h.extend((SAMPLE_RATE * 2).to_le_bytes());
        h.extend(2u16.to_le_bytes());
        h.extend(16u16.to_le_bytes());
        h.extend(b"data");
        h.extend((bytes as u32).to_le_bytes());
        h
    };
    file.write_all(&header).map_err(|e| e.to_string())?;
    for s in samples {
        let v = (s.clamp(-1.0, 1.0) * 32767.0) as i16;
        file.write_all(&v.to_le_bytes()).map_err(|e| e.to_string())?;
    }
    Ok(())
}
