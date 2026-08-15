//! Đọc thử một đoạn bằng engine VieNeu v2, ghi ra WAV và in tốc độ.
//!
//! Đây là bài đo quyết định có nên đưa v2 vào ứng dụng hay không: NeuCodec dựng
//! 50 code cho mỗi giây tiếng, nên **thời gian thực là 50 tok/s**. Dưới mức ấy
//! thì nghe sẽ khựng vì tổng hợp không đuổi kịp tốc độ nghe.
//!
//!     set ORT_DYLIB_PATH=...\onnxruntime.dll
//!     cargo run --release --example thu_v2 -- C:\Dev\models\vieneu-v2 "Xin chào." Ly

use std::path::PathBuf;
use std::time::Instant;

use sachnoi_vieneu::v2::{EngineV2, MAU_MOI_CODE, SAMPLE_RATE_V2};

fn main() {
    let mut args = std::env::args().skip(1);
    let dir = PathBuf::from(args.next().unwrap_or_else(|| {
        eprintln!("dùng: thu_v2 <thư mục mô hình> [văn bản] [giọng]");
        std::process::exit(2);
    }));
    let text = args
        .next()
        .unwrap_or_else(|| "Hôm nay trời đẹp, tôi muốn đi dạo một vòng quanh hồ.".to_string());
    let voice = args.next();
    // Hạt giống đổi được để soi đúng cơ chế đọc lại của `export_service.dart`:
    // đoạn nào mô hình đọc hỏng thì app đọc lại bằng hạt giống khác.
    let seed: u32 = args.next().and_then(|s| s.parse().ok()).unwrap_or(12345);

    let threads = std::thread::available_parallelism()
        .map(|n| (n.get() as i32 / 2).max(1))
        .unwrap_or(4);

    let dict = dir.join("sea_g2p.bin");
    let g2p = match sea_g2p_rs::ffi::SeaG2p::open(dict.to_str().unwrap_or_default(), "vi") {
        Ok(g) => g,
        Err(e) => {
            eprintln!("không mở được từ điển âm vị {}: {e:?}", dict.display());
            eprintln!("(chép app/assets/sea_g2p.bin vào thư mục mô hình)");
            std::process::exit(1);
        }
    };

    println!("Đang nạp mô hình… ({threads} luồng)");
    let nap = Instant::now();
    let mut engine = match EngineV2::open(
        &dir.join("VieNeu-TTS-v2-Q4-K-M.gguf"),
        &dir.join("neucodec_decoder_int8.onnx"),
        &dir.join("voices.json"),
        &dir.join("giong_v2.json"),
        &dir.join("giong_v2_nguoi_dung.json"),
        threads,
        &g2p,
    ) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("lỗi: {e}");
            std::process::exit(1);
        }
    };
    println!("Nạp xong sau {:.2}s", nap.elapsed().as_secs_f64());
    println!("Giọng có: {}", engine.voice_names().join(", "));

    let voice = voice.unwrap_or_else(|| engine.voice_names()[0].clone());
    println!("Đọc bằng giọng '{voice}': {text}");

    // Mô hình được huấn luyện trên âm vị. Đưa chữ thường vào là nó đọc theo mặt
    // chữ, câu dài ra gấp mấy lần — lỗi này đo được ngay ở thời lượng đầu ra.
    let am_vi = match g2p.phonemize(&text, false) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("lỗi chuyển âm vị: {e:?}");
            std::process::exit(1);
        }
    };
    println!("âm vị      : {am_vi}");

    let bat_dau = Instant::now();
    let samples = match engine.synthesize(&am_vi, &voice, seed) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("lỗi đọc: {e}");
            std::process::exit(1);
        }
    };
    let giay_chay = bat_dau.elapsed().as_secs_f64();

    let giay_tieng = samples.len() as f64 / SAMPLE_RATE_V2 as f64;
    let so_code = samples.len() / MAU_MOI_CODE + 1;

    println!();
    println!("  mẫu âm      : {}", samples.len());
    println!("  thời lượng  : {giay_tieng:.2}s");
    println!("  chạy hết    : {giay_chay:.2}s");
    println!("  tốc độ      : {:.2}× thời gian thực", giay_tieng / giay_chay);
    println!(
        "  sinh token  : {:.1} tok/s  (cần ≥50 để theo kịp lúc nghe)",
        so_code as f64 / giay_chay
    );

    let out = dir.join("thu_v2.wav");
    match std::fs::write(&out, dung_wav(&samples, SAMPLE_RATE_V2)) {
        Ok(()) => println!("\nĐã ghi {}", out.display()),
        Err(e) => eprintln!("không ghi được WAV: {e}"),
    }
}

/// Đóng gói mẫu âm thành WAV 16-bit. Bản rút gọn của `core/wav.dart` phía Dart —
/// bài thử này không nên phải kéo theo cả tầng ấy.
fn dung_wav(samples: &[f32], rate: u32) -> Vec<u8> {
    let pcm_len = samples.len() * 2;
    let mut out = Vec::with_capacity(44 + pcm_len);
    out.extend(b"RIFF");
    out.extend(((36 + pcm_len) as u32).to_le_bytes());
    out.extend(b"WAVEfmt ");
    out.extend(16u32.to_le_bytes());
    out.extend(1u16.to_le_bytes()); // PCM
    out.extend(1u16.to_le_bytes()); // một kênh
    out.extend(rate.to_le_bytes());
    out.extend((rate * 2).to_le_bytes());
    out.extend(2u16.to_le_bytes());
    out.extend(16u16.to_le_bytes());
    out.extend(b"data");
    out.extend((pcm_len as u32).to_le_bytes());
    for s in samples {
        out.extend(((s.clamp(-1.0, 1.0) * 32767.0) as i16).to_le_bytes());
    }
    out
}
