//! In ra tên và hình dạng tensor của bộ giải mã NeuCodec (dùng cho VieNeu v2).
//!
//! Bản v2 dùng codec khác hẳn v3 (NeuCodec thay cho MOSS), mà repo của Neuphonic
//! không ghi tài liệu về chữ ký đồ thị. Chạy cái này một lần để biết phải bơm
//! tensor tên gì vào:
//!
//!     set ORT_DYLIB_PATH=...\onnxruntime.dll
//!     cargo run --release --example soi_codec_v2 -- C:\Dev\models\vieneu-v2\neucodec_decoder_int8.onnx

use ort::session::Session;

fn main() {
    let path = match std::env::args().nth(1) {
        Some(p) => p,
        None => {
            eprintln!("thiếu đường dẫn tới file .onnx");
            std::process::exit(2);
        }
    };

    let session = match Session::builder().and_then(|mut b| b.commit_from_file(&path)) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("không mở được {path}: {e}");
            eprintln!("(ORT_DYLIB_PATH đã trỏ vào onnxruntime.dll chưa?)");
            std::process::exit(1);
        }
    };

    println!("== ĐẦU VÀO ==");
    for input in session.inputs() {
        println!("  {input:?}");
    }

    println!("== ĐẦU RA ==");
    for output in session.outputs() {
        println!("  {output:?}");
    }
}
