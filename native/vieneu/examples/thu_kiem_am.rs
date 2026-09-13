//! Đo trực tiếp bộ kiểm âm trên WAV để đối chiếu với tai nghe và lời gốc.
use sachnoi_vieneu::kiem_am::BoKiemAm;
use std::path::Path;
use std::time::Instant;

fn main() -> Result<(), String> {
    let tham_so: Vec<String> = std::env::args().collect();
    if tham_so.len() < 3 {
        return Err("cách dùng: thu_kiem_am <thư_mục_wav2vec2> <file.wav> [nhịp_cao_độ]".into());
    }
    let mut bo = BoKiemAm::mo(Path::new(&tham_so[1]))?;
    let nhip = tham_so
        .get(3)
        .map(|s| s.parse::<f32>())
        .transpose()
        .map_err(|e| e.to_string())?
        .unwrap_or(1.0);
    let bat_dau = Instant::now();
    let ket = bo.kiem_file(Path::new(&tham_so[2]), nhip)?;
    eprintln!("Nhận dạng: {:.3} giây", bat_dau.elapsed().as_secs_f64());
    println!(
        "{}",
        serde_json::to_string(&ket).map_err(|e| e.to_string())?
    );
    Ok(())
}
