//! Đọc thử một đoạn bằng engine Matcha, ghi ra WAV và in tốc độ.
//!
//! Dùng để soi lại hai con số đã ghi trong `src/matcha.rs` khi đụng vào engine:
//! thông lượng theo số luồng, và thời lượng theo `length_scale`. Bài đo phải
//! chạy khi **đã đóng ứng dụng** — bản Windows chạy nền làm lệch số tới 40%.
//!
//!     set ORT_DYLIB_PATH=...\onnxruntime.dll
//!     cargo run --release --example thu_matcha -- C:\Dev\models\matcha "Xin chào." 1.0

use std::path::PathBuf;
use std::time::Instant;

use sachnoi_vieneu::matcha::{EngineMatcha, SAMPLE_RATE_MATCHA};

fn main() {
    let mut args = std::env::args().skip(1);
    let dir = PathBuf::from(args.next().unwrap_or_else(|| {
        eprintln!("dùng: thu_matcha <thư mục mô hình> [văn bản] [tốc độ] [luồng]");
        std::process::exit(2);
    }));
    let text = args.next().unwrap_or_else(|| {
        "Trong khu rừng già, ánh nắng chiều xuyên qua tán lá tạo thành những vệt sáng \
         loang lổ trên mặt đất khô. Ông lão ngồi bên gốc cây cổ thụ, tay cầm chiếc tẩu \
         thuốc đã cũ mèm, mắt nhìn về phía chân trời xa thẳm."
            .to_string()
    });
    let toc_do: f32 = args.next().and_then(|s| s.parse().ok()).unwrap_or(1.0);
    let threads: usize = args.next().and_then(|s| s.parse().ok()).unwrap_or_else(|| {
        std::thread::available_parallelism().map(|n| (n.get() / 2).max(1)).unwrap_or(4)
    });

    println!("Đang nạp mô hình… ({threads} luồng)");
    let nap = Instant::now();
    let mut engine = match EngineMatcha::open(
        &dir.join("matcha_encoder.onnx"),
        &dir.join("matcha_decoder.onnx"),
        &dir.join("vocos.onnx"),
        &dir.join("symbols.json"),
        threads,
    ) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("lỗi: {e}");
            std::process::exit(1);
        }
    };
    println!("Nạp xong sau {:.2}s", nap.elapsed().as_secs_f64());
    println!("Đọc ({} ký tự, tốc độ {toc_do}×): {text}", text.chars().count());

    // Chạy một lượt ngắn cho ONNX Runtime dựng xong bộ đệm, không thì lượt đầu
    // gánh cả phần khởi động và con số đo ra thấp hơn thực tế.
    let _ = engine.doc("Xin chào.", 1.0, 1, 0);

    let bat_dau = Instant::now();
    // Mã 0: bài thử này không có ai tua nên không cần huỷ.
    let samples = match engine.doc(&text, toc_do, 12345, 0) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("lỗi đọc: {e}");
            std::process::exit(1);
        }
    };
    let giay_chay = bat_dau.elapsed().as_secs_f64();
    let giay_tieng = samples.len() as f64 / SAMPLE_RATE_MATCHA as f64;

    println!();
    println!("  mẫu âm      : {}", samples.len());
    println!("  thời lượng  : {giay_tieng:.2}s");
    println!("  chạy hết    : {giay_chay:.2}s");
    println!("  tốc độ      : {:.2}× thời gian thực", giay_tieng / giay_chay);

    let out = dir.join("thu_matcha.wav");
    match std::fs::write(&out, dung_wav(&samples, SAMPLE_RATE_MATCHA)) {
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
