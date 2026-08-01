//! Vòng sinh: từ âm vị ra sóng âm.
//!
//! Mỗi giây âm thanh cần 12,5 khung. Mỗi khung chạy một bước của mạng chính rồi
//! 16 bước của bộ giải mã âm sắc để lấy 16 mã. Xong hết mới đưa toàn bộ mã qua
//! bộ giải mã âm — theo từng cửa sổ cuốn chiếu — để dựng lại sóng.

use std::collections::HashSet;

use ndarray::{Array2, Array3, Array4, ArrayD, IxDyn};
use ort::session::Session;
use ort::value::Value;
use rand::rngs::StdRng;
use rand::SeedableRng;

use crate::model::{sample, Model, Sampling, Voice};

/// Bao nhiêu khung đưa vào bộ giải mã âm mỗi lượt.
///
/// Bộ giải mã tự-chú-ý trên toàn bộ khung đưa vào một lượt, nên cả thời gian lẫn
/// bộ nhớ đi theo BÌNH PHƯƠNG độ dài — đó là lý do đoạn phải bị cắt ngắn (xem
/// ghi chú ở `app/lib/core/chunker.dart`).
///
/// Bản `decode_step` của cùng bộ mã nhận thêm khoá/giá trị đã đệm của lượt
/// trước, nên cắt nhỏ rồi cuốn chiếu cho ra ĐÚNG từng mẫu như giải mã cả đoạn
/// một lượt (đo được lệch nhiều nhất 3e-6, tức đúng tới sai số của float32),
/// mà thời gian thành tuyến tính và bộ nhớ thành hằng số. Đo trên máy 12 nhân,
/// 4 luồng, cùng một chuỗi mã:
///
///    khung   cả đoạn   cuốn chiếu
///      125     0,56s        0,48s
///      375     7,18s        2,56s
///     1000    69,44s        7,83s
///
/// 38 khung (khoảng 3 giây) là chỗ rẻ nhất: nhỏ hơn thì chi phí mỗi lượt gọi
/// lấn át, lớn hơn thì phần bình phương bên trong một lượt bắt đầu ngóc lên.
const KHUNG_MOI_LUOT: usize = 38;

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

/// Như [take_f32] nhưng cho tensor số nguyên 32 bit.
fn take_i32(outputs: &ort::session::SessionOutputs, name: &str) -> Result<(Vec<usize>, Vec<i32>), String> {
    let value = outputs
        .get(name)
        .ok_or_else(|| format!("thiếu đầu ra '{name}'"))?;
    let (shape, data) = value
        .try_extract_tensor::<i32>()
        .map_err(|e| format!("đầu ra '{name}' không phải int32: {e}"))?;
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
    /// Mã đã sinh, (số khung × n_vq) đã làm phẳng.
    ///
    /// Trả ra ngoài để đoạn sau nối được phần đuôi của đoạn này vào khối mã
    /// tham chiếu — xem [Voice::ref_codes]. Không có nó thì mỗi đoạn phải tự
    /// đoán lại ngữ điệu từ đầu, nghe rõ chỗ nối.
    pub codes: Vec<i32>,
}

/// Đọc một đoạn âm vị bằng giọng đã cho.
///
/// [ngu_canh] là mã của phần đuôi đoạn đọc ngay trước, đã làm phẳng theo khung.
/// Rỗng thì đoạn này đứng một mình như trước.
///
/// Khi có ngữ cảnh, nó THAY cho mã tham chiếu của mẫu giọng chứ không nối thêm
/// vào sau. Đo trên 12 đoạn liên tiếp, giọng Latradio:
///
///                        giống đoạn trước   lệch chuẩn cao độ
///   mỗi đoạn đứng riêng            0,794              9,2 Hz
///   nối thêm 100 khung             0,797
///   THAY bằng 100 khung            0,828              4,8 Hz
///
/// Nối thêm gần như vô ích: 8 giây mẫu gốc át mất phần ngữ cảnh. Thay hẳn thì
/// độ cao giọng hết nhảy giữa các đoạn — đó là thứ tai nghe ra rõ nhất. Và giọng
/// KHÔNG trôi khỏi mẫu: sau 12 đoạn, độ giống mẫu gốc còn nhích lên (0,770 ->
/// 0,781) vì mỗi đoạn bám vào đoạn liền trước thay vì tự đoán lại từ đầu.
pub fn synthesize(
    model: &mut Model,
    phonemes: &str,
    voice: &Voice,
    params: &Sampling,
    seed: u64,
    ngu_canh: &[i64],
) -> Result<Synthesis, String> {
    let cfg_hidden = model.cfg.hidden;
    let n_vq = model.cfg.n_vq;
    let layers = model.cfg.layers;

    let thay_the;
    let voice = if ngu_canh.len() < n_vq {
        voice
    } else {
        thay_the = Voice {
            speaker_emb: voice.speaker_emb.clone(),
            ref_frames: ngu_canh.len() / n_vq,
            ref_codes: ngu_canh.to_vec(),
            style: voice.style.clone(),
        };
        &thay_the
    };

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
        return Ok(Synthesis { samples: Vec::new(), frames: 0, codes: Vec::new() });
    }

    let samples = decode_codes(model, &frames, frame_count)?;
    Ok(Synthesis { samples, frames: frame_count, codes: frames })
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

/// Một ô nhớ đệm của bộ giải mã âm, cuốn từ lượt này sang lượt sau.
enum O {
    F(ArrayD<f32>),
    I(ArrayD<i32>),
}

/// Toàn bộ trạng thái cuốn chiếu: khoá, giá trị, vị trí đã đệm và các con trỏ.
///
/// Không viết cứng tên hay số lớp — đọc thẳng từ đồ thị, để đổi bản mô hình khác
/// số lớp thì đây không phải sửa. Mỗi đầu vào `x_<i>` có đầu ra tương ứng tên
/// `x_out_<i>`.
struct BoNhoGiaiMa {
    o: Vec<(String, String, O)>,
}

fn ten_dau_ra(ten_vao: &str) -> String {
    match ten_vao.rsplit_once('_') {
        Some((dau, so)) => format!("{dau}_out_{so}"),
        None => format!("{ten_vao}_out"),
    }
}

impl BoNhoGiaiMa {
    /// Trạng thái lúc chưa giải mã khung nào.
    fn rong(codec: &Session) -> Result<Self, String> {
        let mut o = Vec::new();
        for dau_vao in codec.inputs() {
            let ten = dau_vao.name();
            if ten == "audio_codes" || ten == "audio_code_lengths" {
                continue;
            }
            let hinh = dau_vao
                .dtype()
                .tensor_shape()
                .ok_or_else(|| format!("đầu vào '{ten}' của bộ giải mã âm không phải tensor"))?;
            let dims: Vec<usize> = hinh
                .iter()
                .map(|d| if *d < 0 { 0 } else { *d as usize })
                .collect();
            let ix = IxDyn(&dims);

            // Bản gốc điền -1 cho vùng đệm chưa dùng, KHÔNG phải 0: 0 là một vị
            // trí hợp lệ nên mô hình sẽ chú ý vào khoá rỗng và ra tiếng rè.
            // (modeling_moss_audio_tokenizer.py, chỗ cached_positions.fill_(-1))
            let gia_tri = if ten.contains("positions") {
                O::I(ArrayD::from_elem(ix, -1i32))
            } else if ten.contains("keys") || ten.contains("values") {
                O::F(ArrayD::zeros(ix))
            } else {
                O::I(ArrayD::zeros(ix))
            };
            o.push((ten.to_string(), ten_dau_ra(ten), gia_tri));
        }
        if o.is_empty() {
            return Err("bộ giải mã âm không có đầu vào nhớ đệm — nạp nhầm bản _full?".into());
        }
        Ok(BoNhoGiaiMa { o })
    }
}

/// Đưa mã qua bộ giải mã âm để dựng lại sóng 48 kHz.
///
/// Cắt thành từng cửa sổ [KHUNG_MOI_LUOT] khung, mang bộ nhớ đệm của lượt trước
/// sang lượt sau nên ranh giới cửa sổ không để lại vết gì — không phải gối đầu,
/// không phải hoà tiếng, và cũng không cần canh chỗ ngắt câu.
fn decode_codes(model: &mut Model, frames: &[i32], frame_count: usize) -> Result<Vec<f32>, String> {
    let n_vq = model.cfg.n_vq;
    let mut bo_nho = BoNhoGiaiMa::rong(&model.codec)?;
    let mut out: Vec<f32> = Vec::with_capacity(frame_count * 3840);

    let mut at = 0usize;
    while at < frame_count {
        let so_khung = KHUNG_MOI_LUOT.min(frame_count - at);
        let lat = frames[at * n_vq..(at + so_khung) * n_vq].to_vec();
        let codes = Array3::from_shape_vec((1, so_khung, n_vq), lat)
            .map_err(|e| format!("mã sai hình dạng: {e}"))?;
        let lengths = ndarray::Array1::from_vec(vec![so_khung as i32]);

        let mut feed: Vec<(std::borrow::Cow<'_, str>, ort::session::SessionInputValue<'_>)> = vec![
            ("audio_codes".into(), Value::from_array(codes).map_err(|e| e.to_string())?.into()),
            ("audio_code_lengths".into(), Value::from_array(lengths).map_err(|e| e.to_string())?.into()),
        ];
        for (ten, _, gia_tri) in &bo_nho.o {
            let v = match gia_tri {
                O::F(a) => Value::from_array(a.clone()).map_err(|e| e.to_string())?.into_dyn(),
                O::I(a) => Value::from_array(a.clone()).map_err(|e| e.to_string())?.into_dyn(),
            };
            feed.push((ten.clone().into(), v.into()));
        }

        let outputs = model
            .codec
            .run(feed)
            .map_err(|e| format!("lỗi giải mã âm (khung {at}..{}): {e}", at + so_khung))?;

        let (shape, data) = take_f32(&outputs, "audio")?;
        // (1, số kênh, số mẫu) — lấy trung bình các kênh như bản gốc.
        if shape.len() != 3 {
            return Err(format!("bộ giải mã âm trả về hình dạng lạ: {shape:?}"));
        }
        let channels = shape[1];
        let samples = shape[2];
        let dau = out.len();
        out.resize(dau + samples, 0.0);
        for c in 0..channels {
            let base = c * samples;
            for (i, v) in out[dau..].iter_mut().enumerate() {
                *v += data[base + i];
            }
        }
        let scale = 1.0 / channels as f32;
        for v in out[dau..].iter_mut() {
            *v *= scale;
        }

        let mut moi = Vec::with_capacity(bo_nho.o.len());
        for (_, ten_ra, cu) in &bo_nho.o {
            moi.push(match cu {
                O::F(_) => {
                    let (s, d) = take_f32(&outputs, ten_ra)?;
                    O::F(ArrayD::from_shape_vec(IxDyn(&s), d)
                        .map_err(|e| format!("'{ten_ra}' sai hình dạng: {e}"))?)
                }
                O::I(_) => {
                    let (s, d) = take_i32(&outputs, ten_ra)?;
                    O::I(ArrayD::from_shape_vec(IxDyn(&s), d)
                        .map_err(|e| format!("'{ten_ra}' sai hình dạng: {e}"))?)
                }
            });
        }
        drop(outputs);
        for ((_, _, o), gia_tri) in bo_nho.o.iter_mut().zip(moi) {
            *o = gia_tri;
        }

        at += so_khung;
    }
    Ok(out)
}
