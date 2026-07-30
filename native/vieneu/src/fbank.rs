//! Đặc trưng Kaldi fbank — đầu vào của bộ mã hoá giọng nói.
//!
//! Bản Python lấy hàm này từ torchaudio. Trên điện thoại không có torchaudio
//! nên phải dựng lại, và phải dựng cho *khớp từng con số*: sai một chi tiết thì
//! đặc trưng giọng lệch, giọng nhân bản ra nghe không giống mẫu, mà nhìn vào mã
//! nguồn thì chẳng thấy gì sai cả.
//!
//! Tham số lấy đúng mặc định của Kaldi mà bên Python đang dùng: khung 25 ms,
//! bước nhảy 10 ms, cửa sổ povey, tiền nhấn 0.97, bỏ lệch một chiều, 80 dải mel
//! từ 20 Hz tới Nyquist, không rung nhiễu.

use std::f32::consts::PI;

const SAMPLE_RATE: f32 = 16_000.0;
const FRAME_LENGTH_MS: f32 = 25.0;
const FRAME_SHIFT_MS: f32 = 10.0;
const PREEMPH: f32 = 0.97;
const LOW_FREQ: f32 = 20.0;
const N_MELS: usize = 80;

fn frame_length() -> usize {
    (SAMPLE_RATE * FRAME_LENGTH_MS / 1000.0) as usize // 400
}

fn frame_shift() -> usize {
    (SAMPLE_RATE * FRAME_SHIFT_MS / 1000.0) as usize // 160
}

/// Kaldi làm tròn độ dài FFT lên luỹ thừa của 2.
fn fft_size() -> usize {
    let mut n = 1;
    while n < frame_length() {
        n *= 2;
    }
    n // 512
}

/// Cửa sổ povey của Kaldi: hann mũ 0.85.
fn povey_window(n: usize) -> Vec<f32> {
    (0..n)
        .map(|i| {
            let a = 2.0 * PI / (n as f32 - 1.0);
            (0.5 - 0.5 * (a * i as f32).cos()).powf(0.85)
        })
        .collect()
}

fn hz_to_mel(hz: f32) -> f32 {
    1127.0 * (1.0 + hz / 700.0).ln()
}

fn mel_to_hz(mel: f32) -> f32 {
    700.0 * ((mel / 1127.0).exp() - 1.0)
}

/// Dàn lọc mel tam giác, dựng đúng cách Kaldi làm: mỗi dải là một tam giác trên
/// thang mel, tính theo tần số trung tâm của từng ô FFT.
fn mel_banks(n_fft: usize) -> Vec<Vec<f32>> {
    let n_bins = n_fft / 2; // Kaldi bỏ ô Nyquist
    let nyquist = SAMPLE_RATE / 2.0;
    let low_mel = hz_to_mel(LOW_FREQ);
    let high_mel = hz_to_mel(nyquist);
    let step = (high_mel - low_mel) / (N_MELS + 1) as f32;
    let fft_bin_width = SAMPLE_RATE / n_fft as f32;

    (0..N_MELS)
        .map(|bin| {
            let left = low_mel + bin as f32 * step;
            let center = left + step;
            let right = center + step;
            (0..n_bins)
                .map(|i| {
                    let mel = hz_to_mel(fft_bin_width * i as f32);
                    if mel <= left || mel >= right {
                        0.0
                    } else if mel <= center {
                        (mel - left) / (center - left)
                    } else {
                        (right - mel) / (right - center)
                    }
                })
                .collect()
        })
        .collect()
}

/// Biến đổi Fourier rời rạc kiểu chia đôi, đủ nhanh cho vài trăm khung.
fn fft(re: &mut [f32], im: &mut [f32]) {
    let n = re.len();
    if n <= 1 {
        return;
    }

    // Đảo bit thứ tự phần tử.
    let mut j = 0usize;
    for i in 1..n {
        let mut bit = n >> 1;
        while j & bit != 0 {
            j ^= bit;
            bit >>= 1;
        }
        j |= bit;
        if i < j {
            re.swap(i, j);
            im.swap(i, j);
        }
    }

    let mut len = 2;
    while len <= n {
        let angle = -2.0 * PI / len as f32;
        let (wr, wi) = (angle.cos(), angle.sin());
        let mut i = 0;
        while i < n {
            let (mut cr, mut ci) = (1.0f32, 0.0f32);
            for k in 0..len / 2 {
                let (ur, ui) = (re[i + k], im[i + k]);
                let (vr, vi) = (
                    re[i + k + len / 2] * cr - im[i + k + len / 2] * ci,
                    re[i + k + len / 2] * ci + im[i + k + len / 2] * cr,
                );
                re[i + k] = ur + vr;
                im[i + k] = ui + vi;
                re[i + k + len / 2] = ur - vr;
                im[i + k + len / 2] = ui - vi;
                let next = (cr * wr - ci * wi, cr * wi + ci * wr);
                cr = next.0;
                ci = next.1;
            }
            i += len;
        }
        len <<= 1;
    }
}

/// Tính fbank cho một đoạn tiếng nói 16 kHz mono.
///
/// Trả về ma trận (số khung, 80) đã trừ trung bình theo từng chiều — đúng thứ
/// mà bộ mã hoá giọng chờ nhận.
pub fn speaker_fbank(wav: &[f32]) -> Vec<f32> {
    let flen = frame_length();
    let fshift = frame_shift();
    if wav.len() < flen {
        return Vec::new();
    }

    let n_fft = fft_size();
    let n_bins = n_fft / 2;
    let window = povey_window(flen);
    let banks = mel_banks(n_fft);
    let frames = 1 + (wav.len() - flen) / fshift;

    let mut out = vec![0.0f32; frames * N_MELS];
    let mut re = vec![0.0f32; n_fft];
    let mut im = vec![0.0f32; n_fft];

    for f in 0..frames {
        let start = f * fshift;
        let slice = &wav[start..start + flen];

        // Bỏ lệch một chiều rồi tiền nhấn — đúng thứ tự của Kaldi.
        let mean = slice.iter().sum::<f32>() / flen as f32;
        let mut buf: Vec<f32> = slice.iter().map(|s| s - mean).collect();
        for i in (1..flen).rev() {
            buf[i] -= PREEMPH * buf[i - 1];
        }
        buf[0] -= PREEMPH * buf[0];

        re[..flen].copy_from_slice(&buf);
        for (i, w) in window.iter().enumerate() {
            re[i] *= *w;
        }
        re[flen..].fill(0.0);
        im.fill(0.0);
        fft(&mut re, &mut im);

        // Phổ công suất.
        let power: Vec<f32> = (0..n_bins).map(|i| re[i] * re[i] + im[i] * im[i]).collect();

        for (m, bank) in banks.iter().enumerate() {
            let mut sum = 0.0f32;
            for (i, w) in bank.iter().enumerate() {
                if *w != 0.0 {
                    sum += w * power[i];
                }
            }
            // Kaldi chặn sàn ở epsilon của float trước khi lấy log.
            out[f * N_MELS + m] = sum.max(f32::EPSILON).ln();
        }
    }

    // Trừ trung bình theo từng chiều (mean_norm của bản Python).
    for m in 0..N_MELS {
        let mut sum = 0.0f32;
        for f in 0..frames {
            sum += out[f * N_MELS + m];
        }
        let mean = sum / frames as f32;
        for f in 0..frames {
            out[f * N_MELS + m] -= mean;
        }
    }
    out
}

pub const MEL_BINS: usize = N_MELS;

/// Hàm Bessel biến dạng loại 1 bậc 0 — cần cho cửa sổ Kaiser.
fn bessel_i0(x: f64) -> f64 {
    let mut sum = 1.0;
    let mut term = 1.0;
    let half = x / 2.0;
    for k in 1..50 {
        term *= (half / k as f64) * (half / k as f64);
        sum += term;
        if term < sum * 1e-12 {
            break;
        }
    }
    sum
}

/// Lấy mẫu lại về 16 kHz, dựng theo đúng cách torchaudio làm.
///
/// Mẫu ghi âm thường là 44,1 kHz; bộ mã hoá giọng chỉ nhận 16 kHz. Thông số
/// (bề rộng 64, chặn tần 0,95, cửa sổ Kaiser beta 14,77) lấy đúng của
/// `sinc_interp_kaiser` bên torchaudio — dùng bộ lọc khác thì đặc trưng giọng
/// trích ra lệch đi, giọng nhân bản nghe không giống mẫu.
pub fn resample_to_16k(wav: &[f32], from_rate: u32) -> Vec<f32> {
    if from_rate == SAMPLE_RATE as u32 || wav.is_empty() {
        return wav.to_vec();
    }
    const WIDTH: i32 = 64;
    const ROLLOFF: f64 = 0.95;
    const BETA: f64 = 14.769_656_459_379_492;

    let ratio = SAMPLE_RATE as f64 / from_rate as f64;
    let out_len = (wav.len() as f64 * ratio) as usize;
    // Khi hạ tần số, phải chặn dải theo tần số đích để không bị chồng phổ.
    let cutoff = ROLLOFF * ratio.min(1.0);
    // Cửa sổ trải theo bề rộng bộ lọc tính trên lưới đầu vào.
    let half = WIDTH as f64 / cutoff.min(1.0);
    let denom = bessel_i0(BETA);

    (0..out_len)
        .map(|i| {
            let center = i as f64 / ratio;
            let first = (center - half).ceil() as i64;
            let last = (center + half).floor() as i64;
            let mut sum = 0.0f64;
            let mut norm = 0.0f64;

            for idx in first..=last {
                if idx < 0 || idx as usize >= wav.len() {
                    continue;
                }
                let t = center - idx as f64;
                let x = t * cutoff;
                let sinc = if x.abs() < 1e-9 { 1.0 } else { (PI as f64 * x).sin() / (PI as f64 * x) };

                let ratio_in_window = t / half;
                if ratio_in_window.abs() >= 1.0 {
                    continue;
                }
                let w = bessel_i0(BETA * (1.0 - ratio_in_window * ratio_in_window).sqrt()) / denom;

                sum += wav[idx as usize] as f64 * sinc * w;
                norm += sinc * w;
            }
            if norm.abs() > 1e-9 { (sum / norm) as f32 } else { 0.0 }
        })
        .collect()
}
