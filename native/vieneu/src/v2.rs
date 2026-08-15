//! Engine VieNeu **v2**: Qwen3 0.3B sinh token âm, NeuCodec dựng thành sóng.
//!
//! Khác v3 Turbo ở gần như mọi tầng, nên nằm riêng ra một module thay vì cắm
//! thêm nhánh `if` vào `engine.rs`:
//!
//! | | v3 Turbo | v2 |
//! |---|---|---|
//! | Mô hình | ONNX, đa codebook `n_vq=16` + local transformer | Qwen3 một luồng, GGUF Q4 |
//! | Chạy bằng | ONNX Runtime | llama.cpp |
//! | Codec | MOSS-Audio-Tokenizer-Nano | NeuCodec (ONNX) |
//! | Tần số | 48 kHz | 24 kHz |
//! | Giọng | vector 192 chiều + mã tham chiếu | mã tham chiếu + LỜI của đoạn ấy |
//!
//! Vì sao llama.cpp chứ không xuất v2 sang ONNX: v2 chỉ phát hành safetensors và
//! GGUF. Mà kể cả có ONNX thì llama.cpp vẫn hợp hơn — sinh từng token một với
//! batch bằng 1 là bài toán đọc bộ nhớ chứ không phải bài toán tính, mà trọng số
//! Q4 chỉ nặng 189 MB so với ~300 MB của int8, tức là nhanh hơn theo đúng tỉ lệ
//! ấy. Đổi lại chất lượng có thể kém hơn; `kiem_am.dart` bên Dart sẽ đo giúp.

use std::collections::HashMap;
use std::path::Path;
use std::sync::OnceLock;

use llama_cpp_2::context::params::LlamaContextParams;
use llama_cpp_2::llama_backend::LlamaBackend;
use llama_cpp_2::llama_batch::LlamaBatch;
use llama_cpp_2::model::params::LlamaModelParams;
use llama_cpp_2::model::{AddBos, LlamaModel};
use llama_cpp_2::sampling::LlamaSampler;
use llama_cpp_2::token::LlamaToken;
use ndarray::Array3;
use ort::session::Session;
use ort::value::Value;

/// NeuCodec dựng ra 24 kHz — không phải 48 kHz như v3.
pub const SAMPLE_RATE_V2: u32 = 24_000;

/// Mỗi code dựng ra đúng 480 mẫu.
///
/// Không phải con số đoán: chữ ký đồ thị của bộ giải mã khai đầu ra hình dạng
/// `480*s1 - 480` với `s1` là số code (xem `examples/soi_codec_v2.rs`). Suy ra
/// **50 code cho mỗi giây tiếng**, và thời gian thực đòi mô hình sinh 50 tok/s.
pub const MAU_MOI_CODE: usize = 480;

/// Trần số code sinh ra cho một đoạn.
///
/// Đoạn dài nhất mà `chunker.dart` cho qua là 280 ký tự; ở nhịp ~14,5 ký tự mỗi
/// giây thì khoảng 19 giây, tức ~965 code. Để 1500 là chừa gần gấp rưỡi cho
/// những đoạn đọc chậm hơn trung bình, mà vẫn chặn được trường hợp mô hình lảm
/// nhảm không dừng — đúng bệnh mà `kiem_am.dart` sinh ra để bắt.
const CODE_TOI_DA: usize = 1500;

/// Cửa sổ ngữ cảnh. `max_position_embeddings` của v2 là 4096; prompt cộng phần
/// sinh ra không bao giờ chạm tới nên lấy nguyên.
const CUA_SO: u32 = 4096;

/// Encoder đòi đầu vào 16 kHz và độ dài chia hết cho 320.
///
/// 320 mẫu ở 16 kHz là 20 mili giây — đúng một khung, khớp với 50 code mỗi giây
/// ở đầu ra. Không đệm cho tròn thì đồ thị từ chối chạy.
const MAU_MOI_KHUNG_16K: usize = 320;

/// Dấu đánh giọng do người dùng tự thêm.
///
/// Giọng dựng sẵn nằm trong `voices.json` tải từ HuggingFace — file ấy bị ghi đè
/// mỗi lần tải lại, nên giọng tự thêm phải ở file riêng rồi hợp nhất lúc nạp.
/// Cùng lý do với `_hopNhatGiong` bên v3.
pub const NHAN_TU_THEM: &str = "nguoi-dung";

/// Một giọng dựng sẵn của v2.
///
/// v2 nhân bản zero-shot bằng **mã tham chiếu kèm đúng lời của đoạn ghi âm ấy** —
/// không có vector đặc trưng người nói như v3. Nên hồ sơ giọng ở đây là hai thứ
/// đi liền nhau, thiếu một cái là mô hình đọc sai giọng.
pub struct VoiceV2 {
    pub codes: Vec<i32>,
    /// Lời của đoạn ghi âm tham chiếu, ĐÃ chuyển sang âm vị.
    ///
    /// Chuyển một lần lúc nạp chứ không phải mỗi đoạn: lời này cố định theo
    /// giọng, mà một cuốn sách có hàng nghìn đoạn.
    pub text_phones: String,
    pub description: String,
    /// Giọng do người dùng tự thêm trên chính máy này — chỉ những giọng này mới
    /// cho xoá, giọng dựng sẵn xoá đi thì lần nạp sau lại quay về.
    pub tu_them: bool,
}

/// Backend của llama.cpp, khởi tạo đúng MỘT lần cho cả tiến trình.
///
/// Bắt buộc phải là singleton: lúc xuất file, ứng dụng mở thêm worker, mà mỗi
/// worker là một isolate của Dart — isolate dùng chung tiến trình. Gọi
/// `LlamaBackend::init()` lần thứ hai thì nó trả `BackendAlreadyInitialized` và
/// worker ấy chết. Tệ hơn nữa là chết êm: bên Dart bắt lỗi rồi chạy tiếp với ít
/// worker hơn, nên nhìn ra ngoài chỉ thấy "chạy song song chẳng nhanh hơn mấy".
static BACKEND: OnceLock<Result<LlamaBackend, String>> = OnceLock::new();

fn backend() -> Result<&'static LlamaBackend, String> {
    BACKEND
        .get_or_init(|| {
            LlamaBackend::init().map_err(|e| format!("không khởi tạo llama.cpp: {e}"))
        })
        .as_ref()
        .map_err(|e| e.clone())
}

pub struct EngineV2 {
    model: LlamaModel,
    codec: Session,
    /// Mã token của `<|speech_0|>`. Các code sau nằm liền kề nên đổi qua lại
    /// chỉ là phép cộng, khỏi phải dựng chuỗi rồi tách token cho từng code.
    speech_base: i32,
    /// Số code mà mô hình biết — chặn trên khi đổi token thành code.
    speech_count: i32,
    voices: HashMap<String, VoiceV2>,
    threads: i32,
}

/// Đọc danh sách giọng, chồng nhiều lớp lên nhau — lớp sau thắng lớp trước.
///
/// Ba lớp, mỗi lớp một vòng đời khác nhau nên không thể gộp làm một file:
///
/// 1. `voices.json` tải từ HuggingFace — bảy giọng của tác giả mô hình. **Bị ghi
///    đè mỗi lần tải lại**, nên không được viết gì vào đây.
/// 2. `giong_v2.json` đi kèm ứng dụng — giọng nhân bản sẵn mà bản cài mang theo
///    (Latradio, Việt Sử). Chép ra từ assets, cũng bị ghi đè khi cập nhật.
/// 3. File giọng người dùng tự thêm — chỉ nơi này mới được ghi lúc chạy.
fn load_voices(
    path: &Path,
    overlays: &[&Path],
    g2p: &sea_g2p_rs::ffi::SeaG2p,
) -> Result<HashMap<String, VoiceV2>, String> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("không đọc được {}: {e}", path.display()))?;
    let json: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("voices.json hỏng: {e}"))?;

    let mut presets = json
        .get("presets")
        .and_then(|v| v.as_object())
        .cloned()
        .ok_or("voices.json thiếu mục 'presets'")?;

    for overlay in overlays {
        for (name, entry) in load_user_voices(overlay)? {
            presets.insert(name, entry);
        }
    }

    let mut out = HashMap::new();
    for (name, entry) in &presets {
        let codes: Vec<i32> = entry
            .get("codes")
            .and_then(|v| v.as_array())
            .ok_or_else(|| format!("giọng '{name}' thiếu 'codes'"))?
            .iter()
            .filter_map(|v| v.as_i64().map(|n| n as i32))
            .collect();
        if codes.is_empty() {
            return Err(format!("giọng '{name}' có 'codes' rỗng"));
        }
        let text = entry
            .get("text")
            .and_then(|v| v.as_str())
            .unwrap_or_default();
        let text_phones = g2p
            .phonemize(text, false)
            .map_err(|e| format!("không chuyển được âm vị lời tham chiếu của '{name}': {e:?}"))?;

        out.insert(
            name.clone(),
            VoiceV2 {
                codes,
                text_phones,
                description: entry
                    .get("description")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string(),
                tu_them: entry.get("source").and_then(|v| v.as_str()) == Some(NHAN_TU_THEM),
            },
        );
    }
    if out.is_empty() {
        return Err("voices.json không có giọng nào".into());
    }
    Ok(out)
}

impl EngineV2 {
    /// [g2p] chỉ dùng lúc nạp, để chuyển lời tham chiếu của các giọng sang âm
    /// vị. Bên gọi đã giữ sẵn một bản cho engine v3 nên mượn luôn, khỏi mở thêm
    /// từ điển 50 MB thứ hai.
    pub fn open(
        gguf_path: &Path,
        codec_path: &Path,
        voices_path: &Path,
        extra_voices_path: &Path,
        user_voices_path: &Path,
        threads: i32,
        g2p: &sea_g2p_rs::ffi::SeaG2p,
    ) -> Result<Self, String> {
        let backend = backend()?;

        // Không đẩy lớp nào lên GPU: mô hình xuất ra để chạy CPU, mà máy để bàn
        // còn phải chừa GPU cho việc khác — xem ghi chú "Không dùng GPU" ở README.
        let model_params = LlamaModelParams::default().with_n_gpu_layers(0);
        let model = LlamaModel::load_from_file(backend, gguf_path, &model_params)
            .map_err(|e| format!("không nạp được {}: {e}", gguf_path.display()))?;

        let (speech_base, speech_count) = do_moc_speech(&model)?;

        let codec = Session::builder()
            .and_then(|mut b| b.commit_from_file(codec_path))
            .map_err(|e| format!("không mở được codec {}: {e}", codec_path.display()))?;

        let voices = load_voices(voices_path, &[extra_voices_path, user_voices_path], g2p)?;

        Ok(EngineV2 {
            model,
            codec,
            speech_base,
            speech_count,
            voices,
            threads,
        })
    }

    pub fn voice_names(&self) -> Vec<String> {
        let mut names: Vec<String> = self.voices.keys().cloned().collect();
        names.sort();
        names
    }

    pub fn voice(&self, name: &str) -> Option<&VoiceV2> {
        self.voices.get(name)
    }

    /// Nhân bản một giọng từ file ghi âm kèm lời của chính đoạn ấy.
    ///
    /// Khác v3 ở chỗ **bắt buộc có lời**: v3 trích được vector đặc trưng người
    /// nói từ riêng sóng âm, còn v2 chỉ nhận cặp *mã tham chiếu + lời tương ứng*.
    /// Lời sai thì mô hình học nhầm cách phát âm chứ không phải chỉ mất chút
    /// giống giọng.
    ///
    /// [text] phải là chữ đã chuẩn hoá (số viết thành chữ) — cùng khuôn với văn
    /// bản sách đi qua `text_normalizer.dart` trước khi tới đây.
    pub fn add_voice(
        &mut self,
        name: &str,
        wav_path: &Path,
        text: &str,
        encoder_path: &Path,
        user_voices_path: &Path,
        g2p: &sea_g2p_rs::ffi::SeaG2p,
    ) -> Result<(), String> {
        let ten = name.trim();
        if ten.is_empty() {
            return Err("tên giọng không được để trống".into());
        }
        if text.trim().is_empty() {
            return Err("phải nhập lời của đoạn ghi âm".into());
        }

        let codes = ma_hoa_mau_giong(wav_path, encoder_path)?;
        let text_phones = g2p
            .phonemize(text, false)
            .map_err(|e| format!("không chuyển được âm vị của lời: {e:?}"))?;
        if text_phones.trim().is_empty() {
            return Err("lời đọc không ra âm vị nào".into());
        }

        let giay = codes.len() as f64 / (SAMPLE_RATE_V2 as f64 / MAU_MOI_CODE as f64);
        let mut presets = load_user_voices(user_voices_path)?;
        presets.insert(
            ten.to_string(),
            serde_json::json!({
                "codes": codes,
                "text": text,
                "description": format!("Giọng tự thêm · {giay:.1} giây mẫu"),
                "source": NHAN_TU_THEM,
            }),
        );
        save_user_voices(user_voices_path, &presets)?;

        self.voices.insert(
            ten.to_string(),
            VoiceV2 {
                codes,
                text_phones,
                description: format!("Giọng tự thêm · {giay:.1} giây mẫu"),
                tu_them: true,
            },
        );
        Ok(())
    }

    /// Xoá một giọng tự thêm. Giọng dựng sẵn thì từ chối — xoá được cũng vô ích
    /// vì lần nạp sau `voices.json` lại đưa nó trở lại.
    pub fn remove_voice(&mut self, name: &str, user_voices_path: &Path) -> Result<(), String> {
        match self.voices.get(name) {
            None => return Err(format!("không có giọng '{name}'")),
            Some(v) if !v.tu_them => {
                return Err(format!("'{name}' là giọng dựng sẵn, không xoá được"))
            }
            Some(_) => {}
        }

        let mut presets = load_user_voices(user_voices_path)?;
        presets.remove(name);
        save_user_voices(user_voices_path, &presets)?;
        self.voices.remove(name);
        Ok(())
    }

    /// Đọc một đoạn. [text_phones] và lời tham chiếu đều phải là **âm vị** đã qua
    /// sea-g2p rồi, không phải chữ thường — bên gọi lo việc đó vì nó đã giữ sẵn
    /// một bản g2p cho engine v3.
    ///
    /// [seed] suy từ nội dung đoạn ở phía Dart, để đọc lại cùng một đoạn ra cùng
    /// một giọng và bộ nhớ đệm còn ý nghĩa.
    pub fn synthesize(
        &mut self,
        text_phones: &str,
        voice_name: &str,
        seed: u32,
    ) -> Result<Vec<f32>, String> {
        let voice = self
            .voices
            .get(voice_name)
            .ok_or_else(|| format!("không có giọng '{voice_name}'"))?;

        let prompt = format!(
            "<|TEXT_PROMPT_START|>{} {}<|TEXT_PROMPT_END|><|SPEECH_GENERATION_START|>",
            voice.text_phones.trim(),
            text_phones.trim(),
        );

        let mut tokens = self
            .model
            .str_to_token(&prompt, AddBos::Always)
            .map_err(|e| format!("không tách được token của prompt: {e}"))?;

        // Mã tham chiếu nối thẳng bằng id, không qua chuỗi: 133 code mà dựng
        // thành "<|speech_N|>" rồi tách lại thì vừa chậm vừa dễ sai nếu bộ tách
        // gộp nhầm hai token liền nhau.
        tokens.extend(
            voice
                .codes
                .iter()
                .map(|c| LlamaToken(self.speech_base + *c)),
        );

        let codes = self.sinh_code(&tokens, seed)?;
        if codes.len() < 2 {
            return Err("mô hình không sinh ra code nào nghe được".into());
        }
        self.giai_ma(&codes)
    }

    /// Chạy vòng lặp sinh, trả về dãy code của NeuCodec.
    fn sinh_code(&mut self, prompt: &[LlamaToken], seed: u32) -> Result<Vec<i32>, String> {
        let ctx_params = LlamaContextParams::default()
            .with_n_ctx(std::num::NonZeroU32::new(CUA_SO))
            .with_n_batch(CUA_SO)
            .with_n_threads(self.threads)
            .with_n_threads_batch(self.threads);

        let mut ctx = self
            .model
            .new_context(backend()?, ctx_params)
            .map_err(|e| format!("không tạo được ngữ cảnh: {e}"))?;

        let mut batch = LlamaBatch::new(CUA_SO as usize, 1);
        let cuoi = prompt.len() - 1;
        for (i, token) in prompt.iter().enumerate() {
            // Chỉ xin logit ở token cuối — mấy trăm token prompt kia không dùng
            // tới, mà xin hết thì tốn cả bộ nhớ lẫn thời gian sao chép.
            batch
                .add(*token, i as i32, &[0], i == cuoi)
                .map_err(|e| format!("không nạp được prompt: {e}"))?;
        }
        ctx.decode(&mut batch)
            .map_err(|e| format!("lỗi chạy prompt: {e}"))?;

        // Đúng thứ tự và đúng tham số trong generation_config.json của v2:
        // top_k 20 → top_p 0.8 → nhiệt độ 0.7 → bốc theo phân phối.
        let mut sampler = LlamaSampler::chain_simple([
            LlamaSampler::top_k(20),
            LlamaSampler::top_p(0.8, 1),
            LlamaSampler::temp(0.7),
            LlamaSampler::dist(seed),
        ]);

        let mut codes = Vec::new();
        let mut vi_tri = prompt.len() as i32;

        for _ in 0..CODE_TOI_DA {
            let token = sampler.sample(&ctx, batch.n_tokens() - 1);
            sampler.accept(token);

            if self.model.is_eog_token(token) {
                break;
            }
            // Ra token không phải âm nghĩa là mô hình đã thoát khỏi phần đọc —
            // dừng luôn, đừng cố dịch nó thành code.
            let ma = token.0 - self.speech_base;
            if ma < 0 || ma >= self.speech_count {
                break;
            }
            codes.push(ma);

            batch.clear();
            batch
                .add(token, vi_tri, &[0], true)
                .map_err(|e| format!("không nạp được token vừa sinh: {e}"))?;
            ctx.decode(&mut batch)
                .map_err(|e| format!("lỗi bước sinh: {e}"))?;
            vi_tri += 1;
        }

        Ok(codes)
    }

    /// Đưa dãy code qua NeuCodec để ra mẫu âm 24 kHz.
    fn giai_ma(&mut self, codes: &[i32]) -> Result<Vec<f32>, String> {
        let tensor = Array3::from_shape_vec((1, 1, codes.len()), codes.to_vec())
            .map_err(|e| format!("không dựng được tensor code: {e}"))?;

        let outputs = self
            .codec
            .run(ort::inputs![
                "codes" => Value::from_array(tensor).map_err(|e| e.to_string())?
            ])
            .map_err(|e| format!("lỗi giải mã âm: {e}"))?;

        let value = outputs
            .get("audio")
            .ok_or("bộ giải mã không trả đầu ra 'audio'")?;
        let (_, data) = value
            .try_extract_tensor::<f32>()
            .map_err(|e| format!("đầu ra 'audio' không phải float32: {e}"))?;
        Ok(data.to_vec())
    }
}

/// Mã hoá một file .wav thành dãy code tham chiếu của NeuCodec.
///
/// Đây là nửa còn lại của việc nhân bản giọng: `voices.json` chở sẵn code cho
/// bảy giọng dựng sẵn, còn giọng của người dùng thì phải tự tính ra.
///
/// **Không cắt ngắn đoạn ghi âm.** v2 nhận cặp *mã tham chiếu + lời của đúng
/// đoạn ấy*; cắt audio mà giữ nguyên lời là hai thứ lệch nhau và mô hình bắt sai
/// ngữ điệu. Bên gọi phải bảo người dùng đọc đúng những gì họ ghi âm.
///
/// Bộ mã hoá là bản **distil** (`distill-neucodec`) — Neuphonic ra nó kèm lời
/// khẳng định code tương thích với bộ giải mã gốc, và nó nhỏ hơn bản đầy đủ
/// nhiều lần.
pub fn ma_hoa_mau_giong(wav_path: &Path, encoder_path: &Path) -> Result<Vec<i32>, String> {
    let (wav, rate) = crate::enroll::read_wav(wav_path)?;
    if wav.is_empty() {
        return Err("file ghi âm rỗng".into());
    }

    let mut at_16k = crate::fbank::resample_to_16k(&wav, rate);
    if at_16k.len() < MAU_MOI_KHUNG_16K {
        return Err("đoạn ghi âm quá ngắn — cần ít nhất một phần năm giây".into());
    }

    // Đệm cho tròn khung; đồ thị từ chối chạy nếu độ dài không chia hết cho 320.
    let du = at_16k.len() % MAU_MOI_KHUNG_16K;
    if du != 0 {
        at_16k.resize(at_16k.len() + (MAU_MOI_KHUNG_16K - du), 0.0);
    }

    let mut encoder = Session::builder()
        .and_then(|mut b| b.commit_from_file(encoder_path))
        .map_err(|e| format!("không mở được bộ mã hoá {}: {e}", encoder_path.display()))?;

    let so_mau = at_16k.len();
    let tensor = Array3::from_shape_vec((1, 1, so_mau), at_16k)
        .map_err(|e| format!("không dựng được tensor âm thanh: {e}"))?;

    let outputs = encoder
        .run(ort::inputs![
            "audio" => Value::from_array(tensor).map_err(|e| e.to_string())?
        ])
        .map_err(|e| format!("lỗi mã hoá giọng: {e}"))?;

    let value = outputs
        .get("codes")
        .ok_or("bộ mã hoá không trả đầu ra 'codes'")?;
    let (_, data) = value
        .try_extract_tensor::<i32>()
        .map_err(|e| format!("đầu ra 'codes' không phải int32: {e}"))?;

    let codes = data.to_vec();
    if codes.len() < 2 {
        return Err("không mã hoá ra code nào — file ghi âm có tiếng nói không?".into());
    }
    Ok(codes)
}

/// Đọc file giọng tự thêm. Thiếu file thì coi như chưa có giọng nào.
fn load_user_voices(path: &Path) -> Result<serde_json::Map<String, serde_json::Value>, String> {
    if !path.exists() {
        return Ok(serde_json::Map::new());
    }
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("không đọc được {}: {e}", path.display()))?;
    if text.trim().is_empty() {
        return Ok(serde_json::Map::new());
    }
    let json: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("file giọng tự thêm hỏng: {e}"))?;
    Ok(json
        .get("presets")
        .and_then(|v| v.as_object())
        .cloned()
        .unwrap_or_default())
}

fn save_user_voices(
    path: &Path,
    presets: &serde_json::Map<String, serde_json::Value>,
) -> Result<(), String> {
    let mut root = serde_json::Map::new();
    root.insert(
        "meta".into(),
        serde_json::json!({
            "note": "Giọng do người dùng tự thêm cho engine VieNeu v2",
            "spec": "sachluoi.voice.v2.user",
        }),
    );
    root.insert("presets".into(), serde_json::Value::Object(presets.clone()));

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("không tạo được {}: {e}", parent.display()))?;
    }
    // Ghi ra file tạm rồi đổi tên: mất điện giữa chừng không để lại file hỏng mà
    // mất luôn mọi giọng đã thêm.
    let tmp = path.with_extension("json.tmp");
    let text = serde_json::to_string_pretty(&serde_json::Value::Object(root))
        .map_err(|e| format!("không dựng được JSON: {e}"))?;
    std::fs::write(&tmp, text).map_err(|e| format!("không ghi được {}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, path).map_err(|e| format!("không đổi tên được file giọng: {e}"))?;
    Ok(())
}

/// Tìm mã token của `<|speech_0|>` và số code mà mô hình biết.
///
/// Suy ra lúc chạy chứ không gán cứng: mã token phụ thuộc vào bộ từ vựng, mà
/// bản v2 nào đổi từ vựng thì một hằng số gán cứng sẽ sai lặng lẽ — âm thanh ra
/// vẫn có, chỉ là sai bét, kiểu lỗi khó lần nhất.
fn do_moc_speech(model: &LlamaModel) -> Result<(i32, i32), String> {
    let mot = |s: &str| -> Result<i32, String> {
        let ids = model
            .str_to_token(s, AddBos::Never)
            .map_err(|e| format!("không tách được '{s}': {e}"))?;
        match ids.as_slice() {
            [only] => Ok(only.0),
            other => Err(format!(
                "'{s}' phải là đúng một token, nhận được {}",
                other.len()
            )),
        }
    };

    let base = mot("<|speech_0|>")?;
    let ke = mot("<|speech_1|>")?;
    if ke != base + 1 {
        return Err(format!(
            "các token âm không nằm liền kề (speech_0={base}, speech_1={ke})"
        ));
    }

    // NeuCodec dùng một codebook 65.536 mục. Kiểm lại bằng chính từ vựng thay vì
    // tin con số ấy: mô hình nào đổi cỡ codebook thì thấy ngay ở đây.
    let mut count = 0;
    for n in [65_536, 32_768, 16_384, 8_192, 4_096, 2_048, 1_024] {
        if mot(&format!("<|speech_{}|>", n - 1)).is_ok() {
            count = n;
            break;
        }
    }
    if count == 0 {
        return Err("không đo được số code mà mô hình biết".into());
    }

    Ok((base, count))
}
