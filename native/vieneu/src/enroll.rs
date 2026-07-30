//! Nhân bản giọng từ một file .wav, ngay trên máy.
//!
//! Bản Python làm việc này bằng torchaudio; ở đây chỉ cần ONNX Runtime cộng
//! phần xử lý tín hiệu tự viết, nên chạy được cả trên điện thoại.
//!
//! Hai thứ được trích ra và cất lại:
//!
//! * **Đặc trưng giọng** (192 chiều) — quyết định chất giọng. Đường đi: đổi về
//!   16 kHz, tính fbank, đưa qua speaker_encoder.
//! * **Mã tham chiếu** — một đoạn mẫu đã mã hoá, giúp mô hình bắt đúng ngữ điệu.
//!   Đường đi: đổi về 48 kHz, đưa qua bộ mã hoá của codec.

use std::path::Path;

use ndarray::{Array1, Array3};
use ort::session::{builder::GraphOptimizationLevel, Session};
use ort::value::Value;

use crate::fbank::{resample_to_16k, speaker_fbank, MEL_BINS};

/// Mẫu dài hơn thế này thì cắt bớt — bản Python cũng chặn ở đây.
const MAX_REF_SECONDS: f32 = 8.0;
const CODEC_RATE: u32 = 48_000;

pub struct Enrolled {
    pub speaker_emb: Vec<f32>,
    /// (số khung, 16) đã làm phẳng.
    pub codes: Vec<i64>,
    pub frames: usize,
}

/// Đọc file WAV PCM 16-bit hoặc 32-bit float, trả về (mono, tần số).
pub fn read_wav(path: &Path) -> Result<(Vec<f32>, u32), String> {
    let raw = std::fs::read(path).map_err(|e| format!("không đọc được {}: {e}", path.display()))?;
    if raw.len() < 44 || &raw[0..4] != b"RIFF" || &raw[8..12] != b"WAVE" {
        return Err("không phải file WAV".into());
    }

    let mut at = 12usize;
    let mut channels = 1usize;
    let mut rate = 0u32;
    let mut bits = 16u16;
    let mut format = 1u16;

    while at + 8 <= raw.len() {
        let id = &raw[at..at + 4];
        let size = u32::from_le_bytes([raw[at + 4], raw[at + 5], raw[at + 6], raw[at + 7]]) as usize;
        let body = at + 8;

        if id == b"fmt " && body + 16 <= raw.len() {
            format = u16::from_le_bytes([raw[body], raw[body + 1]]);
            channels = u16::from_le_bytes([raw[body + 2], raw[body + 3]]).max(1) as usize;
            rate = u32::from_le_bytes([raw[body + 4], raw[body + 5], raw[body + 6], raw[body + 7]]);
            bits = u16::from_le_bytes([raw[body + 14], raw[body + 15]]);
        } else if id == b"data" {
            let end = (body + size).min(raw.len());
            let data = &raw[body..end];
            let samples: Vec<f32> = match (format, bits) {
                (1, 16) => data
                    .chunks_exact(2)
                    .map(|b| i16::from_le_bytes([b[0], b[1]]) as f32 / 32768.0)
                    .collect(),
                (1, 32) => data
                    .chunks_exact(4)
                    .map(|b| i32::from_le_bytes([b[0], b[1], b[2], b[3]]) as f32 / 2147483648.0)
                    .collect(),
                (3, 32) => data
                    .chunks_exact(4)
                    .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
                    .collect(),
                (1, 24) => data
                    .chunks_exact(3)
                    .map(|b| {
                        let v = ((b[2] as i32) << 24 | (b[1] as i32) << 16 | (b[0] as i32) << 8) >> 8;
                        v as f32 / 8388608.0
                    })
                    .collect(),
                _ => return Err(format!("WAV kiểu {format} {bits} bit chưa hỗ trợ")),
            };

            let mono: Vec<f32> = if channels > 1 {
                samples
                    .chunks(channels)
                    .map(|c| c.iter().sum::<f32>() / channels as f32)
                    .collect()
            } else {
                samples
            };
            if rate == 0 {
                return Err("WAV thiếu thông tin tần số".into());
            }
            return Ok((mono, rate));
        }

        at = body + size + (size & 1);
    }
    Err("WAV không có phần dữ liệu âm thanh".into())
}

fn open(path: &Path) -> Result<Session, String> {
    let build = || -> Result<Session, Box<dyn std::error::Error>> {
        Ok(Session::builder()?
            .with_optimization_level(GraphOptimizationLevel::Level3)?
            .commit_from_file(path)?)
    };
    build().map_err(|e| format!("không nạp được {}: {e}", path.display()))
}

/// Trích đặc trưng giọng và mã tham chiếu từ một mẫu ghi âm.
///
/// [speaker_encoder] và [codec_encoder] là hai file .onnx tải riêng — chỉ cần
/// khi thêm giọng nên không nằm trong bộ mô hình chính.
pub fn enroll(
    wav_path: &Path,
    speaker_encoder: &Path,
    codec_encoder: &Path,
) -> Result<Enrolled, String> {
    let (mut wav, rate) = read_wav(wav_path)?;
    if wav.is_empty() {
        return Err("file ghi âm rỗng".into());
    }

    let limit = (MAX_REF_SECONDS * rate as f32) as usize;
    if wav.len() > limit {
        wav.truncate(limit);
    }

    // ── Đặc trưng giọng: 16 kHz -> fbank -> speaker_encoder ────────────────
    let at_16k = resample_to_16k(&wav, rate);
    let feat = speaker_fbank(&at_16k);
    if feat.is_empty() {
        return Err("mẫu ghi âm quá ngắn — cần ít nhất khoảng một giây".into());
    }
    let frames = feat.len() / MEL_BINS;

    let mut session = open(speaker_encoder)?;
    let input = Array3::from_shape_vec((1, frames, MEL_BINS), feat)
        .map_err(|e| format!("fbank sai hình dạng: {e}"))?;
    let outputs = session
        .run(ort::inputs!["input" => Value::from_array(input).map_err(|e| e.to_string())?])
        .map_err(|e| format!("lỗi chạy bộ mã hoá giọng: {e}"))?;
    let (_, emb) = outputs
        .get("output")
        .ok_or("bộ mã hoá giọng không trả về 'output'")?
        .try_extract_tensor::<f32>()
        .map_err(|e| format!("đầu ra không phải float32: {e}"))?;
    let speaker_emb = emb.to_vec();
    drop(outputs);

    if speaker_emb.iter().all(|v| *v == 0.0) {
        return Err("không trích được đặc trưng giọng — mẫu có thể toàn im lặng".into());
    }

    // ── Mã tham chiếu: 48 kHz, hai kênh giống nhau -> bộ mã hoá của codec ──
    let at_48k = resample_linear(&wav, rate, CODEC_RATE);
    let n = at_48k.len();
    let mut stereo = Vec::with_capacity(n * 2);
    stereo.extend_from_slice(&at_48k);
    stereo.extend_from_slice(&at_48k);

    let mut session = open(codec_encoder)?;
    let waveform = Array3::from_shape_vec((1, 2, n), stereo)
        .map_err(|e| format!("sóng âm sai hình dạng: {e}"))?;
    let lengths = Array1::from_vec(vec![n as i32]);
    let outputs = session
        .run(ort::inputs![
            "waveform" => Value::from_array(waveform).map_err(|e| e.to_string())?,
            "input_lengths" => Value::from_array(lengths).map_err(|e| e.to_string())?
        ])
        .map_err(|e| format!("lỗi mã hoá mẫu: {e}"))?;

    let value = outputs
        .iter()
        .next()
        .ok_or("bộ mã hoá mẫu không trả về gì")?
        .1;
    // Bộ mã hoá trả về int32; phần còn lại của mô hình làm việc với int64.
    let (shape, codes) = match value.try_extract_tensor::<i32>() {
        Ok((shape, data)) => (shape.to_vec(), data.iter().map(|v| *v as i64).collect::<Vec<i64>>()),
        Err(_) => {
            let (shape, data) = value
                .try_extract_tensor::<i64>()
                .map_err(|e| format!("mã tham chiếu không phải số nguyên: {e}"))?;
            (shape.to_vec(), data.to_vec())
        }
    };
    // (1, số khung, 16)
    let code_frames = if shape.len() >= 2 { shape[shape.len() - 2] as usize } else { 0 };

    Ok(Enrolled { speaker_emb, codes, frames: code_frames })
}

/// Lấy mẫu lại tuyến tính — dùng cho đường lên 48 kHz, nơi bộ mã hoá codec
/// không nhạy với sai lệch nhỏ như bộ mã hoá giọng.
fn resample_linear(wav: &[f32], from: u32, to: u32) -> Vec<f32> {
    if from == to || wav.is_empty() {
        return wav.to_vec();
    }
    let ratio = to as f32 / from as f32;
    let out_len = (wav.len() as f32 * ratio) as usize;
    (0..out_len)
        .map(|i| {
            let at = i as f32 / ratio;
            let low = at.floor() as usize;
            let high = (low + 1).min(wav.len() - 1);
            let frac = at - low as f32;
            wav[low.min(wav.len() - 1)] * (1.0 - frac) + wav[high] * frac
        })
        .collect()
}
