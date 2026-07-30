//! Nhân bản một giọng bằng Rust rồi in ra đặc trưng để so với bản Python.
use std::path::Path;

fn main() -> Result<(), String> {
    let a: Vec<String> = std::env::args().collect();
    let r = sachnoi_vieneu::enroll::enroll(Path::new(&a[1]), Path::new(&a[2]), Path::new(&a[3]))?;
    println!("dac trung: {} chieu, ma tham chieu: {} khung x {}",
             r.speaker_emb.len(), r.frames,
             if r.frames > 0 { r.codes.len() / r.frames } else { 0 });
    let norm: f32 = r.speaker_emb.iter().map(|v| v * v).sum::<f32>().sqrt();
    println!("chuan: {norm:.4}");
    println!("6 gia tri dau: {:?}",
             r.speaker_emb.iter().take(6).map(|v| (v * 10000.0).round() / 10000.0).collect::<Vec<_>>());
    println!("6 ma dau: {:?}", &r.codes[..6.min(r.codes.len())]);
    Ok(())
}
