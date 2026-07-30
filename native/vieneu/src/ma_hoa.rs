//! Nén âm thanh khi xuất file: WAV sang Opus hoặc MP3.
//!
//! Chỉ dựng cho máy tính. Android không kéo hai thư viện này vào (xem Cargo.toml)
//! vì hệ điều hành ở đó đã có MediaCodec.
//!
//! Vào là mẫu PCM 16-bit mono — đúng thứ mà phần xuất file đang ghi ra `.part`,
//! nên không phải đọc lại header WAV cho từng đoạn.

use std::io::Cursor;

use mp3lame_encoder::{Bitrate, Builder, FlushNoGap, MonoPcm};
use ogg::{PacketWriteEndInfo, PacketWriter};

/// Opus chỉ nhận khung có độ dài cố định. 20 ms ở 48 kHz là 960 mẫu — mức mà
/// mọi bộ giải mã đều hiểu và cũng là mức cân bằng nhất giữa độ trễ và hiệu quả.
const KHUNG_20MS: usize = 960;

/// Opus luôn chạy nội bộ ở 48 kHz, đúng bằng tần số mô hình sinh ra.
const OPUS_SR: u32 = 48_000;

/// Đọc mẫu PCM 16-bit mono từ một file WAV do chính ứng dụng ghi ra.
///
/// Không phải bộ đọc WAV tổng quát: chỉ tìm chunk `data` rồi đọc little-endian.
/// Trả về (mẫu, tần số lấy mẫu).
pub fn doc_wav_mono(bytes: &[u8]) -> Result<(Vec<i16>, u32), String> {
    if bytes.len() < 44 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err("không phải file WAV".into());
    }
    let mut sr = 0u32;
    let mut i = 12usize;
    while i + 8 <= bytes.len() {
        let ten = &bytes[i..i + 4];
        let co = u32::from_le_bytes([bytes[i + 4], bytes[i + 5], bytes[i + 6], bytes[i + 7]]) as usize;
        let than = i + 8;
        if ten == b"fmt " && than + 16 <= bytes.len() {
            sr = u32::from_le_bytes([
                bytes[than + 4],
                bytes[than + 5],
                bytes[than + 6],
                bytes[than + 7],
            ]);
        } else if ten == b"data" {
            let het = (than + co).min(bytes.len());
            let mau = bytes[than..het]
                .chunks_exact(2)
                .map(|c| i16::from_le_bytes([c[0], c[1]]))
                .collect();
            if sr == 0 {
                return Err("WAV thiếu chunk fmt".into());
            }
            return Ok((mau, sr));
        }
        // Chunk luôn căn theo số chẵn byte.
        i = than + co + (co & 1);
    }
    Err("WAV không có chunk data".into())
}

/// Nén sang MP3. [bitrate_kbps] nhận 64, 128, 192...
///
/// MP3 không cần container: các khung nối tiếp nhau là file hợp lệ, nên hàm này
/// đơn giản hơn hẳn phần Opus bên dưới.
pub fn wav_sang_mp3(pcm: &[i16], sr: u32, bitrate_kbps: u32) -> Result<Vec<u8>, String> {
    let mut dung = Builder::new().ok_or("không dựng được bộ mã hoá MP3")?;
    dung.set_num_channels(1).map_err(|e| format!("MP3 số kênh: {e}"))?;
    dung.set_sample_rate(sr).map_err(|e| format!("MP3 tần số {sr}: {e}"))?;
    dung.set_brate(bitrate_lame(bitrate_kbps)).map_err(|e| format!("MP3 bitrate: {e}"))?;
    // Chất lượng 2: gần như tốt nhất mà nhanh hơn mức 0 vài lần. Với giọng nói
    // thì khác biệt giữa 0 và 2 không nghe ra được.
    dung.set_quality(mp3lame_encoder::Quality::SecondBest)
        .map_err(|e| format!("MP3 quality: {e}"))?;

    let mut enc = dung.build().map_err(|e| format!("MP3 build: {e}"))?;
    let mut ra = Vec::with_capacity(mp3lame_encoder::max_required_buffer_size(pcm.len()));
    enc.encode_to_vec(MonoPcm(pcm), &mut ra)
        .map_err(|e| format!("MP3 encode: {e}"))?;
    enc.flush_to_vec::<FlushNoGap>(&mut ra)
        .map_err(|e| format!("MP3 flush: {e}"))?;
    Ok(ra)
}

fn bitrate_lame(kbps: u32) -> Bitrate {
    match kbps {
        0..=40 => Bitrate::Kbps32,
        41..=56 => Bitrate::Kbps48,
        57..=72 => Bitrate::Kbps64,
        73..=88 => Bitrate::Kbps80,
        89..=104 => Bitrate::Kbps96,
        105..=120 => Bitrate::Kbps112,
        121..=144 => Bitrate::Kbps128,
        145..=176 => Bitrate::Kbps160,
        177..=208 => Bitrate::Kbps192,
        _ => Bitrate::Kbps256,
    }
}

/// Nén sang Opus, đóng trong container Ogg. [bitrate_bps] ví dụ 32000, 64000.
///
/// Opus chỉ sinh ra từng khung nén, không tự dựng file; phần đóng gói Ogg phải
/// làm tay: hai trang đầu là OpusHead và OpusTags theo đặc tả RFC 7845, rồi mỗi
/// khung âm thanh một packet với granule position tính theo mẫu 48 kHz.
pub fn wav_sang_opus(pcm: &[i16], sr: u32, bitrate_bps: i32) -> Result<Vec<u8>, String> {
    if sr != OPUS_SR {
        return Err(format!("Opus cần 48 kHz, nhận {sr} Hz"));
    }
    use audiopus::{coder::Encoder, Application, Bitrate as OpusBitrate, Channels, SampleRate};

    let mut enc = Encoder::new(SampleRate::Hz48000, Channels::Mono, Application::Audio)
        .map_err(|e| format!("Opus new: {e}"))?;
    enc.set_bitrate(OpusBitrate::BitsPerSecond(bitrate_bps))
        .map_err(|e| format!("Opus bitrate: {e}"))?;

    // Bộ mã hoá cần một quãng "chạy đà" ở đầu; số mẫu đó phải khai trong
    // OpusHead để bộ giải mã bỏ đi, không thì file bị lệch đầu.
    let pre_skip: u16 = enc.lookahead().map(|v| v as u16).unwrap_or(312);

    let mut ra = Vec::new();
    let serial: u32 = 0x5361_6368; // "Sach" — chỉ cần khác nhau giữa các luồng
    {
        let mut w = PacketWriter::new(Cursor::new(&mut ra));

        w.write_packet(opus_head(1, pre_skip, OPUS_SR), serial, PacketWriteEndInfo::EndPage, 0)
            .map_err(|e| format!("Ogg OpusHead: {e}"))?;
        w.write_packet(opus_tags(), serial, PacketWriteEndInfo::EndPage, 0)
            .map_err(|e| format!("Ogg OpusTags: {e}"))?;

        let mut dem_mau = pre_skip as u64;
        let so_khung = (pcm.len() + KHUNG_20MS - 1) / KHUNG_20MS;
        let mut dem = [0u8; 4000];

        for k in 0..so_khung {
            let dau = k * KHUNG_20MS;
            let het = (dau + KHUNG_20MS).min(pcm.len());
            // Khung cuối thường thiếu mẫu: đệm số 0 cho đủ, vì Opus không nhận
            // khung ngắn hơn mức đã khai.
            let mut khung = [0i16; KHUNG_20MS];
            khung[..het - dau].copy_from_slice(&pcm[dau..het]);

            let n = enc
                .encode(&khung, &mut dem)
                .map_err(|e| format!("Opus encode khung {k}: {e}"))?;
            dem_mau += KHUNG_20MS as u64;

            let cuoi = k + 1 == so_khung;
            w.write_packet(
                dem[..n].to_vec(),
                serial,
                if cuoi { PacketWriteEndInfo::EndStream } else { PacketWriteEndInfo::NormalPacket },
                dem_mau,
            )
            .map_err(|e| format!("Ogg khung {k}: {e}"))?;
        }
    }
    Ok(ra)
}

/// Trang nhận dạng của Opus — 19 byte, đặc tả ở RFC 7845 mục 5.1.
fn opus_head(kenh: u8, pre_skip: u16, sr: u32) -> Vec<u8> {
    let mut v = Vec::with_capacity(19);
    v.extend_from_slice(b"OpusHead");
    v.push(1); // phiên bản
    v.push(kenh);
    v.extend_from_slice(&pre_skip.to_le_bytes());
    v.extend_from_slice(&sr.to_le_bytes()); // chỉ để ghi chú, giải mã vẫn ở 48 kHz
    v.extend_from_slice(&0i16.to_le_bytes()); // output gain
    v.push(0); // channel mapping family
    v
}

/// Trang chú thích. Bắt buộc phải có dù để trống, không thì file không hợp lệ.
fn opus_tags() -> Vec<u8> {
    const NHA: &[u8] = b"Sach luoi";
    let mut v = Vec::with_capacity(8 + 4 + NHA.len() + 4);
    v.extend_from_slice(b"OpusTags");
    v.extend_from_slice(&(NHA.len() as u32).to_le_bytes());
    v.extend_from_slice(NHA);
    v.extend_from_slice(&0u32.to_le_bytes()); // không có chú thích nào
    v
}

#[cfg(test)]
mod kiem_thu {
    use super::*;

    /// Một giây sóng sin 440 Hz — đủ để bộ mã hoá có việc thật mà làm.
    fn sin_mot_giay() -> Vec<i16> {
        (0..OPUS_SR as usize)
            .map(|i| {
                let t = i as f32 / OPUS_SR as f32;
                ((t * 440.0 * std::f32::consts::TAU).sin() * 12000.0) as i16
            })
            .collect()
    }

    #[test]
    fn opus_ra_file_ogg_hop_le() {
        let ra = wav_sang_opus(&sin_mot_giay(), OPUS_SR, 32_000).unwrap();
        assert_eq!(&ra[0..4], b"OggS", "phải bắt đầu bằng chữ ký Ogg");
        // Trang đầu chứa OpusHead, trang thứ hai chứa OpusTags.
        assert!(ra.windows(8).any(|w| w == b"OpusHead"));
        assert!(ra.windows(8).any(|w| w == b"OpusTags"));
        // Một giây ở 32 kbps là khoảng 4 KB; nới rộng biên cho chắc.
        assert!(ra.len() > 1500 && ra.len() < 12_000, "dài {} byte", ra.len());
    }

    #[test]
    fn mp3_ra_khung_hop_le() {
        let ra = wav_sang_mp3(&sin_mot_giay(), 48_000, 128).unwrap();
        // Khung MP3 mở đầu bằng 11 bit 1, có thể sau một khối ID3.
        let dau = if &ra[0..3] == b"ID3" { None } else { Some(&ra[0..2]) };
        if let Some(d) = dau {
            assert_eq!(d[0], 0xFF, "byte đầu của khung MP3");
            assert_eq!(d[1] & 0xE0, 0xE0, "11 bit đồng bộ");
        }
        // 128 kbps trong một giây là khoảng 16 KB.
        assert!(ra.len() > 8_000 && ra.len() < 30_000, "dài {} byte", ra.len());
    }

    #[test]
    fn doc_lai_wav_do_chinh_minh_ghi() {
        // Dựng một WAV 16-bit mono tối giản rồi đọc lại.
        let mau: Vec<i16> = vec![0, 100, -100, 32767, -32768];
        let than: Vec<u8> = mau.iter().flat_map(|s| s.to_le_bytes()).collect();
        let mut w = Vec::new();
        w.extend_from_slice(b"RIFF");
        w.extend_from_slice(&(36 + than.len() as u32).to_le_bytes());
        w.extend_from_slice(b"WAVEfmt ");
        w.extend_from_slice(&16u32.to_le_bytes());
        w.extend_from_slice(&1u16.to_le_bytes()); // PCM
        w.extend_from_slice(&1u16.to_le_bytes()); // mono
        w.extend_from_slice(&48_000u32.to_le_bytes());
        w.extend_from_slice(&96_000u32.to_le_bytes());
        w.extend_from_slice(&2u16.to_le_bytes());
        w.extend_from_slice(&16u16.to_le_bytes());
        w.extend_from_slice(b"data");
        w.extend_from_slice(&(than.len() as u32).to_le_bytes());
        w.extend_from_slice(&than);

        let (doc, sr) = doc_wav_mono(&w).unwrap();
        assert_eq!(sr, 48_000);
        assert_eq!(doc, mau);
    }

    #[test]
    fn bao_loi_ro_chu_khong_sap() {
        assert!(doc_wav_mono(b"khong phai wav").is_err());
        // Opus chỉ chạy ở 48 kHz; sai tần số thì phải nói ra.
        assert!(wav_sang_opus(&[0i16; 960], 22_050, 32_000).is_err());
    }
}
