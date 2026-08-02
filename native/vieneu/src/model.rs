//! Nạp mô hình và giữ mọi thứ cần cho một lần đọc.
//!
//! Dịch từ `onnx_runtime_lite.py`. Đồ thị do ONNX Runtime chạy; phần quanh nó —
//! tra embedding, các đầu ra, lấy mẫu — làm bằng mảng số thuần vì mỗi giây âm
//! thanh phải chạy hàng trăm lượt, đặt ở đâu chậm là hỏng cả.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use ort::session::{builder::GraphOptimizationLevel, Session};
use rand::Rng;
use serde_json::Value as Json;

use crate::npz::{read_npz, Array};

/// Tần số lấy mẫu của bản v3 Turbo.
pub const SAMPLE_RATE: u32 = 48_000;

pub struct Config {
    pub n_vq: usize,
    pub hidden: usize,
    pub layers: usize,
    pub local_layers: usize,
    pub local_heads: usize,
    pub audio_pad: i64,
    pub text_prompt_start: i64,
    pub text_prompt_end: i64,
    pub speech_start: i64,
    pub speech_end: i64,
    pub ref_slot: i64,
    pub default_style: i64,
    pub style_labels: std::collections::HashMap<String, i64>,
    pub use_speaker_embedding: bool,
}

fn int(json: &Json, key: &str, fallback: i64) -> i64 {
    json.get(key).and_then(|v| v.as_i64()).unwrap_or(fallback)
}

impl Config {
    fn load(path: &Path) -> Result<Self, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("không đọc được {}: {e}", path.display()))?;
        let c: Json = serde_json::from_str(&text).map_err(|e| format!("config.json hỏng: {e}"))?;

        let hidden = int(&c, "hidden_size", 768) as usize;
        let mut style_labels = std::collections::HashMap::new();
        if let Some(map) = c.get("style_labels").and_then(|v| v.as_object()) {
            for (k, v) in map {
                if let Some(id) = v.as_i64() {
                    style_labels.insert(k.clone(), id);
                }
            }
        }

        Ok(Config {
            n_vq: int(&c, "n_vq", 16) as usize,
            hidden,
            layers: int(&c, "num_hidden_layers", 12) as usize,
            local_layers: int(&c, "local_num_hidden_layers", 1) as usize,
            local_heads: int(&c, "local_num_attention_heads", 8) as usize,
            audio_pad: int(&c, "audio_pad_token_id", 1024),
            text_prompt_start: int(&c, "text_prompt_start_token_id", 3),
            text_prompt_end: int(&c, "text_prompt_end_token_id", 4),
            speech_start: int(&c, "speech_generation_start_token_id", 5),
            speech_end: int(&c, "speech_generation_end_token_id", 6),
            ref_slot: int(&c, "audio_ref_slot_token_id", 7),
            default_style: int(&c, "default_style_token_id", 16),
            style_labels,
            use_speaker_embedding: c
                .get("use_speaker_embedding")
                .and_then(|v| v.as_bool())
                .unwrap_or(false),
        })
    }

    pub fn local_head_dim(&self) -> usize {
        self.hidden / self.local_heads
    }
}

/// Bảng embedding và phép chiếu đặc trưng giọng, đọc từ heads.npz.
pub struct Weights {
    /// (Vt, H) — vừa là bảng tra chữ, vừa là ma trận đầu ra nhờ buộc trọng số.
    pub text_emb: Array,
    /// (n_vq, Va, H)
    pub audio_emb: Array,
    pub audio_vocab: usize,
    pub xvec: Option<XVec>,
}

pub struct XVec {
    pub w: Array,
    pub b: Vec<f32>,
    pub ln_w: Vec<f32>,
    pub ln_b: Vec<f32>,
    pub eps: f32,
}

impl Weights {
    fn load(path: &Path, cfg: &Config) -> Result<Self, String> {
        let mut npz = read_npz(path)?;
        let text_emb = npz.remove("text_emb").ok_or("heads.npz thiếu text_emb")?;
        let audio_emb = npz.remove("audio_emb").ok_or("heads.npz thiếu audio_emb")?;

        let audio_vocab = *audio_emb.shape.get(1).ok_or("audio_emb sai hình dạng")?;
        if audio_emb.shape.first() != Some(&cfg.n_vq) {
            return Err(format!(
                "audio_emb có {} tầng, config nói {}",
                audio_emb.shape.first().copied().unwrap_or(0),
                cfg.n_vq
            ));
        }

        let xvec = match (npz.remove("xvec_w"), npz.remove("xvec_b")) {
            (Some(w), Some(b)) => Some(XVec {
                w,
                b: b.data,
                ln_w: npz.remove("xvec_ln_w").map(|a| a.data).unwrap_or_default(),
                ln_b: npz.remove("xvec_ln_b").map(|a| a.data).unwrap_or_default(),
                eps: npz
                    .remove("xvec_ln_eps")
                    .and_then(|a| a.data.first().copied())
                    .unwrap_or(1e-5),
            }),
            _ => None,
        };

        Ok(Weights { text_emb, audio_emb, audio_vocab, xvec })
    }

    /// Một hàng của bảng embedding âm thanh tầng [channel], mã [code].
    pub fn audio_row(&self, channel: usize, code: usize) -> &[f32] {
        let h = *self.audio_emb.shape.last().unwrap();
        let at = (channel * self.audio_vocab + code) * h;
        &self.audio_emb.data[at..at + h]
    }
}

/// Tham số điều khiển việc lấy mẫu.
#[derive(Clone, Copy)]
pub struct Sampling {
    pub temperature: f32,
    pub top_k: usize,
    pub top_p: f32,
    pub repetition_penalty: f32,
    pub max_new_frames: usize,
}

impl Default for Sampling {
    fn default() -> Self {
        // Hạ từ 0.8/0.95 xuống 0.6/0.85: lấy mẫu ít ngẫu nhiên hơn nên bớt lạc
        // vào những đoạn mã nghe như hơi thở giữa hai từ. Đo trên chương 253
        // Phàm Nhân Tu Tiên (giọng Việt Sử, 12 đoạn nối ngữ cảnh): thời lượng
        // gần như không đổi (165s -> 168s) nên không phải do cắt bớt nhịp.
        //
        // repetition_penalty 1.2 -> 1.4: giảm khả năng mô hình tự hồi quy lặp
        // lại vài từ cuối câu trước khi dừng hẳn (lỗi đo được thật trên một bản
        // xuất file — cụm "vậy được" bị đọc hai lần). Lỗi này mang tính xác
        // suất, phụ thuộc thứ tự cộng dồn dấu phẩy động đa luồng nên không tái
        // hiện ổn định giữa các lần chạy dù cùng seed — không đo được chính xác
        // mức giảm, đây là hạ nguy cơ theo hướng chuẩn (phạt mạnh hơn việc dùng
        // lại mã đã dùng), không phải con số đã kiểm chứng triệt để.
        Sampling {
            temperature: 0.6,
            top_k: 25,
            top_p: 0.85,
            repetition_penalty: 1.4,
            max_new_frames: 300,
        }
    }
}

/// Đặc trưng một giọng đã tính sẵn (xem nap_giong.py bên Python).
pub struct Voice {
    /// 192 chiều, hoặc rỗng nếu mô hình không dùng.
    pub speaker_emb: Vec<f32>,
    /// (số khung, n_vq) — mã tham chiếu của mẫu ghi âm.
    pub ref_codes: Vec<i64>,
    pub ref_frames: usize,
    pub style: String,
}

pub struct Model {
    pub cfg: Config,
    pub weights: Weights,
    pub tokenizer: tokenizers::Tokenizer,
    pub prefill: Session,
    pub decode: Session,
    pub acoustic: Session,
    pub codec: Session,
}

fn open_session(path: PathBuf, threads: usize) -> Result<Session, String> {
    // Các bước dựng phiên trả về kiểu lỗi khác nhau, gom lại bằng Box cho gọn.
    let build = || -> Result<Session, Box<dyn std::error::Error>> {
        Ok(Session::builder()?
            .with_optimization_level(GraphOptimizationLevel::Level3)?
            .with_intra_threads(threads)?
            .with_inter_threads(1)?
            .commit_from_file(&path)?)
    };
    build().map_err(|e| format!("không nạp được {}: {e}", path.display()))
}

impl Model {
    /// [model_dir] chứa các đồ thị của VieNeu, [codec_dir] chứa bộ giải mã âm.
    pub fn load(model_dir: &Path, codec_dir: &Path, threads: usize) -> Result<Self, String> {
        let cfg = Config::load(&model_dir.join("config.json"))?;
        let weights = Weights::load(&model_dir.join("vieneu_v3_heads.npz"), &cfg)?;

        let tokenizer = tokenizers::Tokenizer::from_file(model_dir.join("tokenizer.json"))
            .map_err(|e| format!("không đọc được tokenizer.json: {e}"))?;

        // Ít luồng lại nhanh hơn nhiều luồng. Đo trên máy 12 nhân / 24 luồng
        // (xem examples/do_toc_do.rs, 6 vòng đảo thứ tự để trừ ảnh hưởng nhiệt):
        //
        //   4 luồng  2.98× thời gian thực
        //   8 luồng  2.75×
        //  12 luồng  2.61×
        //
        // Vòng sinh token chạy từng bước một, mỗi bước chỉ là một token với ma
        // trận 768×768 — việc chia cho mỗi luồng còn nhỏ hơn chi phí đồng bộ để
        // chia. Thêm luồng chỉ thêm phần chờ nhau.
        let threads = if threads == 0 {
            std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).clamp(1, 4)
        } else {
            threads
        };

        Ok(Model {
            prefill: open_session(model_dir.join("vieneu_prefill.onnx"), threads)?,
            decode: open_session(model_dir.join("vieneu_decode_step.onnx"), threads)?,
            acoustic: open_session(model_dir.join("vieneu_acoustic_cached.onnx"), threads)?,
            // Bản `_step` chứ không phải `_full`: xem KHUNG_MOI_LUOT trong engine.rs.
            // Hai đồ thị dùng chung file trọng số moss_audio_tokenizer_decode_shared.data.
            codec: open_session(codec_dir.join("moss_audio_tokenizer_decode_step.onnx"), threads)?,
            cfg,
            weights,
            tokenizer,
        })
    }

    /// Đổi 192 chiều đặc trưng giọng thành một vector cộng vào mọi embedding.
    ///
    /// Chính là phép `xvec_proj` bên Python: nhân ma trận, cộng bias, rồi chuẩn
    /// hoá theo lớp.
    pub fn speaker_anchor(&self, speaker_emb: &[f32]) -> Result<Option<Vec<f32>>, String> {
        if !self.cfg.use_speaker_embedding {
            return Ok(None);
        }
        let xvec = self.weights.xvec.as_ref().ok_or("heads.npz thiếu trọng số xvec_proj")?;
        if speaker_emb.is_empty() || speaker_emb.iter().all(|v| *v == 0.0) {
            return Err("đặc trưng giọng rỗng hoặc toàn số 0".into());
        }

        let hidden = self.cfg.hidden;
        let dim = *xvec.w.shape.last().unwrap_or(&speaker_emb.len());
        if speaker_emb.len() != dim {
            return Err(format!("đặc trưng giọng {} chiều, mô hình cần {dim}", speaker_emb.len()));
        }

        let mut v = vec![0.0f32; hidden];
        for (i, out) in v.iter_mut().enumerate() {
            let row = &xvec.w.data[i * dim..(i + 1) * dim];
            let mut sum = 0.0f32;
            for (a, b) in row.iter().zip(speaker_emb) {
                sum += a * b;
            }
            *out = sum + xvec.b.get(i).copied().unwrap_or(0.0);
        }

        let mean = v.iter().sum::<f32>() / hidden as f32;
        let var = v.iter().map(|x| (x - mean) * (x - mean)).sum::<f32>() / hidden as f32;
        let inv = 1.0 / (var + xvec.eps).sqrt();
        for (i, x) in v.iter_mut().enumerate() {
            let normed = (*x - mean) * inv;
            *x = normed * xvec.ln_w.get(i).copied().unwrap_or(1.0)
                + xvec.ln_b.get(i).copied().unwrap_or(0.0);
        }
        Ok(Some(v))
    }

    pub fn style_id(&self, style: &str) -> i64 {
        self.cfg.style_labels.get(style).copied().unwrap_or(self.cfg.default_style)
    }

    /// Dựng bảng token đầu vào: hàng chữ rồi tới hàng mã tham chiếu của giọng.
    pub fn build_rows(&self, phonemes: &str, voice: &Voice, style_id: i64) -> Result<Vec<i64>, String> {
        let encoded = self
            .tokenizer
            .encode(phonemes, false)
            .map_err(|e| format!("lỗi tách token: {e}"))?;

        let width = self.cfg.n_vq + 1;
        let mut text_ids = Vec::with_capacity(encoded.get_ids().len() + 3);
        text_ids.push(style_id);
        text_ids.push(self.cfg.text_prompt_start);
        text_ids.extend(encoded.get_ids().iter().map(|id| *id as i64));
        text_ids.push(self.cfg.text_prompt_end);

        let ref_frames = voice.ref_frames;
        let mut rows = vec![self.cfg.audio_pad; (text_ids.len() + ref_frames) * width];
        for (r, id) in text_ids.iter().enumerate() {
            rows[r * width] = *id;
        }
        for f in 0..ref_frames {
            let base = (text_ids.len() + f) * width;
            rows[base] = self.cfg.ref_slot;
            for ch in 0..self.cfg.n_vq {
                rows[base + 1 + ch] = voice.ref_codes[f * self.cfg.n_vq + ch];
            }
        }
        Ok(rows)
    }

    /// Bảng token -> vector đầu vào: cộng embedding chữ, 16 embedding âm và
    /// vector đặc trưng giọng.
    pub fn embed_rows(&self, rows: &[i64], anchor: Option<&[f32]>) -> Vec<f32> {
        let hidden = self.cfg.hidden;
        let width = self.cfg.n_vq + 1;
        let count = rows.len() / width;
        let mut out = vec![0.0f32; count * hidden];

        for r in 0..count {
            let dst = &mut out[r * hidden..(r + 1) * hidden];
            let text_id = rows[r * width].max(0) as usize;
            dst.copy_from_slice(self.weights.text_emb.row(text_id));

            for ch in 0..self.cfg.n_vq {
                let id = rows[r * width + 1 + ch];
                if id == self.cfg.audio_pad {
                    continue;
                }
                let row = self.weights.audio_row(ch, id.max(0) as usize);
                for (d, s) in dst.iter_mut().zip(row) {
                    *d += *s;
                }
            }

            if let Some(anchor) = anchor {
                for (d, s) in dst.iter_mut().zip(anchor) {
                    *d += *s;
                }
            }
        }
        out
    }

    /// Nhân vector ẩn với bảng embedding để ra điểm số cho từng mã.
    pub fn logits_audio(&self, hidden_vec: &[f32], channel: usize) -> Vec<f32> {
        let hidden = self.cfg.hidden;
        let mut out = vec![0.0f32; self.weights.audio_vocab];
        let base = channel * self.weights.audio_vocab * hidden;
        let table = &self.weights.audio_emb.data;
        for (code, slot) in out.iter_mut().enumerate() {
            let row = &table[base + code * hidden..base + (code + 1) * hidden];
            let mut sum = 0.0f32;
            for (a, b) in row.iter().zip(hidden_vec) {
                sum += a * b;
            }
            *slot = sum;
        }
        out
    }

    /// Chỉ số của token chữ có điểm cao nhất — dùng để biết mô hình đã đọc xong.
    pub fn argmax_text(&self, hidden_vec: &[f32]) -> i64 {
        let hidden = self.cfg.hidden;
        let vocab = self.weights.text_emb.len() / hidden;
        let mut best = 0usize;
        let mut best_score = f32::NEG_INFINITY;
        for id in 0..vocab {
            let row = self.weights.text_emb.row(id);
            let mut sum = 0.0f32;
            for (a, b) in row.iter().zip(hidden_vec) {
                sum += a * b;
            }
            if sum > best_score {
                best_score = sum;
                best = id;
            }
        }
        best as i64
    }
}

/// Chọn một mã từ điểm số: phạt lặp, nhiệt độ, top-k rồi top-p.
///
/// Giữ đúng thứ tự của bản gốc — đổi thứ tự là ra phân phối khác, giọng đọc
/// khác hẳn dù nghe qua vẫn "được".
pub fn sample(
    logits: &mut [f32],
    params: &Sampling,
    seen: Option<&HashSet<usize>>,
    rng: &mut impl Rng,
) -> usize {
    if (params.repetition_penalty - 1.0).abs() > f32::EPSILON {
        if let Some(seen) = seen {
            for &idx in seen {
                if idx < logits.len() {
                    let v = logits[idx];
                    logits[idx] = if v < 0.0 { v * params.repetition_penalty } else { v / params.repetition_penalty };
                }
            }
        }
    }

    if params.temperature <= 0.0 {
        return argmax(logits);
    }
    for v in logits.iter_mut() {
        *v /= params.temperature;
    }

    // Lọc top-k TRƯỚC rồi mới sắp xếp và softmax: cùng phân phối nhưng khỏi
    // phải sắp cả từ vựng mỗi khung.
    let vocab = logits.len();
    let mut cand: Vec<usize> = if params.top_k > 0 && params.top_k < vocab {
        let mut idx: Vec<usize> = (0..vocab).collect();
        idx.select_nth_unstable_by(vocab - params.top_k, |a, b| {
            logits[*a].partial_cmp(&logits[*b]).unwrap_or(std::cmp::Ordering::Equal)
        });
        idx[vocab - params.top_k..].to_vec()
    } else {
        (0..vocab).collect()
    };

    cand.sort_unstable_by(|a, b| {
        logits[*b].partial_cmp(&logits[*a]).unwrap_or(std::cmp::Ordering::Equal)
    });

    let max = logits[cand[0]];
    let mut probs: Vec<f32> = cand.iter().map(|i| (logits[*i] - max).exp()).collect();
    let total: f32 = probs.iter().sum();
    for p in probs.iter_mut() {
        *p /= total;
    }

    if params.top_p > 0.0 && params.top_p < 1.0 {
        let mut running = 0.0f32;
        for p in probs.iter_mut() {
            let before = running;
            running += *p;
            if before >= params.top_p {
                *p = 0.0;
            }
        }
        let total: f32 = probs.iter().sum();
        if total > 0.0 {
            for p in probs.iter_mut() {
                *p /= total;
            }
        }
    }

    let pick: f32 = rng.gen_range(0.0..1.0);
    let mut running = 0.0f32;
    for (i, p) in probs.iter().enumerate() {
        running += *p;
        if pick < running {
            return cand[i];
        }
    }
    cand[cand.len() - 1]
}

fn argmax(values: &[f32]) -> usize {
    let mut best = 0usize;
    let mut score = f32::NEG_INFINITY;
    for (i, v) in values.iter().enumerate() {
        if *v > score {
            score = *v;
            best = i;
        }
    }
    best
}
