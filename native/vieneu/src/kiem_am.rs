//! Đếm nhân âm bằng wav2vec2 nhận dạng âm vị tiếng Việt, không tìm đỉnh sóng.
//!
//! CTC phải gộp mã lặp TRƯỚC khi bỏ blank: a, blank, a là hai âm. Nguyên âm
//! đôi có thanh điệu là một nhãn, còn bán nguyên âm cuối (iz, uz) không có
//! thanh điệu. Đếm các nhãn nguyên âm có thanh là đếm âm tiết, không đếm chữ.
//! Cửa sổ có phần chồng để âm vắt qua biên vẫn có ngữ cảnh; ghép mã từng KHUNG
//! rồi mới giải CTC một lần, không ghép các danh sách âm đã giải riêng.

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_float};
use std::path::Path;
use std::ptr;

use ndarray::Array2;
use ort::session::{Session, builder::GraphOptimizationLevel};
use ort::value::Value;
use serde::{Deserialize, Serialize};

const TAN_SO: usize = 16_000;
const BUOC: usize = 320;
const TRUONG_NHIN: usize = 400;
const KHUNG_LOI: usize = 300; // 6 giây giữ lại mỗi lượt.
const KHUNG_CHONG: usize = 50; // 1 giây ngữ cảnh mỗi bên, tổng cửa sổ ~8 giây.

#[derive(Deserialize)]
struct BangAmVi {
    blank_token_id: usize,
    sampling_rate: usize,
    labels: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct KetQuaNhanAm {
    #[serde(rename = "soAm")]
    pub so_am: usize,
    #[serde(rename = "amVi")]
    pub am_vi: Vec<String>,
}

pub struct BoKiemAm {
    phien: Session,
    bang: BangAmVi,
}

impl BoKiemAm {
    pub fn mo(thu_muc: &Path) -> Result<Self, String> {
        let bang: BangAmVi = serde_json::from_slice(
            &std::fs::read(thu_muc.join("phonemes.json")).map_err(|e| e.to_string())?,
        )
        .map_err(|e| format!("bảng âm vị không hợp lệ: {e}"))?;
        if bang.sampling_rate != TAN_SO
            || bang.blank_token_id != 0
            || bang.labels.len() != 123
            || bang.labels[0] != "<pad>"
            || !bang.labels.iter().any(|s| la_nhan_am(s))
        {
            return Err("cần đúng bảng 123 âm vị của wav2vec2-vi-phone".into());
        }
        let phien = Session::builder()
            .map_err(|e| e.to_string())?
            .with_optimization_level(GraphOptimizationLevel::Level3)
            .map_err(|e| e.to_string())?
            .with_intra_threads(2)
            .map_err(|e| e.to_string())?
            .commit_from_file(thu_muc.join("model_quantized.onnx"))
            .map_err(|e| e.to_string())?;
        Ok(Self { phien, bang })
    }

    /// [nhip_cao_do] chỉ khác 1 nếu TTS đã đổi tốc độ bằng lấy mẫu lại. Hạ tần
    /// số khai báo để khôi phục cao độ gốc trước khi nhận dạng; Matcha giữ 1.
    pub fn kiem_file(
        &mut self,
        duong_dan: &Path,
        nhip_cao_do: f32,
    ) -> Result<KetQuaNhanAm, String> {
        if std::fs::metadata(duong_dan)
            .map_err(|e| e.to_string())?
            .len()
            > 100_000_000
        {
            return Err("file kiểm âm vượt 100 MB; cần kiểm từng đoạn".into());
        }
        let (mau, tan_so) = crate::enroll::read_wav(duong_dan)?;
        self.kiem_mau(&mau, tan_so, nhip_cao_do)
    }

    pub fn kiem_mau(
        &mut self,
        mau: &[f32],
        tan_so: u32,
        nhip_cao_do: f32,
    ) -> Result<KetQuaNhanAm, String> {
        if !(4_000..=192_000).contains(&tan_so)
            || !nhip_cao_do.is_finite()
            || !(0.25..=4.0).contains(&nhip_cao_do)
            || mau.iter().any(|x| !x.is_finite())
        {
            return Err("tần số, tốc độ hoặc mẫu WAV không hợp lệ".into());
        }
        let tan_so_goc = (tan_so as f32 / nhip_cao_do).round() as u32;
        if mau.len() as f64 / tan_so_goc as f64 > 180.0 {
            return Err("đoạn kiểm âm dài quá 180 giây".into());
        }
        if mau.is_empty() {
            return Ok(KetQuaNhanAm {
                so_am: 0,
                am_vi: vec![],
            });
        }
        let mut mau = crate::fbank::resample_to_16k(mau, tan_so_goc);
        // Mạng tích chập cần ít nhất 400 mẫu. Đệm đoạn cực ngắn, không cắt mất.
        mau.resize(mau.len().max(TRUONG_NHIN), 0.0);
        let so_khung = (mau.len() - TRUONG_NHIN) / BUOC + 1;
        let mut ma_khung = Vec::with_capacity(so_khung);
        for (dau, cuoi, lay_tu, lay_den) in cac_cua_so(so_khung) {
            let mut cua_so = mau[dau * BUOC..cuoi * BUOC + TRUONG_NHIN - BUOC].to_vec();
            chuan_hoa(&mut cua_so);
            let vao =
                Array2::from_shape_vec((1, cua_so.len()), cua_so).map_err(|e| e.to_string())?;
            let ra = self
                .phien
                .run(ort::inputs![
                    "input_values" => Value::from_array(vao).map_err(|e| e.to_string())?
                ])
                .map_err(|e| format!("wav2vec2: {e}"))?;
            let logits = ra.get("logits").ok_or("mô hình thiếu đầu ra logits")?;
            let (kich_thuoc, diem) = logits
                .try_extract_tensor::<f32>()
                .map_err(|e| e.to_string())?;
            let so_nhan = self.bang.labels.len();
            if kich_thuoc.as_ref() != [1, (cuoi - dau) as i64, so_nhan as i64] {
                return Err(format!("kích thước logits không đúng: {kich_thuoc:?}"));
            }
            for khung in lay_tu..lay_den {
                let hang = &diem[khung * so_nhan..(khung + 1) * so_nhan];
                if hang.iter().any(|v| !v.is_finite()) {
                    return Err("logits chứa NaN/Inf".into());
                }
                let ma = hang
                    .iter()
                    .enumerate()
                    .max_by(|a, b| a.1.total_cmp(b.1))
                    .unwrap()
                    .0;
                ma_khung.push(ma);
            }
        }
        let am_vi = giai_ctc(&ma_khung, &self.bang.labels, self.bang.blank_token_id);
        Ok(KetQuaNhanAm {
            so_am: am_vi.iter().filter(|s| la_nhan_am(s)).count(),
            am_vi,
        })
    }
}

/// Tất cả chỉ số đều theo lưới khung 20 ms, tránh đếm đôi hoặc bỏ khung ở biên.
fn cac_cua_so(so_khung: usize) -> Vec<(usize, usize, usize, usize)> {
    (0..so_khung)
        .step_by(KHUNG_LOI)
        .map(|loi| {
            let het_loi = (loi + KHUNG_LOI).min(so_khung);
            let dau = loi.saturating_sub(KHUNG_CHONG);
            let cuoi = (het_loi + KHUNG_CHONG).min(so_khung);
            (dau, cuoi, loi - dau, het_loi - dau)
        })
        .collect()
}

fn chuan_hoa(mau: &mut [f32]) {
    let trung_binh = mau.iter().map(|x| *x as f64).sum::<f64>() / mau.len() as f64;
    let phuong_sai = mau
        .iter()
        .map(|x| (*x as f64 - trung_binh).powi(2))
        .sum::<f64>()
        / mau.len() as f64;
    let chia = (phuong_sai + 1e-7).sqrt();
    for x in mau {
        *x = ((*x as f64 - trung_binh) / chia) as f32;
    }
}

fn giai_ctc(ma: &[usize], nhan: &[String], blank: usize) -> Vec<String> {
    ma.iter()
        .enumerate()
        .filter_map(|(i, &m)| {
            if m == blank || (i > 0 && m == ma[i - 1]) {
                None
            } else {
                Some(nhan[m].clone())
            }
        })
        .collect()
}

fn la_nhan_am(nhan: &str) -> bool {
    let Some((nguyen_am, thanh)) = nhan.rsplit_once('-') else {
        return false;
    };
    matches!(thanh, "0" | "1" | "2" | "3" | "4" | "5")
        && matches!(
            nguyen_am,
            "a" | "aː"
                | "e"
                | "eaː"
                | "i"
                | "iə"
                | "o"
                | "u"
                | "uə"
                | "ɔ"
                | "ə"
                | "əː"
                | "ɛ"
                | "ɨ"
                | "ɨə"
        )
}

// Cổng C: mọi chuỗi kết quả/lỗi đều do vieneu_string_free trả lại bộ cấp phát.
fn chuoi_c(noi_dung: String) -> *mut c_char {
    CString::new(noi_dung).unwrap_or_default().into_raw()
}
unsafe fn doc_chuoi<'a>(con_tro: *const c_char) -> Result<&'a str, String> {
    if con_tro.is_null() {
        return Err("thiếu đường dẫn".into());
    }
    unsafe { CStr::from_ptr(con_tro) }
        .to_str()
        .map_err(|e| e.to_string())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn kiem_am_mo(
    thu_muc: *const c_char,
    loi: *mut *mut c_char,
) -> *mut BoKiemAm {
    if !loi.is_null() {
        unsafe {
            *loi = ptr::null_mut();
        }
    }
    let ket = std::panic::catch_unwind(|| {
        let thu_muc = unsafe { doc_chuoi(thu_muc) }?;
        BoKiemAm::mo(Path::new(thu_muc))
    })
    .unwrap_or_else(|_| Err("wav2vec2 gặp lỗi nội bộ khi nạp".into()));
    match ket {
        Ok(bo) => Box::into_raw(Box::new(bo)),
        Err(e) => {
            if !loi.is_null() {
                unsafe {
                    *loi = chuoi_c(e);
                }
            }
            ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn kiem_am_nhan(
    bo: *mut BoKiemAm,
    wav: *const c_char,
    nhip: c_float,
) -> *mut c_char {
    let ket = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let bo = unsafe { bo.as_mut() }.ok_or("bộ kiểm âm đã đóng")?;
        let wav = unsafe { doc_chuoi(wav) }?;
        bo.kiem_file(Path::new(wav), nhip)
    }))
    .unwrap_or_else(|_| Err("wav2vec2 gặp lỗi nội bộ khi nhận dạng".into()));
    chuoi_c(match ket {
        Ok(ra) => serde_json::to_string(&ra).unwrap(),
        Err(e) => serde_json::json!({"loi": e}).to_string(),
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn kiem_am_dong(bo: *mut BoKiemAm) {
    if !bo.is_null() {
        drop(unsafe { Box::from_raw(bo) });
    }
}

#[cfg(test)]
mod thu {
    use super::*;

    #[test]
    fn ctc_giu_hai_am_giong_nhau_cach_boi_blank() {
        let nhan = ["<pad>", "a-0", "t", "iə-3"].map(String::from);
        assert_eq!(
            giai_ctc(&[0, 1, 1, 0, 1, 2, 2, 3, 3, 0], &nhan, 0),
            ["a-0", "a-0", "t", "iə-3"]
        );
        assert!(giai_ctc(&[0, 0, 0], &nhan, 0).is_empty());
    }

    #[test]
    fn nguyen_am_doi_mot_am_ban_nguyen_am_khong_dem() {
        for nhan in ["iə-3", "aː-5", "ɨə-0", "eaː-1"] {
            assert!(la_nhan_am(nhan));
        }
        for nhan in ["iz", "uz", "w", "kz", "<pad>", "n-0", "a-6"] {
            assert!(!la_nhan_am(nhan));
        }
    }

    #[test]
    fn cua_so_phu_het_khung_khong_lap_khong_thieu() {
        for so in [1, 299, 300, 301, 350, 351, 600, 601, 1499] {
            let mut khung = vec![];
            for (dau, cuoi, tu, den) in cac_cua_so(so) {
                assert!(cuoi - dau <= KHUNG_LOI + KHUNG_CHONG * 2);
                assert!(den <= cuoi - dau);
                khung.extend(dau + tu..dau + den);
            }
            assert_eq!(khung, (0..so).collect::<Vec<_>>());
        }
    }

    #[test]
    fn chuan_hoa_khop_quy_uoc_wav2vec2() {
        let mut mau = [2.0, 4.0, 6.0];
        chuan_hoa(&mut mau);
        assert!(mau[1].abs() < 1e-6);
        assert!((mau[2] - (1.5_f32).sqrt()).abs() < 1e-6);
        let mut lang = [0.0; 400];
        chuan_hoa(&mut lang);
        assert!(lang.iter().all(|x| *x == 0.0));
    }
}
