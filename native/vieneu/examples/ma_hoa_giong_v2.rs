//! Tính mã tham chiếu NeuCodec cho một file ghi âm, in ra JSON của một giọng v2.
//!
//! Dùng để dựng `app/assets/giong_v2.json` — các giọng nhân bản sẵn mà bản cài
//! mang theo. Chạy một lần lúc phát triển rồi cất kết quả vào assets; người dùng
//! cuối không cần bộ mã hoá 519 MB chỉ để nghe những giọng ấy.
//!
//!     set ORT_DYLIB_PATH=...\onnxruntime.dll
//!     cargo run --release --example ma_hoa_giong_v2 -- \
//!         <encoder.onnx> <ghi-am.wav> "Tên giọng" "lời của đoạn ghi âm" "mô tả"

use std::path::Path;

use sachnoi_vieneu::v2::{ma_hoa_mau_giong, MAU_MOI_CODE, SAMPLE_RATE_V2};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 4 {
        eprintln!("dùng: ma_hoa_giong_v2 <encoder.onnx> <wav> <tên> <lời> [mô tả]");
        std::process::exit(2);
    }
    let (encoder, wav, ten, loi) = (&args[0], &args[1], &args[2], &args[3]);
    let mo_ta = args.get(4).cloned().unwrap_or_default();

    let codes = match ma_hoa_mau_giong(Path::new(wav), Path::new(encoder)) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("lỗi: {e}");
            std::process::exit(1);
        }
    };

    let moi_giay = SAMPLE_RATE_V2 as f64 / MAU_MOI_CODE as f64;
    eprintln!(
        "{ten}: {} code ≈ {:.2} giây",
        codes.len(),
        codes.len() as f64 / moi_giay
    );

    let entry = serde_json::json!({
        ten: { "codes": codes, "text": loi, "description": mo_ta }
    });
    println!("{}", serde_json::to_string(&entry).unwrap());
}
