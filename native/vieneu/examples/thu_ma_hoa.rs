//! Nén thử một file WAV thật ra Opus, MP3 và AAC, để bộ giải mã ngoài kiểm lại.
//!
//! ```
//! cargo run --release --example thu_ma_hoa -- vao.wav ra_thu_muc
//! ```
use sachnoi_vieneu::ma_hoa::{doc_wav_mono, wav_sang_aac, wav_sang_mp3, wav_sang_opus};

fn main() -> Result<(), String> {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 3 {
        return Err("cần: <vao.wav> <thu_muc_ra>".into());
    }
    let byte = std::fs::read(&a[1]).map_err(|e| e.to_string())?;
    let (pcm, sr) = doc_wav_mono(&byte)?;
    println!("doc {} mau o {} Hz = {:.1} giay", pcm.len(), sr, pcm.len() as f32 / sr as f32);

    for (ten, du_lieu) in [
        ("opus-32k.opus", wav_sang_opus(&pcm, sr, 32_000)?),
        ("opus-64k.opus", wav_sang_opus(&pcm, sr, 64_000)?),
        ("mp3-128k.mp3", wav_sang_mp3(&pcm, sr, 128)?),
        ("aac-64k.aac", wav_sang_aac(&pcm, sr, 64_000)?),
    ] {
        let d = std::path::Path::new(&a[2]).join(ten);
        std::fs::write(&d, &du_lieu).map_err(|e| e.to_string())?;
        println!("{:<14} {:>8} KB", ten, du_lieu.len() / 1024);
    }
    Ok(())
}
