//! Engine Matcha-TTS tiếng Việt: khớp dòng chảy (flow matching) + Vocos.
//!
//! Khác hẳn hai bản VieNeu ở chỗ **không sinh token**. Cả đoạn ra một lượt:
//! bộ mã hoá văn bản đoán độ dài từng âm rồi trải ra thành khung mel, bộ giải
//! ODE lặp đúng [BUOC_ODE] lần trên toàn bộ khung ấy, rồi Vocos dựng sóng. Vì
//! thế thời gian đọc tỉ lệ thẳng với độ dài đoạn và **biết trước** — không có
//! chuyện mô hình không chịu dừng rồi đọc dài gấp mấy lần như v2.
//!
//! Đo trên máy 24 nhân, đoạn 261 ký tự (đúng cỡ `chunkTargetChars` của
//! `core/chunker.dart`), 10 bước ODE:
//!
//! | luồng | thông lượng |
//! |---|---|
//! | 1 | 8,71× thời gian thực |
//! | 2 | 7,97× |
//! | 4 | 10,78× |
//! | 8 | 15,16× |
//!
//! Nhanh gấp ba tới năm lần v3 Turbo (2,87×) với bộ mô hình chỉ 65 MB thay vì
//! 145 MB. Cái giá là giọng cố định: mô hình một người nói, không nhân bản
//! giọng được, và không có mã tham chiếu nào để mà nối ngữ cảnh.
//!
//! **Không dùng `prompt_encoder.onnx`.** Kho mô hình có nó và bản C++ gốc bơm
//! đuôi mel của câu trước vào `mu` để nối ngữ điệu. Đo trên 8 đoạn liên tiếp
//! (cao độ trung bình từng đoạn, đo bằng tự tương quan):
//!
//! | | lệch chuẩn cao độ giữa các đoạn |
//! |---|---|
//! | không nối | **4,13 Hz** |
//! | có nối (60 khung đuôi) | 4,64 Hz |
//!
//! Nối không giúp gì — nằm trong khoảng nhiễu, mà bản không nối còn nhỉnh hơn.
//! Có lý do: đây là mô hình MỘT người nói, cao độ do chính trọng số quy định
//! nên không có gì để mà trôi. Khác hẳn VieNeu, vốn đoán lại ngữ điệu từ mẫu
//! giọng mỗi đoạn (9,2 Hz khi không nối, 4,8 Hz khi nối). Nên bỏ hẳn bước ấy:
//! các đoạn độc lập nhau, đọc trước song song được, và bớt một file phải tải.

use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};

use ndarray::{Array1, Array2, Array3};
use ort::session::{builder::GraphOptimizationLevel, Session};
use ort::value::Value;
use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};

/// Vocos dựng 22 050 Hz — khác cả 48 kHz của v3 lẫn 24 kHz của v2. Bên Dart
/// phải hỏi chứ đừng gán cứng.
pub const SAMPLE_RATE_MATCHA: u32 = 22_050;

/// Số dải mel của mô hình.
const N_FEATS: usize = 80;

/// Hai hằng số chuẩn hoá mel lấy từ lúc huấn luyện: bộ giải ODE làm việc trên
/// mel đã chuẩn hoá, Vocos thì nhận mel thô, nên phải nhân ngược lại ở giữa.
const MEL_MEAN: f32 = -5.205_414_8;
const MEL_STD: f32 = 2.596_707_1;

/// Số bước giải ODE. Đây là **núm đánh đổi tốc độ ↔ chất lượng** duy nhất của
/// engine này, và mỗi bước là đúng một lượt chạy bộ giải mã.
///
/// Đo trên một câu 95 ký tự, 4 luồng:
///
/// | bước | thông lượng |
/// |---|---|
/// | 4 | 23,22× |
/// | 6 | 18,78× |
/// | 8 | 15,06× |
/// | **10** | **12,47×** |
/// | 16 | 7,88× |
/// | 32 | 4,35× |
///
/// Giữ 10 như bản gốc: engine đã nhanh hơn v3 gấp mấy lần rồi, cắt xuống 4 để
/// đổi lấy chút tốc độ nữa là lấy phần đang thừa đi trả cho phần đang thiếu.
const BUOC_ODE: usize = 10;

/// Độ lệch chuẩn của nhiễu khởi tạo cho bộ giải ODE.
const NHIET: f32 = 0.9;

/// Số mẫu cắt ở đuôi mỗi lượt đọc.
///
/// ISTFT của Vocos chạy `padding='same'` với hop 256, nên hai hop cuối là phản
/// xạ biên chứ không phải tiếng thật — nghe ra tiếng "xịt" ở cuối câu.
const CAT_DUOI: usize = 512;

/// Vuốt nhỏ dần ở ĐẦU đoạn để hết tiếng "bụp" (mili giây).
///
/// Rộng tay được vì mô hình tự chừa sẵn khoảng lặng dài ở đầu: đo 8 câu thì
/// tiếng bắt đầu ở 130–180 ms (trung bình 162). Vuốt 20 ms rơi trọn vào vùng
/// lặng ấy, không đụng vào âm nào.
const VUOT_DAU_MS: usize = 20;

/// Vuốt nhỏ dần ở CUỐI đoạn. Ngắn hơn hẳn đầu, có lý do đo được.
///
/// Đuôi thì ngược hẳn với đầu: mô hình chừa trung bình **7,7 ms**, có câu chừa
/// **0 ms**. Bản trước vuốt 20 ms ở cả hai đầu nên ở đuôi nó ăn thẳng vào
/// 22–43 ms tiếng thật — cả 8/8 câu đo đều dính. Ở đây chỉ cần đủ để chỗ nối
/// vào phần đệm không kêu "bụp", nên 5 ms là vừa.
const VUOT_CUOI_MS: usize = 5;

/// Đệm thêm bấy nhiêu mili giây im lặng vào đuôi mỗi đoạn.
///
/// **Đây là phần chữa lỗi mất tiếng cuối câu trên Android.** Nguyên nhân đã ghi
/// sẵn ở `_nhipXaDem` trong `player_controller.dart`: mở file đoạn kế trong lúc
/// bộ đệm phần cứng còn đang xả thì nó cắt mất một âm ở cuối đoạn vừa đọc. Bên
/// đó chữa bằng cách chờ 400 ms, nhưng con số ấy chỉnh với VieNeu — engine ấy
/// chừa sẵn khoảng lặng ở đuôi nên phần bị cắt rơi vào chỗ im.
///
/// Matcha chừa 0–21 ms, tức là gần như không có biên nào. Bất kỳ phần đuôi nào
/// bị nuốt cũng rơi thẳng vào từ cuối. Windows không lộ ra vì bộ đệm ở đó mỏng
/// hơn nhiều.
///
/// Lấy 150 ms cho xấp xỉ bằng khoảng lặng mà chính mô hình chừa ở ĐẦU đoạn
/// (162 ms) — đó là mức mà mô hình tự coi là đủ để một câu đứng riêng, chứ
/// không phải con số bịa ra.
const DEM_CUOI_MS: usize = 150;

/// Yêu cầu có mã ≤ số này thì bỏ. Cùng cách làm với v2 — xem `v2::huy_toi`.
static HUY_TOI: AtomicU64 = AtomicU64::new(0);

pub fn huy_toi(den_ma: u64) {
    HUY_TOI.fetch_max(den_ma, Ordering::SeqCst);
}

fn da_huy(ma: u64) -> bool {
    ma != 0 && ma <= HUY_TOI.load(Ordering::SeqCst)
}

pub struct EngineMatcha {
    /// Văn bản → `mu` (mel trung bình) + mặt nạ độ dài.
    enc: Session,
    /// Một bước của ODE: (x, mask, mu, t) → dphi_dt.
    dec: Session,
    /// Mel → sóng âm.
    voc: Session,
    /// Ký tự → số hiệu. Khoá là một ký tự Unicode ĐÃ viết thường.
    ma_ky_tu: HashMap<char, i64>,
}

fn mo_session(path: &Path, threads: usize) -> Result<Session, String> {
    let build = || -> Result<Session, Box<dyn std::error::Error>> {
        Ok(Session::builder()?
            .with_optimization_level(GraphOptimizationLevel::Level3)?
            .with_intra_threads(threads)?
            .with_inter_threads(1)?
            .commit_from_file(path)?)
    };
    build().map_err(|e| format!("không nạp được {}: {e}", path.display()))
}

impl EngineMatcha {
    pub fn open(
        enc_path: &Path,
        dec_path: &Path,
        voc_path: &Path,
        symbols_path: &Path,
        threads: usize,
    ) -> Result<Self, String> {
        let threads = threads.max(1);
        Ok(EngineMatcha {
            enc: mo_session(enc_path, threads)?,
            dec: mo_session(dec_path, threads)?,
            voc: mo_session(voc_path, threads)?,
            ma_ky_tu: doc_symbols(symbols_path)?,
        })
    }

    /// Đọc một đoạn, trả mẫu âm 22 050 Hz.
    ///
    /// [toc_do] đi thẳng vào bộ đoán độ dài (`length_scale = 1/toc_do`) chứ
    /// không lấy mẫu lại như hai bản VieNeu — **cao độ giữ nguyên**, chỉ nhịp
    /// đọc đổi. Đo được đúng tuyến tính: 0,8× ra 5,178 s, 1,0× ra 6,478 s,
    /// 1,25× ra 8,104 s trên cùng một câu.
    ///
    /// [seed] chỉ chi phối nhiễu khởi tạo của ODE. Độ dài đoạn KHÔNG đổi theo
    /// nó — xem ghi chú `docLaiRaKhac` bên `matcha_engine.dart`.
    ///
    /// [ma] là mã yêu cầu để [huy_toi] cắt được; 0 nghĩa là không huỷ được.
    pub fn doc(&mut self, text: &str, toc_do: f32, seed: u32, ma: u64) -> Result<Vec<f32>, String> {
        // Bỏ ngay từ cửa: yêu cầu có thể đã nằm trong hàng đợi suốt lúc người
        // dùng tua, chưa chạy dòng nào đã hết cần tới.
        if da_huy(ma) {
            return Err(crate::v2::LOI_HUY.to_string());
        }

        let chuoi = self.thanh_ma(&lam_sach(text));
        if chuoi.is_empty() {
            return Err("không còn ký tự nào mô hình đọc được sau khi dọn văn bản".into());
        }

        let so_ky_tu = chuoi.len();
        let length_scale = if toc_do > 0.01 { 1.0 / toc_do } else { 1.0 };

        // -- 1. Bộ mã hoá văn bản: ra mel trung bình và mặt nạ ------------------
        let x = Array2::from_shape_vec((1, so_ky_tu), chuoi)
            .map_err(|e| format!("không dựng được tensor văn bản: {e}"))?;

        let outputs = self
            .enc
            .run(ort::inputs![
                "x" => Value::from_array(x).map_err(|e| e.to_string())?,
                "x_lengths" => Value::from_array(Array1::from_vec(vec![so_ky_tu as i64]))
                    .map_err(|e| e.to_string())?,
                // Đồ thị khai `length_scale` là số vô hướng (hạng 0), nhưng ONNX
                // Runtime nhận cả hạng 1 và cho ra mảng giống hệt từng bit — đã
                // đối chiếu. Dùng hạng 1 cho khỏi phải dựng tensor 0 chiều.
                "length_scale" => Value::from_array(Array1::from_vec(vec![length_scale]))
                    .map_err(|e| e.to_string())?
            ])
            .map_err(|e| format!("lỗi chạy bộ mã hoá văn bản: {e}"))?;

        let (mu_shape, mut mu) = lay_f32(&outputs, "mu_y")?;
        let (_, mask) = lay_f32(&outputs, "y_mask")?;
        if mu_shape.len() != 3 || mu_shape[1] != N_FEATS {
            return Err(format!("'mu_y' phải là (1, {N_FEATS}, khung), nhận {mu_shape:?}"));
        }
        let so_khung = mu_shape[2];
        if so_khung == 0 {
            return Err("bộ mã hoá không sinh khung mel nào".into());
        }
        // Cắt lát `mask` ở dưới sẽ hoảng nếu thiếu phần tử, mà crate build với
        // `panic = "abort"` nên hoảng là sập cả ứng dụng chứ không phải một lỗi
        // bắt được. Kiểm ở đây rẻ hơn nhiều.
        if mask.len() < so_khung {
            return Err(format!(
                "'y_mask' thiếu phần tử: cần {so_khung}, nhận {}",
                mask.len()
            ));
        }
        mu.truncate(N_FEATS * so_khung);
        drop(outputs);

        // -- 2. Giải ODE bằng phép Euler --------------------------------------
        // Nhiễu khởi tạo N(0, NHIET²). Hạt giống suy từ nội dung đoạn nên cùng
        // một đoạn luôn ra cùng âm thanh — bộ nhớ đệm bên Dart dựa vào đó.
        let mut rng = StdRng::seed_from_u64(seed as u64);
        let mut x: Vec<f32> = (0..N_FEATS * so_khung).map(|_| chuan(&mut rng) * NHIET).collect();

        let dt = 1.0 / BUOC_ODE as f32;
        for buoc in 0..BUOC_ODE {
            // Kiểm giữa các bước chứ không trong lúc chạy đồ thị: mỗi bước chỉ
            // vài chục mili giây nên đây đã là chỗ cắt đủ nhạy, mà cũng là chỗ
            // duy nhất cắt được — phần nặng nằm gọn trong một lượt `run`.
            if da_huy(ma) {
                return Err(crate::v2::LOI_HUY.to_string());
            }

            let t = buoc as f32 / BUOC_ODE as f32;
            let mat_na = Array3::from_shape_vec((1, 1, so_khung), mask[..so_khung].to_vec())
                .map_err(|e| format!("không dựng được tensor mặt nạ: {e}"))?;

            let outputs = self
                .dec
                .run(ort::inputs![
                    "x" => Value::from_array(mel3(&x, so_khung, "x")?).map_err(|e| e.to_string())?,
                    "mask" => Value::from_array(mat_na).map_err(|e| e.to_string())?,
                    "mu" => Value::from_array(mel3(&mu, so_khung, "mu")?).map_err(|e| e.to_string())?,
                    "t" => Value::from_array(Array1::from_vec(vec![t])).map_err(|e| e.to_string())?
                ])
                .map_err(|e| format!("lỗi chạy bộ giải mã: {e}"))?;

            let (_, dphi) = lay_f32(&outputs, "dphi_dt")?;
            if dphi.len() < x.len() {
                return Err(format!(
                    "'dphi_dt' thiếu phần tử: cần {}, nhận {}",
                    x.len(),
                    dphi.len()
                ));
            }
            for (v, d) in x.iter_mut().zip(dphi.iter()) {
                *v += dt * d;
            }
        }

        // Trả mel về thang thật cho Vocos.
        for v in x.iter_mut() {
            *v = *v * MEL_STD + MEL_MEAN;
        }

        // -- 3. Vocos: mel → sóng ---------------------------------------------
        let outputs = self
            .voc
            .run(ort::inputs![
                "mel" => Value::from_array(mel3(&x, so_khung, "mel")?).map_err(|e| e.to_string())?
            ])
            .map_err(|e| format!("lỗi dựng sóng: {e}"))?;
        let (_, mut wav) = lay_f32(&outputs, "wav")?;

        if wav.len() > CAT_DUOI + 1000 {
            wav.truncate(wav.len() - CAT_DUOI);
        }
        Ok(vuot_va_dem(wav))
    }

    /// Văn bản đã dọn → dãy số hiệu, xen số 0 giữa mọi ký tự.
    ///
    /// Việc xen 0 (`intersperse`) là quy ước của chính mô hình lúc huấn luyện:
    /// bộ đoán độ dài cần một ô trống giữa hai âm để đặt phần chuyển tiếp. Bỏ
    /// bước này thì mô hình vẫn chạy, chỉ đọc dính và sai nhịp.
    ///
    /// Ký tự không có trong bảng thì **bỏ hẳn**. Bảng gồm chữ cái tiếng Việt có
    /// dấu, chữ số, dấu câu thường gặp và bộ ký hiệu IPA.
    fn thanh_ma(&self, text: &str) -> Vec<i64> {
        let mut ra = Vec::with_capacity(text.len() * 2 + 1);
        ra.push(0);
        // `to_lowercase` của Rust hạ cả chữ có dấu (Ộ → ộ, Đ → đ). Bản C++ gốc
        // chỉ hạ ký tự một byte, nên mọi chữ hoa tiếng Việt rơi khỏi bảng rồi
        // biến mất: "ĐÊM" bên đó chỉ còn đúng chữ "m".
        for ky_tu in text.chars().flat_map(|c| c.to_lowercase()) {
            if let Some(ma) = self.ma_ky_tu.get(&ky_tu) {
                ra.push(*ma);
                ra.push(0);
            }
        }
        // Chỉ còn số 0 mở đầu nghĩa là không đọc được chữ nào.
        if ra.len() == 1 {
            ra.clear();
        }
        ra
    }
}

/// Dựng mảng (1, 80, khung) từ mảng phẳng.
fn mel3(data: &[f32], so_khung: usize, ten: &str) -> Result<Array3<f32>, String> {
    Array3::from_shape_vec((1, N_FEATS, so_khung), data.to_vec())
        .map_err(|e| format!("không dựng được tensor '{ten}': {e}"))
}

fn lay_f32(outputs: &ort::session::SessionOutputs, name: &str) -> Result<(Vec<usize>, Vec<f32>), String> {
    let value = outputs.get(name).ok_or_else(|| {
        let co: Vec<&str> = outputs.keys().collect();
        format!("thiếu đầu ra '{name}'; đồ thị trả về: {co:?}")
    })?;
    let (shape, data) = value
        .try_extract_tensor::<f32>()
        .map_err(|e| format!("đầu ra '{name}' không phải float32: {e}"))?;
    Ok((shape.iter().map(|d| *d as usize).collect(), data.to_vec()))
}

/// Một mẫu chuẩn N(0,1) bằng Box–Muller.
///
/// Tự viết thay vì kéo thêm `rand_distr`: đúng một công thức, mà thêm một
/// dependency là thêm một thứ phải biên dịch chéo sang Android.
fn chuan(rng: &mut StdRng) -> f32 {
    let u1: f32 = rng.gen_range(f32::MIN_POSITIVE..1.0);
    let u2: f32 = rng.gen_range(0.0..1.0);
    (-2.0 * u1.ln()).sqrt() * (std::f32::consts::TAU * u2).cos()
}

/// Vuốt hai đầu theo đường cos² rồi đệm im lặng vào đuôi.
///
/// Ba việc phải làm đúng thứ tự: vuốt đầu, vuốt đuôi, RỒI mới đệm. Đệm trước
/// thì phép vuốt đuôi rơi vào vùng im, chỗ nối vẫn còn bậc nhảy và vẫn kêu.
fn vuot_va_dem(mut wav: Vec<f32>) -> Vec<f32> {
    let dau = VUOT_DAU_MS * SAMPLE_RATE_MATCHA as usize / 1000;
    let cuoi = VUOT_CUOI_MS * SAMPLE_RATE_MATCHA as usize / 1000;
    // Đoạn quá ngắn để vuốt cả hai đầu mà không chồng lên nhau thì bỏ qua phần
    // vuốt, nhưng vẫn đệm — chính đoạn ngắn mới hay bị nuốt đuôi nhất.
    if wav.len() > dau + cuoi {
        let het = wav.len();
        for i in 0..dau {
            let goc = (i as f32 / dau as f32) * std::f32::consts::FRAC_PI_2;
            wav[i] *= goc.sin() * goc.sin();
        }
        for i in 0..cuoi {
            let goc = (i as f32 / cuoi as f32) * std::f32::consts::FRAC_PI_2;
            wav[het - cuoi + i] *= goc.cos() * goc.cos();
        }
    }
    wav.resize(wav.len() + DEM_CUOI_MS * SAMPLE_RATE_MATCHA as usize / 1000, 0.0);
    wav
}

/// Đọc `symbols.json` thành bảng ký tự → số hiệu.
///
/// File có cả `symbols` (mảng theo thứ tự) lẫn `_symbol_to_id` (bảng tra sẵn).
/// Lấy bảng tra khi có, không thì suy từ vị trí trong mảng.
fn doc_symbols(path: &Path) -> Result<HashMap<char, i64>, String> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("không đọc được {}: {e}", path.display()))?;
    let doc: serde_json::Value = serde_json::from_str(&text)
        .map_err(|e| format!("{} không phải JSON hợp lệ: {e}", path.display()))?;

    let mut bang = HashMap::new();
    // Bảng chỉ chứa ký tự đơn; mục nào dài hơn một ký tự thì mô hình không tra
    // theo ký tự được nên bỏ qua thay vì đoán mò.
    let mut nhan = |ten: &str, ma: i64| {
        let mut chars = ten.chars();
        if let (Some(c), None) = (chars.next(), chars.next()) {
            bang.insert(c, ma);
        }
    };

    if let Some(map) = doc.get("_symbol_to_id").and_then(|v| v.as_object()) {
        for (ten, ma) in map {
            if let Some(so) = ma.as_i64() {
                nhan(ten, so);
            }
        }
    } else if let Some(list) = doc.get("symbols").and_then(|v| v.as_array()) {
        for (i, ten) in list.iter().enumerate() {
            if let Some(s) = ten.as_str() {
                nhan(s, i as i64);
            }
        }
    }

    if bang.is_empty() {
        return Err(format!("{} không có bảng ký tự nào", path.display()));
    }
    Ok(bang)
}

/// Ký hiệu không đọc được thành chữ — đổi sang cách người ta đọc nó.
///
/// Bảng này của riêng engine: nó phụ thuộc vào bảng ký tự của mô hình chứ không
/// phải vào tiếng Việt nói chung, nên để cạnh mô hình chứ đừng nhét vào
/// `core/text_normalizer.dart` dùng chung cho mọi engine.
const DOI_KY_HIEU: &[(char, &str)] = &[
    ('/', " xuyệt "),
    ('\\', " xuyệt ngược "),
    ('_', " gạch dưới "),
    ('@', " a còng "),
    ('#', " thăng "),
    ('$', " đô la "),
    ('%', " phần trăm "),
    ('^', " mũ "),
    ('&', " và "),
    ('*', " sao "),
    ('+', " cộng "),
    ('=', " bằng "),
    ('<', " nhỏ hơn "),
    ('>', " lớn hơn "),
    ('|', " hoặc "),
    ('~', " khoảng "),
];

/// Bỏ hẳn, không đọc thành gì: mở/đóng ngoặc và dấu nháy kép.
const BO_HAN: &[char] = &['(', ')', '[', ']', '{', '}', '"', '`', '“', '”', '«', '»'];

/// Dọn văn bản cho vừa bảng ký tự của mô hình.
///
/// Nhẹ hơn hẳn bản C++ gốc, có chủ ý: số, ngày tháng và từ viết tắt đã được
/// `core/text_normalizer.dart` lo từ lúc NHẬP SÁCH rồi, làm lại ở đây vừa thừa
/// vừa dễ lệch với những gì màn hình đang hiện. Chỗ này chỉ còn phần thuộc về
/// riêng mô hình: bảng ký tự nó biết đọc.
pub fn lam_sach(text: &str) -> String {
    let mut ra = String::with_capacity(text.len());
    for c in text.chars() {
        if let Some((_, doc)) = DOI_KY_HIEU.iter().find(|(k, _)| *k == c) {
            ra.push_str(doc);
        } else if BO_HAN.contains(&c) {
            continue;
        } else if c == '–' || c == '—' {
            ra.push('-');
        } else if c == '‘' || c == '’' {
            ra.push('\'');
        } else if c.is_whitespace() {
            ra.push(' ');
        } else {
            ra.push(c);
        }
    }

    // Gộp khoảng trắng kép do các phép thay ở trên sinh ra.
    let mut gon = String::with_capacity(ra.len());
    let mut vua_trang = true;
    for c in ra.chars() {
        if c == ' ' {
            if !vua_trang {
                gon.push(' ');
            }
            vua_trang = true;
        } else {
            gon.push(c);
            vua_trang = false;
        }
    }
    gon.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lam_sach_doi_ky_hieu_va_gop_khoang_trang() {
        assert_eq!(lam_sach("giảm  50%  hôm nay"), "giảm 50 phần trăm hôm nay");
        assert_eq!(lam_sach("(ghi chú)  “trích”"), "ghi chú trích");
        assert_eq!(lam_sach("một – hai"), "một - hai");
    }
}
