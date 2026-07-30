//! In ra fbank của một file .wav để đối chiếu với torchaudio.
use std::io::Read;

fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    let mut file = std::fs::File::open(&args[1]).map_err(|e| e.to_string())?;
    let mut raw = Vec::new();
    file.read_to_end(&mut raw).map_err(|e| e.to_string())?;

    // WAV 16-bit mono/stereo đơn giản: bỏ 44 byte đầu.
    let rate = u32::from_le_bytes([raw[24], raw[25], raw[26], raw[27]]);
    let channels = u16::from_le_bytes([raw[22], raw[23]]) as usize;
    let pcm: Vec<f32> = raw[44..]
        .chunks_exact(2)
        .map(|b| i16::from_le_bytes([b[0], b[1]]) as f32 / 32768.0)
        .collect();
    let mono: Vec<f32> = if channels > 1 {
        pcm.chunks(channels).map(|c| c.iter().sum::<f32>() / channels as f32).collect()
    } else {
        pcm
    };

    let wav = sachnoi_vieneu::fbank::resample_to_16k(&mono, rate);
    let feat = sachnoi_vieneu::fbank::speaker_fbank(&wav);
    let frames = feat.len() / sachnoi_vieneu::fbank::MEL_BINS;
    println!("rate={rate} channels={channels} samples={} -> 16k samples={} frames={frames}",
             mono.len(), wav.len());

    // In vài con số để so: trung bình, lệch chuẩn, và ba khung đầu.
    let mean = feat.iter().sum::<f32>() / feat.len() as f32;
    let var = feat.iter().map(|v| (v - mean) * (v - mean)).sum::<f32>() / feat.len() as f32;
    println!("mean={mean:.6} std={:.6}", var.sqrt());
    for f in [0usize, 1, frames / 2] {
        let row = &feat[f * 80..f * 80 + 6];
        println!("frame {f}: {:?}", row.iter().map(|v| (v * 1000.0).round() / 1000.0).collect::<Vec<_>>());
    }
    Ok(())
}
