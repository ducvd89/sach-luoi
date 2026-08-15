//! Mở nhiều bản engine v2 trong CÙNG một tiến trình rồi đọc song song.
//!
//! Đây đúng là cảnh lúc xuất file: mỗi worker là một isolate của Dart, mà isolate
//! dùng chung tiến trình. Bài này canh hai thứ:
//!
//! 1. Mở được bản thứ hai, thứ ba — `LlamaBackend` phải là singleton, không thì
//!    bản sau chết với `BackendAlreadyInitialized`.
//! 2. Chạy song song có nhanh hơn thật không, và tốn thêm bao nhiêu RAM. Trọng
//!    số nạp bằng mmap nên các bản dùng chung một bản trong page cache.
//!
//!     cargo run --release --example thu_v2_song_song -- C:\Dev\models\vieneu-v2 3

use std::path::PathBuf;
use std::time::Instant;

use sachnoi_vieneu::v2::{EngineV2, SAMPLE_RATE_V2};

const DOAN: &str = "Hàn Lập nhìn quanh bốn phía, trong lòng thầm tính toán. Nơi này linh khí \
nồng đậm hơn hẳn những chỗ khác, hiển nhiên không phải đất bình thường. Hắn cẩn thận thu liễm \
khí tức, chậm rãi men theo vách đá mà đi tới, từng bước một đều hết sức thận trọng.";

fn rss_mb() -> f64 {
    // Chỉ có trên Windows; máy khác thì in 0 và bỏ qua phần RAM.
    #[cfg(target_os = "windows")]
    {
        use std::mem::size_of;
        #[repr(C)]
        struct Counters {
            cb: u32,
            page_fault_count: u32,
            peak_working_set_size: usize,
            working_set_size: usize,
            quota_peak_paged_pool_usage: usize,
            quota_paged_pool_usage: usize,
            quota_peak_non_paged_pool_usage: usize,
            quota_non_paged_pool_usage: usize,
            pagefile_usage: usize,
            peak_pagefile_usage: usize,
        }
        unsafe extern "system" {
            fn GetCurrentProcess() -> isize;
            fn K32GetProcessMemoryInfo(h: isize, c: *mut Counters, cb: u32) -> i32;
        }
        let mut c: Counters = unsafe { std::mem::zeroed() };
        c.cb = size_of::<Counters>() as u32;
        unsafe {
            if K32GetProcessMemoryInfo(GetCurrentProcess(), &mut c, c.cb) != 0 {
                return c.working_set_size as f64 / 1024.0 / 1024.0;
            }
        }
    }
    0.0
}

fn main() {
    let mut args = std::env::args().skip(1);
    let dir = PathBuf::from(args.next().unwrap_or_else(|| {
        eprintln!("dùng: thu_v2_song_song <thư mục mô hình> [số worker]");
        std::process::exit(2);
    }));
    let so_worker: usize = args.next().and_then(|s| s.parse().ok()).unwrap_or(3);

    let dict = dir.join("sea_g2p.bin");
    let g2p = sea_g2p_rs::ffi::SeaG2p::open(dict.to_str().unwrap_or_default(), "vi")
        .unwrap_or_else(|e| {
            eprintln!("không mở được từ điển: {e:?}");
            std::process::exit(1);
        });
    let am_vi = g2p.phonemize(DOAN, false).unwrap_or_default();

    // Mỗi worker lấy một phần số nhân, giống cách bên Dart chia.
    let nhan = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(8);
    let luong = ((nhan / (2 * so_worker)).max(1)) as i32;
    println!("{nhan} nhân · {so_worker} worker · {luong} luồng mỗi worker");
    println!("RAM trước khi nạp: {:.0} MB", rss_mb());

    let mut engines = Vec::new();
    for i in 0..so_worker {
        let t = Instant::now();
        match EngineV2::open(
            &dir.join("VieNeu-TTS-v2-Q4-K-M.gguf"),
            &dir.join("neucodec_decoder_int8.onnx"),
            &dir.join("voices.json"),
            &dir.join("giong_v2.json"),
            &dir.join("giong_v2_nguoi_dung.json"),
            luong,
            &g2p,
        ) {
            Ok(e) => {
                println!(
                    "  worker {} nạp xong sau {:.2}s · RAM {:.0} MB",
                    i + 1,
                    t.elapsed().as_secs_f64(),
                    rss_mb()
                );
                engines.push(e);
            }
            Err(e) => {
                eprintln!("  worker {} HỎNG: {e}", i + 1);
                eprintln!("  (nếu là BackendAlreadyInitialized thì singleton backend đã vỡ)");
                std::process::exit(1);
            }
        }
    }

    // Đọc song song, mỗi worker một hạt giống khác nên không ai chờ ai.
    let bat_dau = Instant::now();
    let tong: usize = std::thread::scope(|s| {
        let mut tay = Vec::new();
        for (i, engine) in engines.iter_mut().enumerate() {
            let am_vi = &am_vi;
            tay.push(s.spawn(move || {
                match engine.synthesize(am_vi, "Ly", 777 + i as u32) {
                    Ok(v) => v.len(),
                    Err(e) => {
                        eprintln!("worker {} lỗi đọc: {e}", i + 1);
                        0
                    }
                }
            }));
        }
        tay.into_iter().map(|t| t.join().unwrap_or(0)).sum()
    });

    let giay = bat_dau.elapsed().as_secs_f64();
    let tieng = tong as f64 / SAMPLE_RATE_V2 as f64;
    println!();
    println!("  {so_worker} đoạn cùng lúc: {tieng:.2}s tiếng trong {giay:.2}s");
    println!("  tổng thông lượng: {:.2}× thời gian thực", tieng / giay);
    println!("  RAM đỉnh: {:.0} MB", rss_mb());
}
