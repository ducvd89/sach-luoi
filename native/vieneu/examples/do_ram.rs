//! Đọc nhiều đoạn liên tiếp trên MỘT mô hình rồi in mức RAM sau mỗi đoạn.
//!
//! Để trả lời: mức RAM phình lên là do mã Rust/ONNX Runtime, hay do phía Dart.
use std::path::Path;
use sachnoi_vieneu::engine::synthesize;
use sachnoi_vieneu::model::{Model, Sampling, Voice, SAMPLE_RATE};

fn ram_mb() -> u64 {
    // Windows: đọc qua GetProcessMemoryInfo là phải bind winapi; dùng cách đơn
    // giản hơn là hỏi hệ điều hành qua wmic thì chậm. Đọc /proc không có trên
    // Windows, nên dùng con số của chính bộ cấp phát: xấp xỉ đủ để thấy xu hướng.
    #[cfg(windows)]
    {
        use std::process::Command;
        let ra = Command::new("powershell")
            .args(["-NoProfile", "-Command",
                &format!("[math]::Round((Get-Process -Id {}).WorkingSet64/1MB)", std::process::id())])
            .output();
        if let Ok(o) = ra {
            if let Ok(s) = String::from_utf8(o.stdout) {
                if let Ok(v) = s.trim().parse::<u64>() { return v; }
            }
        }
    }
    0
}

fn main() -> Result<(), String> {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 6 { return Err("cần: <model> <codec> <dict> <giong.json> <tên giọng>".into()); }
    let g2p = sea_g2p_rs::ffi::SeaG2p::open(&a[3], "vi")?;
    let voices = crate_load(Path::new(&a[4]))?;
    let voice = voices.get(&a[5]).ok_or("không có giọng")?;

    let mut model = Model::load(Path::new(&a[1]), Path::new(&a[2]), 4)?;
    println!("sau khi nạp mô hình: {} MB", ram_mb());

    let cau = [
        "Buổi sáng hôm ấy trời trong xanh và gió nhẹ, người thợ già dậy từ rất sớm.",
        "Ông pha một ấm trà nóng rồi ngồi lặng lẽ bên hiên nhà, nhìn ra con đường đất.",
        "Ngày ấy cả xóm còn nghèo, nhưng ai cũng thương nhau như người một nhà.",
        "Mùa gặt đến thì sân nhà nào cũng vàng rực, tiếng máy tuốt lúa chạy suốt đêm.",
    ];
    let mut sampling = Sampling::default();
    // Đoạn dài dần: nếu arena phình theo đoạn dài nhất rồi giữ luôn thì RAM chỉ
    // tăng, không bao giờ tụt lại — kể cả khi sau đó chỉ đọc đoạn ngắn.
    for (buoc, so_cau) in [(1usize, 1usize), (2, 3), (3, 6), (4, 12), (5, 1), (6, 1)] {
        let van: String = (0..so_cau).map(|k| cau[k % cau.len()]).collect::<Vec<_>>().join(" ");
        sampling.max_new_frames = 300 + so_cau * 120;
        let ph = g2p.phonemize(&van, false)?;
        let m = synthesize(&mut model, &ph, voice, &sampling, 99)?;
        println!("bước {} ({:>2} câu): {} MB   âm thanh {:.1}s", buoc, so_cau, ram_mb(),
            m.samples.len() as f32 / SAMPLE_RATE as f32);
    }
    Ok(())
}

// Dùng lại bộ đọc giong.json của ví dụ đo tốc độ.
include!("phan_dung_chung.rs");
