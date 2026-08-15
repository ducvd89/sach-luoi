//! In âm vị mà sea-g2p sinh ra cho một câu — không tổng hợp gì cả.
//!
//! Mô hình TTS không bao giờ thấy chữ, nó chỉ thấy âm vị. Nên muốn biết vì sao
//! một từ bị đọc sai thì phải soi ở đây trước, chứ nghe rồi đoán là mò kim.
//!
//! Dùng để so cách g2p đọc từ tiếng Anh khi có và không có thẻ `<en>`:
//!
//!     cargo run --release --example soi_am_vi -- <sea_g2p.bin> "câu cần soi"

use std::path::PathBuf;

fn main() {
    let mut args = std::env::args().skip(1);
    let dict = PathBuf::from(args.next().unwrap_or_else(|| {
        eprintln!("dùng: soi_am_vi <sea_g2p.bin> \"câu\" [\"câu\" ...]");
        std::process::exit(2);
    }));

    let g2p = match sea_g2p_rs::ffi::SeaG2p::open(dict.to_str().unwrap_or_default(), "vi") {
        Ok(g) => g,
        Err(e) => {
            eprintln!("không mở được từ điển: {e:?}");
            std::process::exit(1);
        }
    };

    for cau in args {
        match g2p.phonemize(&cau, false) {
            Ok(am) => {
                println!("VÀO : {cau}");
                println!("RA  : {am}");
                println!();
            }
            Err(e) => eprintln!("lỗi với \"{cau}\": {e:?}"),
        }
    }
}
