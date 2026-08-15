//! Đo xem lệnh huỷ cắt được lượt đọc đang chạy nhanh tới mức nào.
//!
//! Đây là thứ quyết định cảm giác lúc TUA: người dùng nhảy sang đoạn khác thì
//! mấy đoạn đang đọc trước phải buông máy ngay, không thì đoạn vừa chọn xếp
//! hàng sau chúng — mỗi đoạn 5–7 giây.
//!
//!     cargo run --release --example thu_huy_v2 -- C:\Dev\models\vieneu-v2

use std::path::PathBuf;
use std::time::{Duration, Instant};

use sachnoi_vieneu::v2::{huy_toi, EngineV2, LOI_HUY};

const DOAN: &str = "Hàn Lập nhìn quanh bốn phía, trong lòng thầm tính toán. Nơi này linh khí \
nồng đậm hơn hẳn những chỗ khác, hiển nhiên không phải đất bình thường. Hắn cẩn thận thu liễm \
khí tức, chậm rãi men theo vách đá mà đi tới, từng bước một đều hết sức thận trọng.";

fn main() {
    let dir = PathBuf::from(std::env::args().nth(1).unwrap_or_else(|| {
        eprintln!("dùng: thu_huy_v2 <thư mục mô hình>");
        std::process::exit(2);
    }));

    let dict = dir.join("sea_g2p.bin");
    let g2p = sea_g2p_rs::ffi::SeaG2p::open(dict.to_str().unwrap_or_default(), "vi")
        .unwrap_or_else(|e| {
            eprintln!("không mở được từ điển: {e:?}");
            std::process::exit(1);
        });
    let am_vi = g2p.phonemize(DOAN, false).unwrap_or_default();

    let mut engine = EngineV2::open(
        &dir.join("VieNeu-TTS-v2-Q4-K-M.gguf"),
        &dir.join("neucodec_decoder_int8.onnx"),
        &dir.join("voices.json"),
        &dir.join("giong_v2.json"),
        &dir.join("giong_v2_nguoi_dung.json"),
        6,
        &g2p,
    )
    .unwrap_or_else(|e| {
        eprintln!("lỗi mở engine: {e}");
        std::process::exit(1);
    });

    // 1. Đọc trọn vẹn, lấy mốc so sánh.
    let t = Instant::now();
    let day = engine.synthesize(&am_vi, "Ly", 777, 0).map(|v| v.len()).unwrap_or(0);
    let giay_day = t.elapsed().as_secs_f64();
    println!("đọc trọn vẹn : {giay_day:.2}s ({day} mẫu)");

    // 2. Đọc lại, nhưng huỷ sau nửa giây. Lệnh huỷ phát từ luồng khác, đúng như
    //    lúc chạy thật: isolate giao diện gọi trong khi isolate nền đang kẹt.
    let ma = 42;
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(500));
        huy_toi(ma);
    });

    let t = Instant::now();
    let ket = engine.synthesize(&am_vi, "Ly", 777, ma);
    let giay_huy = t.elapsed().as_secs_f64();

    match ket {
        Err(e) if e == LOI_HUY => {
            println!("huỷ sau 0,50s : dừng lại ở {giay_huy:.2}s");
            println!("               tiết kiệm {:.2}s", giay_day - giay_huy);
            // Phải dừng gần như tức thì sau lệnh huỷ, không phải chạy nốt.
            assert!(
                giay_huy < giay_day * 0.6,
                "huỷ mà vẫn chạy {giay_huy:.2}s trên tổng {giay_day:.2}s — quá chậm"
            );
            println!("\nĐẠT: lệnh huỷ cắt được lượt đọc đang chạy.");
        }
        Err(e) => {
            eprintln!("KHÔNG ĐẠT: lỗi khác lỗi huỷ: {e}");
            std::process::exit(1);
        }
        Ok(_) => {
            eprintln!("KHÔNG ĐẠT: chạy hết {giay_huy:.2}s, lệnh huỷ không có tác dụng");
            std::process::exit(1);
        }
    }

    // 3. Yêu cầu MỚI (mã lớn hơn) phải không bị dính lệnh huỷ cũ.
    let t = Instant::now();
    match engine.synthesize(&am_vi, "Ly", 777, ma + 1) {
        Ok(v) => println!(
            "yêu cầu sau  : chạy bình thường {:.2}s ({} mẫu)",
            t.elapsed().as_secs_f64(),
            v.len()
        ),
        Err(e) => {
            eprintln!("KHÔNG ĐẠT: yêu cầu mới cũng bị huỷ theo: {e}");
            std::process::exit(1);
        }
    }
}
