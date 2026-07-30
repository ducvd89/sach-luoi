//! Vòng sinh: từ âm vị ra sóng âm.
//!
//! Mỗi giây âm thanh cần 12,5 khung. Mỗi khung chạy một bước của mạng chính rồi
//! 16 bước của bộ giải mã âm sắc để lấy 16 mã. Xong hết mới đưa toàn bộ mã qua
//! bộ giải mã âm để dựng lại sóng.

use std::collections::HashSet;

use ndarray::{Array2, Array3, Array4};
use ort::value::Value;
use rand::rngs::StdRng;
use rand::SeedableRng;

use crate::model::{sample, Model, Sampling, Voice};

/// Lấy tensor float32 từ kết quả chạy, trả về (hình dạng, dữ liệu).
fn take_f32(outputs: &ort::session::SessionOutputs, name: &str) -> Result<(Vec<usize>, Vec<f32>), String> {
    let value = outputs.get(name).ok_or_else(|| {
        let available: Vec<&str> = outputs.keys().collect();
        format!("thiếu đầu ra '{name}'; đồ thị trả về: {available:?}")
    })?;
    let (shape, data) = value
        .try_extract_tensor::<f32>()
        .map_err(|e| format!("đầu ra '{name}' không phải float32: {e}"))?;
    Ok((shape.iter().map(|d| *d as usize).collect(), data.to_vec()))
}

/// Bộ nhớ đệm khoá/giá trị của mạng chính, một cặp cho mỗi lớp.
struct Cache {
    keys: Vec<Array4<f32>>,
    values: Vec<Array4<f32>>,
}

fn to_array4(shape: &[usize], data: Vec<f32>) -> Result<Array4<f32>, String> {
    if shape.len() != 4 {
        return Err(format!("cần tensor 4 chiều, nhận {shape:?}"));
    }
    Array4::from_shape_vec((shape[0], shape[1], shape[2], shape[3]), data)
        .map_err(|e| format!("hình dạng không khớp: {e}"))
}

pub struct Synthesis {
    pub samples: Vec<f32>,
    pub frames: usize,
}

/// Đọc một đoạn âm vị bằng giọng đã cho.
pub fn synthesize(
    model: &mut Model,
    phonemes: &str,
    voice: &Voice,
    params: &Sampling,
    seed: u64,
) -> Result<Synthesis, String> {
    let cfg_hidden = model.cfg.hidden;
    let n_vq = model.cfg.n_vq;
    let layers = model.cfg.layers;

    let style_id = model.style_id(&voice.style);
    let anchor = model.speaker_anchor(&voice.speaker_emb)?;
    let rows = model.build_rows(phonemes, voice, style_id)?;
    let prompt_len = rows.len() / (n_vq + 1);
    let prompt = model.embed_rows(&rows, anchor.as_deref());

    let mut rng = StdRng::seed_from_u64(seed);

    // ── Nạp ngữ cảnh ────────────────────────────────────────────────────────
    let prompt_tensor = Array3::from_shape_vec((1, prompt_len, cfg_hidden), prompt)
        .map_err(|e| format!("prompt sai hình dạng: {e}"))?;
    let outputs = model
        .prefill
        .run(ort::inputs!["inputs_embeds" => Value::from_array(prompt_tensor).map_err(|e| e.to_string())?])
        .map_err(|e| format!("lỗi chạy prefill: {e}"))?;

    let (hidden_shape, hidden_data) = take_f32(&outputs, "hidden")?;
    let width = *hidden_shape.last().unwrap();
    let mut h: Vec<f32> = hidden_data[hidden_data.len() - width..].to_vec();

    let mut cache = Cache { keys: Vec::with_capacity(layers), values: Vec::with_capacity(layers) };
    for i in 0..layers {
        let (s, d) = take_f32(&outputs, &format!("present_k_{i}"))?;
        cache.keys.push(to_array4(&s, d)?);
    }
    for i in 0..layers {
        let (s, d) = take_f32(&outputs, &format!("present_v_{i}"))?;
        cache.values.push(to_array4(&s, d)?);
    }
    drop(outputs);

    // ── Sinh từng khung ─────────────────────────────────────────────────────
    let track_repeats = (params.repetition_penalty - 1.0).abs() > f32::EPSILON;
    let mut seen: Vec<HashSet<usize>> = if track_repeats {
        vec![HashSet::new(); n_vq]
    } else {
        Vec::new()
    };

    let mut frames: Vec<i32> = Vec::with_capacity(params.max_new_frames * n_vq);
    for step in 0..params.max_new_frames {
        let (codes, done) = acoustic_frame(model, &h, params, &mut seen, &mut rng)?;
        frames.extend(codes.iter().map(|c| *c as i32));
        if done {
            break;
        }

        // Khung vừa sinh trở thành đầu vào của bước kế tiếp.
        let mut slot = vec![model.cfg.audio_pad; n_vq + 1];
        slot[0] = model.cfg.speech_start;
        for (i, code) in codes.iter().enumerate() {
            slot[1 + i] = *code as i64;
        }
        let embed = model.embed_rows(&slot, anchor.as_deref());
        let embed = Array3::from_shape_vec((1, 1, cfg_hidden), embed)
            .map_err(|e| format!("embed sai hình dạng: {e}"))?;
        let position = Array2::from_shape_vec((1, 1), vec![(prompt_len + step) as i64])
            .map_err(|e| format!("position sai hình dạng: {e}"))?;

        let mut feed: Vec<(std::borrow::Cow<'_, str>, ort::session::SessionInputValue<'_>)> = vec![
            ("inputs_embeds".into(), Value::from_array(embed).map_err(|e| e.to_string())?.into()),
            ("position_ids".into(), Value::from_array(position).map_err(|e| e.to_string())?.into()),
        ];
        for i in 0..layers {
            feed.push((
                format!("past_k_{i}").into(),
                Value::from_array(cache.keys[i].clone()).map_err(|e| e.to_string())?.into(),
            ));
            feed.push((
                format!("past_v_{i}").into(),
                Value::from_array(cache.values[i].clone()).map_err(|e| e.to_string())?.into(),
            ));
        }

        let outputs = model.decode.run(feed).map_err(|e| format!("lỗi bước sinh: {e}"))?;
        let (s, d) = take_f32(&outputs, "hidden")?;
        h = d[..*s.last().unwrap()].to_vec();
        for i in 0..layers {
            let (s, d) = take_f32(&outputs, &format!("present_k_{i}"))?;
            cache.keys[i] = to_array4(&s, d)?;
        }
        for i in 0..layers {
            let (s, d) = take_f32(&outputs, &format!("present_v_{i}"))?;
            cache.values[i] = to_array4(&s, d)?;
        }
    }

    let frame_count = frames.len() / n_vq;
    if frame_count == 0 {
        return Ok(Synthesis { samples: Vec::new(), frames: 0 });
    }

    let samples = decode_codes(model, &frames, frame_count)?;
    Ok(Synthesis { samples, frames: frame_count })
}

/// Sinh 16 mã của một khung, và cho biết mô hình đã đọc hết chưa.
fn acoustic_frame(
    model: &mut Model,
    h: &[f32],
    params: &Sampling,
    seen: &mut Vec<HashSet<usize>>,
    rng: &mut StdRng,
) -> Result<(Vec<usize>, bool), String> {
    let hidden = model.cfg.hidden;
    let n_vq = model.cfg.n_vq;
    let local_layers = model.cfg.local_layers;
    let local_heads = model.cfg.local_heads;
    let head_dim = model.cfg.local_head_dim();

    // Bước đầu đưa vào hai vector: trạng thái của mạng chính và token báo hiệu
    // bắt đầu phần âm thanh.
    let mut token = Vec::with_capacity(2 * hidden);
    token.extend_from_slice(h);
    token.extend_from_slice(model.weights.text_emb.row(model.cfg.speech_start.max(0) as usize));
    let token = Array3::from_shape_vec((1, 2, hidden), token)
        .map_err(|e| format!("token sai hình dạng: {e}"))?;
    let position = Array2::from_shape_vec((1, 2), vec![0i64, 1])
        .map_err(|e| format!("position sai hình dạng: {e}"))?;

    let mut feed: Vec<(std::borrow::Cow<'_, str>, ort::session::SessionInputValue<'_>)> = vec![
        ("token_emb".into(), Value::from_array(token).map_err(|e| e.to_string())?.into()),
        ("position_ids".into(), Value::from_array(position).map_err(|e| e.to_string())?.into()),
    ];
    for i in 0..local_layers {
        let empty = Array4::<f32>::zeros((1, local_heads, 0, head_dim));
        feed.push((
            format!("past_k_{i}").into(),
            Value::from_array(empty.clone()).map_err(|e| e.to_string())?.into(),
        ));
        feed.push((
            format!("past_v_{i}").into(),
            Value::from_array(empty).map_err(|e| e.to_string())?.into(),
        ));
    }

    let outputs = model.acoustic.run(feed).map_err(|e| format!("lỗi bước âm sắc: {e}"))?;
    let (shape, data) = take_f32(&outputs, "hidden")?;
    let width = *shape.last().unwrap();
    // hidden[0,0] quyết định đã hết câu chưa, hidden[0,1] cho mã đầu tiên.
    let slot0: Vec<f32> = data[..width].to_vec();
    let first: Vec<f32> = data[width..2 * width].to_vec();

    let mut keys = Vec::with_capacity(local_layers);
    let mut values = Vec::with_capacity(local_layers);
    for i in 0..local_layers {
        let (s, d) = take_f32(&outputs, &format!("present_k_{i}"))?;
        keys.push(to_array4(&s, d)?);
    }
    for i in 0..local_layers {
        let (s, d) = take_f32(&outputs, &format!("present_v_{i}"))?;
        values.push(to_array4(&s, d)?);
    }
    drop(outputs);

    let mut codes = Vec::with_capacity(n_vq);
    let mut logits = model.logits_audio(&first, 0);
    codes.push(sample(&mut logits, params, seen.first(), rng));
    if let Some(set) = seen.first_mut() {
        set.insert(codes[0]);
    }

    for ch in 1..n_vq {
        let previous = model.weights.audio_row(ch - 1, codes[ch - 1]).to_vec();
        let token = Array3::from_shape_vec((1, 1, hidden), previous)
            .map_err(|e| format!("token sai hình dạng: {e}"))?;
        let position = Array2::from_shape_vec((1, 1), vec![(ch + 1) as i64])
            .map_err(|e| format!("position sai hình dạng: {e}"))?;

        let mut feed: Vec<(std::borrow::Cow<'_, str>, ort::session::SessionInputValue<'_>)> = vec![
            ("token_emb".into(), Value::from_array(token).map_err(|e| e.to_string())?.into()),
            ("position_ids".into(), Value::from_array(position).map_err(|e| e.to_string())?.into()),
        ];
        for i in 0..local_layers {
            feed.push((
                format!("past_k_{i}").into(),
                Value::from_array(keys[i].clone()).map_err(|e| e.to_string())?.into(),
            ));
            feed.push((
                format!("past_v_{i}").into(),
                Value::from_array(values[i].clone()).map_err(|e| e.to_string())?.into(),
            ));
        }

        let outputs = model.acoustic.run(feed).map_err(|e| format!("lỗi bước âm sắc {ch}: {e}"))?;
        let (shape, data) = take_f32(&outputs, "hidden")?;
        let width = *shape.last().unwrap();
        let vector: Vec<f32> = data[..width].to_vec();
        for i in 0..local_layers {
            let (s, d) = take_f32(&outputs, &format!("present_k_{i}"))?;
            keys[i] = to_array4(&s, d)?;
        }
        for i in 0..local_layers {
            let (s, d) = take_f32(&outputs, &format!("present_v_{i}"))?;
            values[i] = to_array4(&s, d)?;
        }
        drop(outputs);

        let mut logits = model.logits_audio(&vector, ch);
        let code = sample(&mut logits, params, seen.get(ch), rng);
        if let Some(set) = seen.get_mut(ch) {
            set.insert(code);
        }
        codes.push(code);
    }

    let done = model.argmax_text(&slot0) == model.cfg.speech_end;
    Ok((codes, done))
}

/// Đưa toàn bộ mã qua bộ giải mã âm để dựng lại sóng 48 kHz.
fn decode_codes(model: &mut Model, frames: &[i32], frame_count: usize) -> Result<Vec<f32>, String> {
    let n_vq = model.cfg.n_vq;
    let codes = Array3::from_shape_vec((1, frame_count, n_vq), frames.to_vec())
        .map_err(|e| format!("mã sai hình dạng: {e}"))?;
    let lengths = ndarray::Array1::from_vec(vec![frame_count as i32]);

    let outputs = model
        .codec
        .run(ort::inputs![
            "audio_codes" => Value::from_array(codes).map_err(|e| e.to_string())?,
            "audio_code_lengths" => Value::from_array(lengths).map_err(|e| e.to_string())?
        ])
        .map_err(|e| format!("lỗi giải mã âm: {e}"))?;

    let (shape, data) = take_f32(&outputs, "audio")?;
    // (1, số kênh, số mẫu) — lấy trung bình các kênh như bản gốc.
    if shape.len() != 3 {
        return Err(format!("bộ giải mã âm trả về hình dạng lạ: {shape:?}"));
    }
    let channels = shape[1];
    let samples = shape[2];
    let mut out = vec![0.0f32; samples];
    for c in 0..channels {
        let base = c * samples;
        for (i, v) in out.iter_mut().enumerate() {
            *v += data[base + i];
        }
    }
    let scale = 1.0 / channels as f32;
    for v in out.iter_mut() {
        *v *= scale;
    }
    Ok(out)
}
