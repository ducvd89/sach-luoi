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

// -- Lấy mẫu lại: cầu nối giữa engine 22 050 Hz và libopus --------------------

/// Bề rộng bộ lọc, đếm bằng số lần sinc cắt trục ở MỖI bên.
const LOC_SO_ZERO: usize = 32;

/// Chặn tần, tính theo Nyquist của đầu có tần số THẤP hơn trong hai đầu, và
/// cửa sổ Kaiser đi kèm. Đúng cặp số của `fbank.rs`, tức preset "kaiser_best"
/// mà resampy/torchaudio dùng — không nghĩ lại làm gì, nó đã được soi kỹ.
const LOC_CHAN_TAN: f64 = 0.947_593_716_739_959_6;
const LOC_BETA: f64 = 14.769_656_459_379_492;

/// Bảng hệ số đa pha: mỗi vị trí lẻ có thể gặp là một hàng hệ số dựng sẵn.
///
/// Số hàng là `dich / ƯCLN(sr, dich)` nên phụ thuộc vào việc hai tần số rút gọn
/// đẹp tới đâu: 22 050 → 48 000 cho 320 hàng (88 KB), 44 100 cho 160. Tần số
/// nguyên tố cùng nhau với 48 000 sẽ cho 48 000 hàng, cỡ 13 MB — không engine
/// nào ra kiểu tần số ấy, nhưng đây là lý do bảng dựng theo từng lần gọi chứ
/// không nằm thường trú.
struct BangDaPha {
    /// `so_pha` hàng nối tiếp nhau, mỗi hàng `so_tap` hệ số.
    he_so: Vec<f32>,
    so_tap: usize,
    /// Số pha = `dich / ƯCLN`, cũng là mẫu số của mọi vị trí lẻ gặp được.
    so_pha: u64,
    /// Bước = `sr / ƯCLN`: mẫu ra thứ `i` rơi vào vị trí `i * buoc / so_pha`
    /// trên lưới đầu vào.
    buoc: u64,
    /// Nửa bề rộng bộ lọc, đếm bằng mẫu ĐẦU VÀO.
    nua: usize,
}

fn uoc_chung_lon_nhat(mut a: u64, mut b: u64) -> u64 {
    while b != 0 {
        let du = a % b;
        a = b;
        b = du;
    }
    a
}

fn dung_bang_da_pha(sr: u32, dich: u32) -> BangDaPha {
    use std::f64::consts::PI;

    let uc = uoc_chung_lon_nhat(sr as u64, dich as u64);
    let so_pha = dich as u64 / uc;
    let buoc = sr as u64 / uc;

    // Hạ tần thì phải chặn dải theo Nyquist của đầu RA, không thì chồng phổ.
    let ti_le = dich as f64 / sr as f64;
    let chan_tan = LOC_CHAN_TAN * ti_le.min(1.0);
    // Cửa sổ trải theo bề rộng bộ lọc tính trên lưới đầu vào: chặn tần càng
    // thấp thì bộ lọc càng phải dài mới ôm đủ số lần sinc cắt trục.
    let nua_that = LOC_SO_ZERO as f64 / chan_tan;
    let nua = nua_that.ceil() as usize;
    let so_tap = 2 * nua + 1;

    let mau_so = crate::fbank::bessel_i0(LOC_BETA);
    let mut he_so = vec![0f32; so_pha as usize * so_tap];
    let mut hang = vec![0f64; so_tap];
    for pha in 0..so_pha as usize {
        let le = pha as f64 / so_pha as f64;
        let mut tong = 0f64;
        for (j, o) in hang.iter_mut().enumerate() {
            // Hệ số thứ j ăn vào mẫu vào cách tâm (j - nua) bước.
            let t = le - (j as f64 - nua as f64);
            let x = t * chan_tan;
            let sinc = if x.abs() < 1e-12 { 1.0 } else { (PI * x).sin() / (PI * x) };
            let r = t / nua_that;
            let cua_so = if r.abs() >= 1.0 {
                0.0
            } else {
                crate::fbank::bessel_i0(LOC_BETA * (1.0 - r * r).sqrt()) / mau_so
            };
            *o = sinc * cua_so;
            tong += *o;
        }
        // Chuẩn hoá từng pha về tổng 1: giữ đúng mức một chiều, và quan trọng
        // hơn là để mọi pha cùng độ lợi — lệch nhau thì ra tiếng ù tuần hoàn.
        for (j, &v) in hang.iter().enumerate() {
            he_so[pha * so_tap + j] = (v / tong) as f32;
        }
    }

    BangDaPha { he_so, so_tap, so_pha, buoc, nua }
}

/// Lấy mẫu lại PCM 16-bit mono sang [dich] Hz bằng nội suy windowed-sinc.
///
/// ## Vì sao không dùng lại `fbank::resample_to_16k`
///
/// Nó đúng là cùng một phép toán — sinc nhân cửa sổ Kaiser, cùng beta
/// 14,7697 — nhưng dựng cho một việc khác hẳn: gọt một đoạn ghi âm vài giây
/// lúc thêm giọng mới, chạy đúng một lần cho mỗi giọng. Nên nó tính lại cửa sổ
/// Kaiser (một chuỗi Bessel tới 50 số hạng) cho TỪNG hệ số của TỪNG mẫu ra.
/// Đường xuất file thì ngược lại: một part 30 phút ở 22 050 Hz là 86,4 triệu
/// mẫu ra, mỗi mẫu 135 hệ số — gần 12 tỉ lượt tính Bessel.
///
/// Mà tỉ số hai tần số luôn là số hữu tỉ: 22 050/48 000 rút gọn còn 147/320,
/// nên chỉ tồn tại đúng 320 vị trí lẻ khác nhau. Dựng bảng hệ số cho 320 pha ấy
/// một lần rồi tra là xong — 69 phép nhân cộng mỗi mẫu ra, không còn Bessel nào
/// trong vòng nóng. Đo bằng hai bản viết cùng ngôn ngữ, cùng kiểu vòng lặp:
/// **nhanh hơn 12,2 lần**, mà hai đầu ra lệch nhau nhiều nhất **8,3e-9** — đổi
/// cách tính chứ không đổi kết quả. Đó cũng là lý do không sửa `fbank.rs` cho
/// dùng chung: file ấy khớp torchaudio tới cosine 1,0000, đụng vào là mất chỗ
/// dựa ấy, mà đổi lại chẳng được gì.
///
/// Bề rộng thì cắt còn nửa của bản fbank (32 lần sinc cắt trục thay vì 64) sau
/// khi đo đáp ứng tần số của cả hai ở 22 050 → 48 000:
///
/// | | 32 lần (69 hệ số) | 64 lần (137 hệ số) |
/// |---|---|---|
/// | phẳng tới | 9,5 kHz (−0,06 dB) | 10 kHz (−0,09 dB) |
/// | ở 10 kHz | −1,22 dB | −0,09 dB |
/// | ảnh phổ cao nhất | dưới −50 dB | dưới −139 dB |
///
/// Chênh nhau chỉ ở mẩu 9,5–11 kHz, mà Opus 32 kbps mono cũng không giữ tới
/// đó. Đổi lại là một nửa công. Toàn cục thì sin 440 Hz nâng từ 22 050 lên
/// 48 000 cho SNR **82,5 dB** so với sóng sin lý tưởng ở 48 kHz, tức sai số
/// hiệu dụng 0,64 LSB — đã chạm trần của chính i16 chứ không phải trần bộ lọc.
///
/// Cạm bẫy: **phải chặn tràn.** Nâng tần số làm đỉnh nhô lên (Gibbs) — sin
/// 997 Hz biên độ đầy thang vọt tới 32 836, mà i16 tràn thì không méo nhẹ, nó
/// lật dấu thành tiếng nổ.
fn lay_mau_lai(pcm: &[i16], sr: u32, dich: u32) -> Vec<i16> {
    if sr == dich || pcm.is_empty() {
        return pcm.to_vec();
    }
    let bang = dung_bang_da_pha(sr, dich);
    let so_ra = (pcm.len() as u64 * dich as u64 / sr as u64) as usize;

    // Đệm 0 hai đầu để vòng trong khỏi phải kiểm biên từng hệ số. Đuôi thừa ra
    // một bộ hệ số vì mẫu ra cuối cùng vẫn còn với tới quá mẫu vào cuối cùng.
    let mut vao = vec![0f32; pcm.len() + 2 * bang.nua + bang.so_tap];
    for (i, &s) in pcm.iter().enumerate() {
        vao[bang.nua + i] = s as f32;
    }

    let mut ra = Vec::with_capacity(so_ra);
    for i in 0..so_ra as u64 {
        // u64 chứ không u32: một part 30 phút cho i tới 86 triệu, nhân với
        // bước 147 là vượt trần u32 từ lâu.
        let vi_tri = i * bang.buoc;
        let dau = (vi_tri / bang.so_pha) as usize;
        let pha = (vi_tri % bang.so_pha) as usize;
        let he = &bang.he_so[pha * bang.so_tap..(pha + 1) * bang.so_tap];
        let cua = &vao[dau..dau + bang.so_tap];
        let tong: f32 = cua.iter().zip(he).map(|(&a, &b)| a * b).sum();
        ra.push(tong.round().clamp(-32768.0, 32767.0) as i16);
    }
    ra
}

/// Năm tần số libopus nhận thẳng. Ngoài chúng thì [wav_sang_opus] lấy mẫu lại.
fn muc_libopus(sr: u32) -> Option<audiopus::SampleRate> {
    use audiopus::SampleRate;
    Some(match sr {
        8_000 => SampleRate::Hz8000,
        12_000 => SampleRate::Hz12000,
        16_000 => SampleRate::Hz16000,
        24_000 => SampleRate::Hz24000,
        48_000 => SampleRate::Hz48000,
        _ => return None,
    })
}

/// Nén sang Opus, đóng trong container Ogg. [bitrate_bps] ví dụ 32000, 64000.
///
/// Opus chỉ sinh ra từng khung nén, không tự dựng file; phần đóng gói Ogg phải
/// làm tay: hai trang đầu là OpusHead và OpusTags theo đặc tả RFC 7845, rồi mỗi
/// khung âm thanh một packet với granule position tính theo mẫu 48 kHz.
///
/// ## Tần số vào: nhận tất — năm mức thì nén thẳng, còn lại thì lấy mẫu lại
///
/// libopus nhận thẳng 8/12/16/24/48 kHz. Đưa 24 kHz của engine v2 vào thẳng còn
/// hơn nâng lên 48 kHz rồi mới nén: khỏi nội suy, khỏi tốn gấp đôi công.
///
/// Nhưng hai engine ra **22 050 Hz** (Piper và Matcha) thì không rơi vào mức
/// nào, và trước đây hàm này trả lỗi. Hậu quả không phải một dòng cảnh báo vô
/// hại: Opus 32 kbps là định dạng xuất **mặc định**, nên ai chọn một trong hai
/// engine ấy rồi xuất file đều nhận lại WAV kèm dòng "giữ nguyên WAV" — nặng
/// gấp khoảng 30 lần. Giờ những tần số ngoài năm mức được nâng lên 48 kHz bằng
/// [lay_mau_lai] trước khi nén.
///
/// Cạm bẫy: **đồng hồ của Ogg không đổi theo tần số vào.** `pre_skip` và
/// granule position luôn đếm bằng mẫu 48 kHz, nên phải nhân với
/// [OPUS_DONG_HO]`/sr` (24 kHz thì gấp đôi; sau khi lấy mẫu lại thì bằng 1).
/// Quên chỗ này thì file vẫn phát được nhưng mọi trình phát báo độ dài chỉ bằng
/// một nửa, và tua thì nhảy sai chỗ — hỏng lặng lẽ, không có lỗi nào bật ra.
pub fn wav_sang_opus(pcm: &[i16], sr: u32, bitrate_bps: i32) -> Result<Vec<u8>, String> {
    use audiopus::{coder::Encoder, Application, Bitrate as OpusBitrate, Channels};
    use std::borrow::Cow;

    if sr == 0 {
        return Err("WAV khai tần số lấy mẫu bằng 0".into());
    }
    // Chỉ sao chép khi thật sự phải lấy mẫu lại; ba engine kia đi thẳng.
    let (mau, sr_nen): (Cow<[i16]>, u32) = match muc_libopus(sr) {
        Some(_) => (Cow::Borrowed(pcm), sr),
        None => (Cow::Owned(lay_mau_lai(pcm, sr, OPUS_DONG_HO)), OPUS_DONG_HO),
    };
    let sr_vao = muc_libopus(sr_nen).expect("đã đưa về 48 kHz nếu không khớp mức nào");

    // Chia hết với cả năm mức trên, nên không mất mẫu nào vì làm tròn.
    let nhip = (OPUS_DONG_HO / sr_nen) as u64;
    let khung = khung_20ms(sr_nen);

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

        // Khai tần số GỐC chứ không phải tần số đã nén: RFC 7845 mục 5.1 định
        // nghĩa ô này là tần số của bản gốc và nói thẳng rằng bộ giải mã không
        // dùng nó để phát (Opus luôn giải ra 48 kHz). Giữ số gốc thì về sau còn
        // biết file đến từ engine nào.
        w.write_packet(opus_head(1, pre_skip, sr), serial, PacketWriteEndInfo::EndPage, 0)
            .map_err(|e| format!("Ogg OpusHead: {e}"))?;
        w.write_packet(opus_tags(), serial, PacketWriteEndInfo::EndPage, 0)
            .map_err(|e| format!("Ogg OpusTags: {e}"))?;

        let mut dem_mau = pre_skip as u64;
        let so_khung = mau.len().div_ceil(khung);
        let mut dem = [0u8; 4000];
        // Dựng một lần rồi dùng lại: một part 30 phút là gần 90 nghìn khung.
        let mut vao = vec![0i16; khung];

        for k in 0..so_khung {
            let dau = k * khung;
            let het = (dau + khung).min(mau.len());
            // Khung cuối thường thiếu mẫu: đệm số 0 cho đủ, vì Opus không nhận
            // khung ngắn hơn mức đã khai.
            vao[..het - dau].copy_from_slice(&mau[dau..het]);
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

    /// Một giây sóng sin [f] Hz biên độ [bien] ở tần số [sr], dựng bằng f64.
    ///
    /// Khác [sin_mot_giay_o] ở chỗ tính bằng f64. Bài đo SNR của bộ lấy mẫu lại
    /// lấy chính sóng sin lý tưởng làm mốc, mà f32 tới cuối giây đã lệch pha
    /// vài LSB — đủ để ăn mất mấy dB của thứ đang muốn đo.
    fn sin_chinh_xac(sr: u32, f: f64, bien: f64) -> Vec<i16> {
        (0..sr as usize)
            .map(|i| ((i as f64 / sr as f64 * f * std::f64::consts::TAU).sin() * bien) as i16)
            .collect()
    }

    /// Mức hiệu dụng — thước đo "có ra tiếng thật không".
    fn rms(v: &[i16]) -> f64 {
        (v.iter().map(|&s| (s as f64).powi(2)).sum::<f64>() / v.len() as f64).sqrt()
    }

    /// Số lần sóng cắt trục. Với sóng sin thuần thì đây là cao độ đo bằng cách
    /// rẻ nhất, và nó bắt được cả lỗi làm tiếng nhanh/chậm đi.
    fn doi_dau(v: &[i16]) -> usize {
        v.windows(2).filter(|w| (w[0] >= 0) != (w[1] >= 0)).count()
    }

    /// Biên độ của thành phần [f] Hz — một bước DFT tại đúng một tần số. Dùng
    /// để phân biệt cao độ đúng với cao độ mà một lỗi tỉ số sẽ đẻ ra.
    fn nang_luong_tai(mau: &[i16], f: f64, sr: f64) -> f64 {
        let (mut re, mut im) = (0f64, 0f64);
        for (i, &s) in mau.iter().enumerate() {
            let w = std::f64::consts::TAU * f * i as f64 / sr;
            re += s as f64 * w.cos();
            im -= s as f64 * w.sin();
        }
        (re * re + im * im).sqrt() / mau.len() as f64
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
        for sr in [16_000u32, 22_050, 24_000, 48_000] {
            let g = mot_giay(sr);
            assert!(
                (48_000..49_500).contains(&g),
                "{sr} Hz cho granule {g}, đáng lẽ quanh 48 000"
            );
        }
    }

    /// Bộ lấy mẫu lại phải giữ nguyên cao độ và mức âm, không chỉ giữ độ dài.
    ///
    /// Sai tỉ số thì độ dài lệch theo nên dễ thấy; sai *pha* của bảng hệ số thì
    /// độ dài vẫn đúng mà tiếng ù đi — nên soi thêm số lần đổi dấu và mức hiệu
    /// dụng, hai thứ mà một bảng hệ số hỏng không giữ được.
    #[test]
    fn lay_mau_lai_giu_cao_do_va_muc_am() {
        const SR: u32 = 22_050; // Piper và Matcha
        let goc = sin_chinh_xac(SR, 440.0, 12_000.0);
        let ra = lay_mau_lai(&goc, SR, 48_000);
        assert_eq!(ra.len(), 48_000, "một giây vào phải ra đúng một giây 48 kHz");

        // 440 Hz trong một giây là 880 lần đổi dấu; mẫu cuối cắt mất một lần
        // nên cả hai bên đều đếm được 879.
        assert_eq!(doi_dau(&ra), doi_dau(&goc), "cao độ phải giữ nguyên");

        let ti_le = rms(&ra) / rms(&goc);
        assert!((0.99..1.01).contains(&ti_le), "mức âm lệch: tỉ lệ {ti_le:.4}");

        // So với chính sóng sin lý tưởng ở 48 kHz. Đo được 82,5 dB — trần của
        // i16 chứ không phải của bộ lọc; lấy 70 dB làm lưới cho chắc.
        let bien = 12_000.0f64;
        let bo = 100; // hai đầu có phần bộ lọc thò ra ngoài dữ liệu
        let mut tong_loi = 0f64;
        let mut tong_tin = 0f64;
        for i in bo..ra.len() - bo {
            let ly_tuong = (i as f64 / 48_000.0 * 440.0 * std::f64::consts::TAU).sin() * bien;
            tong_loi += (ra[i] as f64 - ly_tuong).powi(2);
            tong_tin += ly_tuong.powi(2);
        }
        let snr = 10.0 * (tong_tin / tong_loi).log10();
        assert!(snr > 70.0, "SNR chỉ {snr:.1} dB");
    }

    /// Nâng tần số làm đỉnh nhô lên: sin đầy thang vọt tới 32 836, mà i16 tràn
    /// thì lật dấu thành tiếng nổ chứ không méo nhẹ.
    #[test]
    fn lay_mau_lai_chan_tran_i16() {
        const SR: u32 = 22_050;
        let goc = sin_chinh_xac(SR, 997.0, 32_767.0);
        let ra = lay_mau_lai(&goc, SR, 48_000);
        // Đo được 65 mẫu chạm trần; điều phải giữ là không mẫu nào lật dấu.
        assert_eq!(doi_dau(&ra), doi_dau(&goc), "tràn i16 sẽ đẻ ra lần đổi dấu lạ");
        let ti_le = rms(&ra) / rms(&goc);
        assert!((0.99..1.01).contains(&ti_le), "mức âm lệch: tỉ lệ {ti_le:.4}");
    }

    /// Đúng đường đi của Piper và Matcha: 22 050 Hz, không nằm trong năm mức
    /// libopus nhận.
    ///
    /// Trước đây hàm nén trả lỗi nên hai engine ấy không xuất được Opus bao
    /// giờ; mà Opus 32 kbps là định dạng mặc định, nên mọi file cuối rơi về WAV
    /// — nặng gấp khoảng 30 lần.
    ///
    /// Soi cả ruột chứ không chỉ cái vỏ: nén rồi giải lại rồi đo cao độ. Lấy
    /// nhầm tỉ số thì file vẫn đủ trang đủ mục, chỉ có tiếng là sai — 440 Hz
    /// hoá 958 Hz nếu quên lấy mẫu lại, hoá 202 Hz nếu lấy mẫu lại ngược chiều.
    #[test]
    fn opus_lay_mau_lai_tan_so_ngoai_nam_muc() {
        use audiopus::{coder::Decoder, Channels, SampleRate};
        use ogg::PacketReader;

        const SR: u32 = 22_050;
        let goc = sin_mot_giay_o(SR);
        let nen = wav_sang_opus(&goc, SR, 48_000).expect("22 050 Hz phải nén được");
        assert_eq!(&nen[0..4], b"OggS");

        // OpusHead giữ tần số GỐC: RFC 7845 mục 5.1 định nghĩa ô này là tần số
        // của bản gốc, không phải tần số đã đưa vào bộ mã hoá.
        let dau = nen.windows(8).position(|w| w == b"OpusHead").expect("thiếu OpusHead");
        let khai = u32::from_le_bytes(nen[dau + 12..dau + 16].try_into().unwrap());
        assert_eq!(khai, SR, "OpusHead phải ghi tần số gốc");

        // Một giây ở 48 kbps là khoảng 6 KB, không phải cỡ WAV.
        assert!(nen.len() > 2_000 && nen.len() < 20_000, "dài {} byte", nen.len());

        let mut doc = PacketReader::new(Cursor::new(&nen));
        let mut dec = Decoder::new(SampleRate::Hz48000, Channels::Mono).unwrap();
        let mut ra: Vec<i16> = Vec::new();
        let mut bo_qua_header = 2; // OpusHead và OpusTags không phải âm thanh
        while let Ok(Some(goi)) = doc.read_packet() {
            if bo_qua_header > 0 {
                bo_qua_header -= 1;
                continue;
            }
            let mut khung = vec![0i16; khung_20ms(48_000)];
            let n = dec.decode(Some(&goi.data), &mut khung[..], false).unwrap();
            ra.extend_from_slice(&khung[..n]);
        }

        // Một giây vào thì một giây ra — ở 48 kHz là 48 000 mẫu, không phải
        // 22 050 (quên nói cho bộ giải mã) cũng không phải 96 000 (nhân hai lần).
        let lech = (ra.len() as i64 - 48_000).abs();
        assert!(lech < 4_800, "giải ra {} mẫu, đáng lẽ quanh 48 000", ra.len());

        // Cao độ: 440 Hz phải áp đảo hai cao độ mà một lỗi tỉ số sẽ đẻ ra.
        let (dung, cao, thap) = (
            nang_luong_tai(&ra, 440.0, 48_000.0),
            nang_luong_tai(&ra, 958.0, 48_000.0),
            nang_luong_tai(&ra, 202.0, 48_000.0),
        );
        assert!(dung > cao * 5.0 && dung > thap * 5.0, "440 Hz {dung:.1}, 958 Hz {cao:.1}, 202 Hz {thap:.1}");

        // Còn ra tiếng thật: mức hiệu dụng xấp xỉ bản gốc.
        let ti_le = rms(&ra) / rms(&goc);
        assert!((0.7..1.3).contains(&ti_le), "mức âm gốc {}, giải ra {}", rms(&goc), rms(&ra));
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
        // Tần số bằng 0 thì không lấy mẫu lại được — phải nói ra chứ đừng chia
        // cho 0. Còn 22 050 Hz thì giờ chạy được, xem bài lấy mẫu lại ở trên.
        assert!(wav_sang_opus(&[0i16; 960], 0, 32_000).is_err());
    }
}
