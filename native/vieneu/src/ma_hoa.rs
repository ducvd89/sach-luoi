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

/// Đồng hồ của Ogg/Opus: granule position và pre-skip LUÔN đếm theo mẫu 48 kHz
/// dù âm thanh vào ở tần số nào (RFC 7845 mục 4). Đây không phải tần số của
/// tín hiệu — xem [wav_sang_opus].
const OPUS_DONG_HO: u32 = 48_000;

/// Opus chỉ nhận khung có độ dài cố định. Lấy 20 ms — mức mà mọi bộ giải mã đều
/// hiểu và cũng là mức cân bằng nhất giữa độ trễ và hiệu quả. Ở 48 kHz là 960
/// mẫu, ở 24 kHz là 480.
fn khung_20ms(sr: u32) -> usize {
    (sr / 50) as usize
}

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

/// Nén sang AAC-LC, đóng khung ADTS (`.aac`) — mỗi khung tự mang đủ thông tin
/// để phát, không cần bảng mục lục kiểu MP4 nên ghép file cũng đơn giản như MP3.
///
/// Bộ mã hoá thuần Rust (rusty_aac), không FFI/thư viện C nào — không phải lo
/// cross-compile như Opus hay MP3, và theo tài liệu của thư viện thì còn nhanh
/// hơn hẳn (~450 lần thời gian thực).
pub fn wav_sang_aac(pcm: &[i16], sr: u32, bitrate_bps: u32) -> Result<Vec<u8>, String> {
    use rusty_aac::{AacEncoder, AacEncoderConfig, AdtsHeader};

    let mau: Vec<f32> = pcm.iter().map(|&s| s as f32 / 32768.0).collect();
    let mut enc = AacEncoder::new(AacEncoderConfig { bitrate_bps });
    enc.push_pcm(&mau, 1, sr)
        .map_err(|e| format!("AAC push (tần số {sr} Hz): {e}"))?;
    enc.finish();

    let mut ra = Vec::new();
    loop {
        match enc.next_packet() {
            Ok(goi) => {
                // 7 byte header + thân khung, không CRC — protection_absent=1.
                let header = rusty_aac::write_adts_header(&AdtsHeader {
                    object_type: 2, // AAC-LC
                    sample_rate: sr,
                    channels: 1,
                    frame_length: goi.data.len() + 7,
                    header_len: 7,
                });
                ra.extend_from_slice(&header);
                ra.extend_from_slice(&goi.data);
            }
            Err(rusty_aac::Error::Eof) => break,
            Err(e) => return Err(format!("AAC encode: {e}")),
        }
    }
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
///
/// ## Tần số vào: nhận thẳng cả năm mức của libopus
///
/// Trước đây hàm này đòi đúng 48 kHz, nên **engine VieNeu v2 không xuất được
/// Opus**: NeuCodec dựng ra 24 kHz (xem `v2.rs`) nên mọi file cuối đều rơi về
/// WAV kèm dòng "Opus cần 48 kHz, nhận 24000 Hz". Đòi hỏi ấy sai: libopus nhận
/// thẳng 8/12/16/24/48 kHz, chỉ những tần số NGOÀI năm mức đó mới phải lấy mẫu
/// lại. Đọc 24 kHz thẳng còn hơn nâng lên 48 kHz rồi mới nén — khỏi nội suy,
/// khỏi tốn gấp đôi công.
///
/// Cạm bẫy: **đồng hồ của Ogg không đổi theo tần số vào.** `pre_skip` và
/// granule position luôn đếm bằng mẫu 48 kHz, nên phải nhân với
/// [OPUS_DONG_HO]`/sr` (24 kHz thì gấp đôi). Quên chỗ này thì file vẫn phát
/// được nhưng mọi trình phát báo độ dài chỉ bằng một nửa, và tua thì nhảy sai
/// chỗ — hỏng lặng lẽ, không có lỗi nào bật ra.
pub fn wav_sang_opus(pcm: &[i16], sr: u32, bitrate_bps: i32) -> Result<Vec<u8>, String> {
    use audiopus::{coder::Encoder, Application, Bitrate as OpusBitrate, Channels, SampleRate};

    let sr_vao = match sr {
        8_000 => SampleRate::Hz8000,
        12_000 => SampleRate::Hz12000,
        16_000 => SampleRate::Hz16000,
        24_000 => SampleRate::Hz24000,
        48_000 => SampleRate::Hz48000,
        _ => return Err(format!("Opus nhận 8/12/16/24/48 kHz, không nhận {sr} Hz")),
    };
    // Chia hết với cả năm mức trên, nên không mất mẫu nào vì làm tròn.
    let nhip = (OPUS_DONG_HO / sr) as u64;
    let khung = khung_20ms(sr);

    let mut enc = Encoder::new(sr_vao, Channels::Mono, Application::Audio)
        .map_err(|e| format!("Opus new: {e}"))?;
    enc.set_bitrate(OpusBitrate::BitsPerSecond(bitrate_bps))
        .map_err(|e| format!("Opus bitrate: {e}"))?;

    // Bộ mã hoá cần một quãng "chạy đà" ở đầu; số mẫu đó phải khai trong
    // OpusHead để bộ giải mã bỏ đi, không thì file bị lệch đầu. libopus trả về
    // theo tần số VÀO, còn OpusHead khai theo đồng hồ 48 kHz.
    let pre_skip: u16 = enc
        .lookahead()
        .map(|v| (v as u64 * nhip) as u16)
        .unwrap_or(312);

    let mut ra = Vec::new();
    let serial: u32 = 0x5361_6368; // "Sach" — chỉ cần khác nhau giữa các luồng
    {
        let mut w = PacketWriter::new(Cursor::new(&mut ra));

        w.write_packet(opus_head(1, pre_skip, sr), serial, PacketWriteEndInfo::EndPage, 0)
            .map_err(|e| format!("Ogg OpusHead: {e}"))?;
        w.write_packet(opus_tags(), serial, PacketWriteEndInfo::EndPage, 0)
            .map_err(|e| format!("Ogg OpusTags: {e}"))?;

        let mut dem_mau = pre_skip as u64;
        let so_khung = pcm.len().div_ceil(khung);
        let mut dem = [0u8; 4000];
        // Dựng một lần rồi dùng lại: một part 30 phút là gần 90 nghìn khung.
        let mut vao = vec![0i16; khung];

        for k in 0..so_khung {
            let dau = k * khung;
            let het = (dau + khung).min(pcm.len());
            // Khung cuối thường thiếu mẫu: đệm số 0 cho đủ, vì Opus không nhận
            // khung ngắn hơn mức đã khai.
            vao[..het - dau].copy_from_slice(&pcm[dau..het]);
            vao[het - dau..].fill(0);

            let n = enc
                .encode(&vao, &mut dem)
                .map_err(|e| format!("Opus encode khung {k}: {e}"))?;
            dem_mau += khung as u64 * nhip;

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

    /// Một giây sóng sin 440 Hz ở tần số [sr] — đủ để bộ mã hoá có việc thật.
    fn sin_mot_giay_o(sr: u32) -> Vec<i16> {
        (0..sr as usize)
            .map(|i| {
                let t = i as f32 / sr as f32;
                ((t * 440.0 * std::f32::consts::TAU).sin() * 12000.0) as i16
            })
            .collect()
    }

    fn sin_mot_giay() -> Vec<i16> {
        sin_mot_giay_o(48_000)
    }

    #[test]
    fn opus_ra_file_ogg_hop_le() {
        let ra = wav_sang_opus(&sin_mot_giay(), 48_000, 32_000).unwrap();
        assert_eq!(&ra[0..4], b"OggS", "phải bắt đầu bằng chữ ký Ogg");
        // Trang đầu chứa OpusHead, trang thứ hai chứa OpusTags.
        assert!(ra.windows(8).any(|w| w == b"OpusHead"));
        assert!(ra.windows(8).any(|w| w == b"OpusTags"));
        // Một giây ở 32 kbps là khoảng 4 KB; nới rộng biên cho chắc.
        assert!(ra.len() > 1500 && ra.len() < 12_000, "dài {} byte", ra.len());
    }

    /// Đúng đường đi của engine VieNeu v2: NeuCodec dựng 24 kHz.
    ///
    /// Trước đây hàm nén trả lỗi "Opus cần 48 kHz" nên v2 không xuất được Opus
    /// bao giờ, mọi file cuối đều rơi về WAV.
    #[test]
    fn opus_nhan_ca_nam_tan_so_cua_libopus() {
        for sr in [8_000u32, 12_000, 16_000, 24_000, 48_000] {
            let ra = wav_sang_opus(&sin_mot_giay_o(sr), sr, 32_000)
                .unwrap_or_else(|e| panic!("{sr} Hz: {e}"));
            assert_eq!(&ra[0..4], b"OggS", "{sr} Hz phải ra Ogg");
            assert!(ra.windows(8).any(|w| w == b"OpusHead"), "{sr} Hz thiếu OpusHead");

            // OpusHead khai lại đúng tần số vào (RFC 7845 mục 5.1, byte 12..16).
            let dau = ra.windows(8).position(|w| w == b"OpusHead").unwrap();
            let khai = u32::from_le_bytes(ra[dau + 12..dau + 16].try_into().unwrap());
            assert_eq!(khai, sr, "OpusHead phải ghi tần số vào thật");

            // Một giây ở 32 kbps là khoảng 4 KB, không phụ thuộc tần số vào.
            assert!(ra.len() > 1500 && ra.len() < 12_000, "{sr} Hz dài {} byte", ra.len());
        }
    }

    /// Nén rồi giải nén lại: âm thanh 24 kHz phải ra đúng âm thanh 24 kHz.
    ///
    /// Bài trên chỉ soi vỏ Ogg, bài này soi ruột. Khai sai tần số cho bộ mã hoá
    /// thì file vẫn đủ trang đủ mục, chỉ có tiếng là nhanh gấp đôi hoặc chậm một
    /// nửa — thứ mà chỉ mở ra nghe mới biết.
    #[test]
    fn nen_roi_giai_lai_ra_dung_do_dai_va_dung_muc_am() {
        use audiopus::{coder::Decoder, Channels, SampleRate};
        use ogg::PacketReader;

        const SR: u32 = 24_000;
        let goc = sin_mot_giay_o(SR);
        let nen = wav_sang_opus(&goc, SR, 48_000).unwrap();

        let mut doc = PacketReader::new(Cursor::new(&nen));
        let mut dec = Decoder::new(SampleRate::Hz24000, Channels::Mono).unwrap();
        let mut ra: Vec<i16> = Vec::new();
        let mut bo_qua_header = 2; // OpusHead và OpusTags không phải âm thanh
        while let Ok(Some(goi)) = doc.read_packet() {
            if bo_qua_header > 0 {
                bo_qua_header -= 1;
                continue;
            }
            let mut khung = vec![0i16; khung_20ms(SR)];
            let n = dec.decode(Some(&goi.data), &mut khung[..], false).unwrap();
            ra.extend_from_slice(&khung[..n]);
        }

        // Một giây vào thì một giây ra, sai lệch chỉ ở phần chạy đà và khung
        // cuối được đệm — không được là nửa hay gấp đôi.
        let lech = (ra.len() as i64 - goc.len() as i64).abs();
        assert!(
            lech < SR as i64 / 10,
            "giải ra {} mẫu, vào {} mẫu — lệch quá xa",
            ra.len(),
            goc.len()
        );

        // Còn ra tiếng thật chứ không phải im lặng hay nhiễu: mức hiệu dụng
        // phải xấp xỉ bản gốc (sin biên độ 12000 -> RMS ~8500).
        let rms = |v: &[i16]| (v.iter().map(|&s| (s as f64).powi(2)).sum::<f64>() / v.len() as f64).sqrt();
        let (a, b) = (rms(&goc), rms(&ra));
        assert!(b > a * 0.7 && b < a * 1.3, "mức âm gốc {a:.0}, giải ra {b:.0}");
    }

    /// Đồng hồ của Ogg luôn là 48 kHz dù âm thanh vào ở tần số nào.
    ///
    /// Đây là chỗ hỏng lặng lẽ nhất: quên nhân nhịp thì file 24 kHz vẫn phát
    /// được, chỉ là trình phát báo độ dài bằng nửa thật và tua thì nhảy sai.
    #[test]
    fn granule_dem_theo_dong_ho_48k_chu_khong_theo_tan_so_vao() {
        let mot_giay = |sr: u32| -> u64 {
            let ra = wav_sang_opus(&sin_mot_giay_o(sr), sr, 32_000).unwrap();
            // Granule của trang cuối = tổng số mẫu 48 kHz, nằm ở byte 6..14 của
            // trang Ogg cuối cùng.
            let cuoi = (0..ra.len() - 4)
                .rev()
                .find(|&i| &ra[i..i + 4] == b"OggS")
                .expect("phải có trang Ogg");
            u64::from_le_bytes(ra[cuoi + 6..cuoi + 14].try_into().unwrap())
        };
        // Một giây âm thanh là ~48 000 mẫu ở đồng hồ 48 kHz, dù vào ở tần số
        // nào — cộng thêm pre-skip và phần đệm của khung cuối.
        for sr in [16_000u32, 24_000, 48_000] {
            let g = mot_giay(sr);
            assert!(
                (48_000..49_500).contains(&g),
                "{sr} Hz cho granule {g}, đáng lẽ quanh 48 000"
            );
        }
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
    fn aac_ra_khung_adts_hop_le() {
        let ra = wav_sang_aac(&sin_mot_giay(), 48_000, 96_000).unwrap();
        // Chữ ký ADTS: 12 bit đồng bộ (0xFFF) rồi layer = 00.
        assert_eq!(ra[0], 0xFF, "byte đầu của khung ADTS");
        assert_eq!(ra[1] & 0xF6, 0xF0, "12 bit đồng bộ + layer");
        // 96 kbps trong một giây là khoảng 12 KB.
        assert!(ra.len() > 6_000 && ra.len() < 24_000, "dài {} byte", ra.len());
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
        // 22 050 Hz (giọng Piper) không nằm trong năm mức libopus nhận, mà ở
        // đây chưa có bộ lấy mẫu lại — phải nói ra chứ đừng ghi file hỏng.
        assert!(wav_sang_opus(&[0i16; 960], 22_050, 32_000).is_err());
    }
}
