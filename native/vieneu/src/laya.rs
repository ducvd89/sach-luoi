//! Laya chạy trong ứng dụng: chọn một trong nhiều lựa chọn từ đoạn văn (ai nói câu này,
//! nhân vật này nam hay nữ) bằng một mô hình mã hoá ~300 triệu tham số xuất sang ONNX.
//!
//! Vì sao tự viết phần chạy thay vì dùng gói Python `laya`: ứng dụng không có Python. Mô hình
//! xuất ONNX gồm cả bộ mã hoá lẫn đầu phân loại; phần còn lại — dựng chuỗi token, đánh dấu
//! lựa chọn, lấy xác suất — là mã nhỏ, dịch lại từ `laya.common.build_head/build_sequence` và
//! `ONNXAgent._decode_answers`. Lệch một token là lệch kết quả mà không có lỗi nào bật ra, nên
//! `thu::dung_chuoi_khop_python` đối chiếu từng id và vị trí đánh dấu với bản Python.
//!
//! Bản float16 (645 MB), KHÔNG phải int8: đo trên ba bài test, float16 ra đúng từng con số của
//! PyTorch (86/90, 178/182, giới tính 39/44) còn int8 động (334 MB) làm giới tính tụt xuống
//! 36/44 và người nói 174/182 dù đã thử lượng tử theo kênh và giữ nguyên đầu phân loại. Tốc độ
//! float16 trên CPU ~0,2–0,4 giây mỗi câu hỏi tuỳ độ dài đoạn và số luồng (đo qua cầu Dart trên
//! chương Harry Potter 5: 4 luồng ~0,29 s, 8 luồng ~0,21 s, 12 luồng ~0,19 s).

use std::path::Path;

use ndarray::{Array1, Array2};
use ort::session::{builder::GraphOptimizationLevel, Session};
use ort::value::Value;
use tokenizers::Tokenizer;

const MASK: &str = "<mask>";
const ID_CLS: i64 = 2; // <bos>
const ID_SEP: i64 = 1; // <eos>
const ID_MASK: i64 = 4;
/// Trần token của mỗi lựa chọn (`max_length=48` trong build_head).
const TOI_DA_LUA_CHON: usize = 48;

/// Một lựa chọn: nhãn trả về và phần mô tả hiện cho mô hình ("Fred: Fred").
pub struct LuaChon {
    pub nhan: String,
    pub mo_ta: String,
}

/// Trạng thái hỏi: đoạn văn, và (nếu hỏi người nói) câu thoại cần xác định.
pub struct TrangThai<'a> {
    pub doan: &'a str,
    pub thoai: Option<&'a str>,
}

fn chuoi_json(s: &str) -> String {
    // serde_json và json.dumps(ensure_ascii=False) thoát đúng cùng một tập ký tự.
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".into())
}

/// `serialize_state` của laya: json.dumps với dấu phân cách MẶC ĐỊNH của Python (", " và ": "),
/// không phải kiểu gọn của serde_json — khác một dấu cách là khác token.
fn tuan_tu_hoa(tt: &TrangThai) -> String {
    match tt.thoai {
        Some(q) => format!(
            "{{\"passage\": {}, \"quote\": {}}}",
            chuoi_json(tt.doan),
            chuoi_json(q)
        ),
        None => format!("{{\"passage\": {}}}", chuoi_json(tt.doan)),
    }
}

fn doc_cau_hinh(thu_muc: &Path) -> Result<serde_json::Value, String> {
    serde_json::from_str(
        &std::fs::read_to_string(thu_muc.join("rl_agent_config.json"))
            .map_err(|e| format!("không đọc được rl_agent_config.json: {e}"))?,
    )
    .map_err(|e| e.to_string())
}

/// Phần dựng chuỗi token — không cần phiên ONNX nên kiểm thử đối chiếu với Python được riêng.
pub struct BoDungChuoi {
    tok: Tokenizer,
    max_len: usize,
    head_max_len: usize,
}

impl BoDungChuoi {
    /// Thư mục cần có `tokenizer.json` và `rl_agent_config.json`.
    pub fn mo(thu_muc: &Path) -> Result<Self, String> {
        let cfg = doc_cau_hinh(thu_muc)?;
        if cfg["option_layout"].as_str().unwrap_or("sequential") != "sequential" {
            return Err("chỉ hỗ trợ option_layout sequential".into());
        }
        let mut tok = Tokenizer::from_file(thu_muc.join("tokenizer.json")).map_err(|e| e.to_string())?;
        // tokenizer.json của checkpoint mang sẵn `truncation.max_length = 48` (dấu vết của việc
        // laya cắt mỗi lựa chọn ở 48 token) và Python chỉ tắt nó cho TỪNG lượt gọi. Để nguyên thì
        // cả phần trạng thái bị cắt lặng lẽ còn 48 token — đoạn dài mất đuôi mà không báo gì (đã
        // gặp: 88 thay vì 90 token ở một câu 49 token). Cắt lựa chọn ở 48 làm riêng, ở `dung_chuoi`.
        tok.with_truncation(None).map_err(|e| e.to_string())?;
        tok.with_padding(None);
        Ok(Self {
            tok,
            max_len: cfg["max_len"].as_u64().unwrap_or(512) as usize,
            head_max_len: cfg["head_max_len"].as_u64().unwrap_or(192) as usize,
        })
    }

    fn ma_hoa(&self, chu: &str) -> Result<Vec<i64>, String> {
        let r = self.tok.encode(chu, false).map_err(|e| e.to_string())?;
        Ok(r.get_ids().iter().map(|&v| v as i64).collect())
    }

    /// Dựng chuỗi `[CLS] choice question: <hướng dẫn> [SEP] [MASK] lựa chọn 0 [MASK] ... [SEP]
    /// <trạng thái> [SEP]`; trả (id, vị trí các [MASK]).
    pub fn dung_chuoi(
        &self,
        huong_dan: &str,
        tt: &TrangThai,
        lua_chon: &[LuaChon],
    ) -> Result<(Vec<i64>, Vec<usize>), String> {
        let ins = huong_dan.replace(MASK, " ");
        let mut dau = self.ma_hoa(&format!("choice question: {ins}"))?;
        let mut cac: Vec<Vec<i64>> = Vec::with_capacity(lua_chon.len());
        for l in lua_chon {
            let chu = if l.mo_ta.is_empty() {
                l.nhan.clone()
            } else {
                format!("{}: {}", l.nhan, l.mo_ta)
            };
            let mut t = self.ma_hoa(&format!(" {}", chu.replace(MASK, " ")))?;
            t.truncate(TOI_DA_LUA_CHON);
            let mut o = vec![ID_MASK];
            o.extend(t);
            cac.push(o);
        }
        let tong = |c: &Vec<Vec<i64>>| c.iter().map(|o| o.len() as i64).sum::<i64>();
        let head = self.head_max_len as i64;
        let mut ngan_sach = head - tong(&cac);
        if ngan_sach < 16 {
            let moi = std::cmp::max(4, (head - 16) / std::cmp::max(1, cac.len() as i64)) as usize;
            for o in cac.iter_mut() {
                o.truncate(moi);
            }
            ngan_sach = head - tong(&cac);
        }
        dau.truncate(std::cmp::max(8, ngan_sach).max(0) as usize);
        let mut ids = vec![ID_CLS];
        ids.extend(dau);
        ids.push(ID_SEP);
        let mut danh_dau = Vec::with_capacity(cac.len());
        for o in &cac {
            danh_dau.push(ids.len());
            ids.extend(o);
        }
        ids.push(ID_SEP);

        let cho = self.max_len.saturating_sub(ids.len()).saturating_sub(1);
        let mut doan = tt.doan.to_string();
        let mut trang_thai = self.ma_hoa(&tuan_tu_hoa(tt).replace(MASK, " "))?;
        // Trạng thái dài quá chỗ còn lại thì phần ĐUÔI bị cắt (như bản Python) — mà trong câu hỏi người
        // nói, `quote` nằm SAU `passage`, nên đoạn văn dài là đủ để câu thoại cần hỏi bị cắt mất
        // trong khi Laya vẫn trả lời. Ở đây cắt ĐẦU đoạn văn (xa câu thoại nhất) cho tới khi vừa, giữ
        // nguyên câu thoại. Chỉ làm với câu hỏi có `quote`; đoạn văn vừa thì y hệt Python.
        if tt.thoai.is_some() {
            let mut vong = 0;
            while trang_thai.len() > cho && !doan.is_empty() && vong < 16 {
                let ky_tu: Vec<char> = doan.chars().collect();
                doan = ky_tu[(ky_tu.len() / 4).max(1).min(ky_tu.len())..].iter().collect();
                let rut = TrangThai { doan: &doan, thoai: tt.thoai };
                trang_thai = self.ma_hoa(&tuan_tu_hoa(&rut).replace(MASK, " "))?;
                vong += 1;
            }
        }
        let dung = trang_thai.len().min(cho);
        ids.extend(&trang_thai[..dung]);
        ids.push(ID_SEP);
        ids.truncate(self.max_len);
        danh_dau.retain(|&m| m < self.max_len);
        if danh_dau.len() != lua_chon.len() {
            return Err(format!(
                "chỉ {} trên {} lựa chọn nằm vừa trong {} token; giảm số ứng viên",
                danh_dau.len(),
                lua_chon.len(),
                self.max_len
            ));
        }
        Ok((ids, danh_dau))
    }
}

pub struct Laya {
    phien: Session,
    bo: BoDungChuoi,
    nhiet_do: f32,
}

impl Laya {
    /// Thư mục cần có `laya.onnx`, `tokenizer.json` và `rl_agent_config.json`.
    pub fn mo(thu_muc: &Path, so_luong: usize) -> Result<Self, String> {
        let cfg = doc_cau_hinh(thu_muc)?;
        // Nhiệt độ của loại câu hỏi `choice` (chỉ số 0) — đúng t_scale của ONNXAgent.
        let nhiet_do = cfg["temperature"][0].as_f64().unwrap_or(1.0).clamp(0.05, 20.0) as f32;
        let bo = BoDungChuoi::mo(thu_muc)?;
        let phien = Session::builder()
            .map_err(|e| e.to_string())?
            .with_optimization_level(GraphOptimizationLevel::Level3)
            .map_err(|e| e.to_string())?
            .with_intra_threads(so_luong.max(1))
            .map_err(|e| e.to_string())?
            .commit_from_file(thu_muc.join("laya.onnx"))
            .map_err(|e| e.to_string())?;
        Ok(Self { phien, bo, nhiet_do })
    }

    /// Xác suất của từng lựa chọn (cộng lại bằng 1), theo đúng thứ tự đưa vào.
    pub fn chon(
        &mut self,
        huong_dan: &str,
        tt: &TrangThai,
        lua_chon: &[LuaChon],
    ) -> Result<Vec<f32>, String> {
        if lua_chon.len() < 2 {
            return Err("cần ít nhất hai lựa chọn".into());
        }
        let (ids, danh_dau) = self.bo.dung_chuoi(huong_dan, tt, lua_chon)?;
        let n = ids.len();
        let k = std::cmp::max(danh_dau.len(), 2); // mô hình xuất ra đòi >= 2 cột (topk(2))
        let mut pos = vec![0i64; k];
        let mut mask = vec![false; k];
        for (i, &m) in danh_dau.iter().enumerate() {
            pos[i] = m as i64;
            mask[i] = true;
        }
        let hinh = |e: ndarray::ShapeError| e.to_string();
        let ort_loi = |e: ort::Error| e.to_string();
        let ra = self
            .phien
            .run(ort::inputs![
                "input_ids" => Value::from_array(Array2::from_shape_vec((1, n), ids).map_err(hinh)?).map_err(ort_loi)?,
                "attention_mask" => Value::from_array(Array2::from_shape_vec((1, n), vec![1i64; n]).map_err(hinh)?).map_err(ort_loi)?,
                "marker_pos" => Value::from_array(Array2::from_shape_vec((1, k), pos).map_err(hinh)?).map_err(ort_loi)?,
                "marker_mask" => Value::from_array(Array2::from_shape_vec((1, k), mask).map_err(hinh)?).map_err(ort_loi)?,
                "qtype" => Value::from_array(Array1::from_vec(vec![0i64])).map_err(ort_loi)?
            ])
            .map_err(|e| format!("laya: {e}"))?;
        let (dang, logits) = ra
            .get("logits")
            .ok_or("mô hình thiếu đầu ra logits")?
            .try_extract_tensor::<f32>()
            .map_err(ort_loi)?;
        if dang.len() != 2 || dang[1] as usize != k {
            return Err(format!("kích thước logits không đúng: {dang:?}"));
        }
        let z: Vec<f32> = logits[..danh_dau.len()].iter().map(|v| v / self.nhiet_do).collect();
        if z.iter().any(|v| !v.is_finite()) {
            return Err("logits chứa NaN/Inf".into());
        }
        let cao = z.iter().cloned().fold(f32::MIN, f32::max);
        let e: Vec<f32> = z.iter().map(|v| (v - cao).exp()).collect();
        let tong: f32 = e.iter().sum();
        Ok(e.iter().map(|v| v / tong).collect())
    }
}

#[cfg(test)]
mod thu {
    use super::*;

    /// Đối chiếu id và vị trí đánh dấu với bản Python (laya.common.build_sequence).
    /// Cần LAYA_DIR (thư mục có tokenizer.json + rl_agent_config.json) và LAYA_MAU
    /// (mau_tokenize.json do Python sinh ra). Thiếu một trong hai thì bỏ qua, như các bài test
    /// cần mô hình khác của dự án.
    #[test]
    fn dung_chuoi_khop_python() {
        let (Ok(thu_muc), Ok(mau)) = (std::env::var("LAYA_DIR"), std::env::var("LAYA_MAU")) else {
            eprintln!("bỏ qua: chưa đặt LAYA_DIR / LAYA_MAU");
            return;
        };
        let bo = BoDungChuoi::mo(Path::new(&thu_muc)).unwrap();
        let m: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(mau).unwrap()).unwrap();
        let tt = TrangThai {
            doan: m["state"]["passage"].as_str().unwrap(),
            thoai: m["state"]["quote"].as_str(),
        };
        // `opts` giữ đúng thứ tự lựa chọn của Python: serde_json không giữ thứ tự khoá của object
        // (BTreeMap), và đổi thứ tự lựa chọn là đổi cả chuỗi token.
        let lua: Vec<LuaChon> = m["opts"]
            .as_array()
            .unwrap()
            .iter()
            .map(|kv| LuaChon {
                nhan: kv[0].as_str().unwrap().to_string(),
                mo_ta: kv[1].as_str().unwrap().to_string(),
            })
            .collect();
        let (ids, danh_dau) = bo.dung_chuoi(m["q"]["instructions"].as_str().unwrap(), &tt, &lua).unwrap();
        let ids_py: Vec<i64> = m["ids"].as_array().unwrap().iter().map(|v| v.as_i64().unwrap()).collect();
        let mk_py: Vec<usize> = m["markers"].as_array().unwrap().iter().map(|v| v.as_u64().unwrap() as usize).collect();
        if ids != ids_py {
            let d = ids.iter().zip(&ids_py).position(|(a, b)| a != b);
            eprintln!("độ dài Rust {} / Python {}; khác đầu tiên ở {:?}", ids.len(), ids_py.len(), d);
            eprintln!("chuỗi trạng thái: {:?}", tuan_tu_hoa(&tt));
            eprintln!("số token trạng thái: {:?}", bo.ma_hoa(&tuan_tu_hoa(&tt)).map(|v| v.len()));
            eprintln!("max_len={} head_max_len={}", bo.max_len, bo.head_max_len);
            eprintln!("đuôi Rust   : {:?}", &ids[ids.len().saturating_sub(8)..]);
            eprintln!("đuôi Python : {:?}", &ids_py[ids_py.len().saturating_sub(8)..]);
        }
        assert_eq!(ids, ids_py, "id token lệch bản Python");
        assert_eq!(danh_dau, mk_py, "vị trí [MASK] lệch bản Python");
    }

    /// Đoạn văn dài quá chỗ còn lại thì phải cắt ĐẦU đoạn văn chứ không cắt mất câu thoại ở đuôi.
    #[test]
    fn doan_van_dai_van_giu_nguyen_cau_thoai() {
        let Ok(thu_muc) = std::env::var("LAYA_DIR") else {
            eprintln!("bỏ qua: chưa đặt LAYA_DIR");
            return;
        };
        let bo = BoDungChuoi::mo(Path::new(&thu_muc)).unwrap();
        let dai = "Một đoạn kể rất dài không liên quan gì. ".repeat(200);
        let doan = format!("{dai}\n“Cái này mới là câu thoại cần hỏi.”");
        let tt = TrangThai { doan: &doan, thoai: Some("“Cái này mới là câu thoại cần hỏi.”") };
        let lua = vec![
            LuaChon { nhan: "Fred".into(), mo_ta: "Fred".into() },
            LuaChon { nhan: "Harry".into(), mo_ta: "Harry".into() },
        ];
        let (ids, danh_dau) = bo.dung_chuoi("Which character speaks the `quote` in the `passage`?", &tt, &lua).unwrap();
        assert!(ids.len() <= bo.max_len, "vượt max_len");
        assert_eq!(danh_dau.len(), 2);
        let u: Vec<u32> = ids.iter().map(|&v| v as u32).collect();
        let chu = bo.tok.decode(&u, false).unwrap();
        assert!(chu.matches("câu thoại cần hỏi").count() >= 2, "câu thoại phải còn ở cả passage lẫn quote: {chu}");
    }

    #[test]
    fn tuan_tu_hoa_dung_dau_cach_cua_python() {
        let tt = TrangThai { doan: "Fred hỏi:\n“Nó có ăn không?”", thoai: Some("“Nó có ăn không?”") };
        assert_eq!(
            tuan_tu_hoa(&tt),
            "{\"passage\": \"Fred hỏi:\\n“Nó có ăn không?”\", \"quote\": \"“Nó có ăn không?”\"}"
        );
    }
}
