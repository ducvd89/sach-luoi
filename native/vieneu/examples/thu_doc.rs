//! Đọc thử một câu bằng engine Rust rồi ghi ra WAV.
//!
//! Chạy trên máy tính để đối chiếu với bản Python trước khi tin nó trên điện
//! thoại:
//!
//! ```
//! set ORT_DYLIB_PATH=...\onnxruntime.dll
//! cargo run --release --example thu_doc -- <model_dir> <codec_dir> <dict> <voices.json> <ten_giong> <file_ra.wav>
//! ```

use std::io::Write;
use std::path::Path;
use std::time::Instant;

use sachnoi_vieneu::engine::synthesize;
use sachnoi_vieneu::model::{Model, Sampling, Voice, SAMPLE_RATE};

fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 7 {
        return Err("cần: <model_dir> <codec_dir> <dict.bin> <giong.json> <tên giọng> <ra.wav> [câu]".into());
    }
    let text = args
        .get(7)
        .cloned()
        .unwrap_or_else(|| "Xin chào, đây là bản đọc thử của ứng dụng sách nói.".to_string());

    println!("Đang nạp mô hình...");
    let started = Instant::now();
    let mut model = Model::load(Path::new(&args[1]), Path::new(&args[2]), 4)?;
    println!("  nạp xong sau {:.1}s", started.elapsed().as_secs_f32());

    let g2p = sea_g2p_rs::ffi::SeaG2p::open(&args[3], "vi")?;
    let voices = load_voices(Path::new(&args[4]))?;
    let voice = voices.get(&args[5]).ok_or(format!("không có giọng '{}'", args[5]))?;

    let phonemes = g2p.phonemize(&text, false)?;
    // Cắt theo ký tự chứ không theo byte: âm vị IPA là chữ nhiều byte, cắt giữa
    // chừng là panic.
    println!("Âm vị: {}", phonemes.chars().take(90).collect::<String>());

    let started = Instant::now();
    let result = synthesize(&mut model, &phonemes, voice, &Sampling::default(), 12345, &[])?;
    let elapsed = started.elapsed().as_secs_f32();
    let seconds = result.samples.len() as f32 / SAMPLE_RATE as f32;
    println!(
        "Sinh {} khung -> {:.2}s âm thanh trong {:.2}s (nhanh gấp {:.2} lần thời gian thực)",
        result.frames,
        seconds,
        elapsed,
        seconds / elapsed
    );

    write_wav(Path::new(&args[6]), &result.samples)?;
    println!("Đã ghi {}", args[6]);
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
