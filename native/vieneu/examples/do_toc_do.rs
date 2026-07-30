//! Đo tốc độ đọc theo số luồng, để chọn đúng con số thay vì đoán.
//!
//! In ra hệ số thời gian thực: 3.0× nghĩa là một phút âm thanh mất 20 giây.
//!
//! Máy tính xách tay tụt tần số khi nóng lên, nên nếu quét số luồng theo thứ tự
//! tăng dần thì cái nóng lên bị tính thành cái chậm đi. Vì vậy: đảo thứ tự sau
//! mỗi vòng, đo mỗi cấu hình nhiều lần rồi lấy lần nhanh nhất — lần nhanh nhất
//! là lần ít bị việc khác giành CPU nhất.
//!
//! ```
//! set ORT_DYLIB_PATH=...\onnxruntime.dll
//! cargo run --release --example do_toc_do -- <model_dir> <codec_dir> <dict> <giong.json> <tên giọng>
//! ```

use std::collections::HashMap;
use std::io::Write;
use std::path::Path;
use std::time::Instant;

use sachnoi_vieneu::engine::synthesize;
use sachnoi_vieneu::model::{Model, Sampling, Voice, SAMPLE_RATE};

/// Đoạn dài cỡ một đoạn sách thật — câu quá ngắn thì phần dựng phiên lấn hết.
const CAU: &str = "Buổi sáng hôm ấy trời trong xanh và gió nhẹ. Người thợ già dậy từ sớm, \
pha một ấm trà nóng rồi ngồi lặng lẽ bên hiên nhà. Ông nhớ lại quãng thời gian cả xóm còn \
nghèo nhưng ai cũng thương nhau.";

const LUONG: [usize; 3] = [0, 4, 8];
const SO_VONG: usize = 6;

fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 6 {
        return Err("cần: <model_dir> <codec_dir> <dict.bin> <giong.json> <tên giọng>".into());
    }
    let g2p = sea_g2p_rs::ffi::SeaG2p::open(&args[3], "vi")?;
    let voices = load_voices(Path::new(&args[4]))?;
    let voice = voices
        .get(&args[5])
        .ok_or_else(|| format!("không có giọng '{}'", args[5]))?;
    let phonemes = g2p.phonemize(CAU, false)?;
    let sampling = Sampling::default();

    let mut moi_lan: HashMap<usize, Vec<f32>> = HashMap::new();

    for vong in 0..SO_VONG {
        // Xoay thứ tự mỗi vòng: cấu hình nào cũng có lượt chạy lúc máy còn mát.
        for i in 0..LUONG.len() {
            let luong = LUONG[(i + vong) % LUONG.len()];
            let mut model = Model::load(Path::new(&args[1]), Path::new(&args[2]), luong)?;
            // Lượt đầu của một phiên mới luôn chậm hơn, không tính vào số đo.
            let _ = synthesize(&mut model, &phonemes, voice, &sampling, 1234)?;

            for _ in 0..2 {
                let t = Instant::now();
                let mau = synthesize(&mut model, &phonemes, voice, &sampling, 1234)?;
                let giay = t.elapsed().as_secs_f32();
                let he_so = (mau.samples.len() as f32 / SAMPLE_RATE as f32) / giay;
                moi_lan.entry(luong).or_default().push(he_so);
            }
            print!(".");
            std::io::stdout().flush().ok();
        }
    }
    println!();
    println!(
        "{:>7}  {:>11}  {:>10}  {:>11}",
        "luồng", "nhanh nhất", "trung vị", "chậm nhất"  // 0 = để engine tự chọn
    );
    for luong in LUONG {
        let mut v = moi_lan.remove(&luong).unwrap_or_default();
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        println!(
            "{luong:>7}  {:>10.2}×  {:>9.2}×  {:>10.2}×",
            v[v.len() - 1],
            v[v.len() / 2],
            v[0]
        );
    }
    Ok(())
}

fn load_voices(path: &Path) -> Result<HashMap<String, Voice>, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let json: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("giong.json lỗi: {e}"))?;
    let presets = json
        .get("presets")
        .and_then(|v| v.as_object())
        .ok_or("giong.json thiếu presets")?;

    let mut ra = HashMap::new();
    for (ten, v) in presets {
        let frames = v.get("ref_frames").and_then(|x| x.as_u64()).unwrap_or(0) as usize;
        let codes = v
            .get("ref_codes")
            .and_then(|x| x.as_array())
            .map(|hang| {
                hang.iter()
                    .flat_map(|r| {
                        r.as_array()
                            .map(|c| c.iter().filter_map(|x| x.as_i64()).collect::<Vec<_>>())
                            .unwrap_or_default()
                    })
                    .collect::<Vec<i64>>()
            })
            .unwrap_or_default();
        ra.insert(
            ten.clone(),
            Voice {
                speaker_emb: doc_f32(v.get("speaker_emb")),
                ref_codes: codes,
                ref_frames: frames,
                style: v
                    .get("style")
                    .and_then(|x| x.as_str())
                    .unwrap_or("doc_truyen")
                    .to_string(),
            },
        );
    }
    Ok(ra)
}

fn doc_f32(v: Option<&serde_json::Value>) -> Vec<f32> {
    v.and_then(|x| x.as_array())
        .map(|a| a.iter().filter_map(|x| x.as_f64()).map(|x| x as f32).collect())
        .unwrap_or_default()
}
