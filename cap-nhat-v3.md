# VieNeu v3 Turbo — cập nhật 18/9/2026

Nguồn: [pnnbao-ump/VieNeu-TTS-v3-Turbo](https://huggingface.co/pnnbao-ump/VieNeu-TTS-v3-Turbo/tree/5f2a3e93092efaba9153253ff5f2e6a8e810e4f2),
revision `5f2a3e93092efaba9153253ff5f2e6a8e810e4f2`, cập nhật 16/9/2026.
Model card của revision này công bố Apache-2.0.

## Bản sao trên GitHub

Trong [sach-luoi-models · v1](https://github.com/ducvd89/sach-luoi-models/releases/tag/v1):

| Asset | Byte | SHA-256 |
|---|---:|---|
| `vieneu-v3-5f2a3e9.zip` | 153798041 | `d228baf1439b3672f84a9508f453808ff0e7e170993186223d51081816989337` |
| `vieneu-v3-5f2a3e9-snapshot.zip` | 1677831742 | `b2d4db77dcd94a3f050077475428d9b4e6fb3435c86640f8fd93c81464a6f7bc` |

Gói đầu dành cho app: bộ ONNX int8 mới cùng codec MOSS đang dùng, khoảng 146,7 MiB.
Gói snapshot chứa toàn bộ file gốc của revision, gồm safetensors, các bản ONNX,
speaker encoder, denoiser, tokenizer và model card. Mỗi file đã đối chiếu LFS SHA-256
hoặc Git blob ID từ Hugging Face. File `vieneu-v3-5f2a3e9-nguon.json` ghi SHA-256 từng file.
Giữ nguyên asset `vieneu-v3.zip` cũ để bản app đã phát hành tiếp tục tải được.

## Tích hợp

- Model/tokenizer mới nằm trong `model-v3-5f2a3e9`, không ghi đè thư mục `model` cũ.
  App nhận bộ cũ là chưa có bản mới; tải qua GitHub và kiểm SHA-256 trước khi bung.
- Giữ codec MOSS cũ: nó không thuộc model TTS vừa đổi. Gói codec lấy từ `vieneu-v3.zip`
  có SHA-256 `19dbe3d0d4ab4f24a9d7709892d597a1fee37890b5d26807e2e9e461785a15ab`.
- SDK mới bỏ lựa chọn style: Rust luôn dùng `default_style_token_id`, kể cả hồ sơ giọng cũ.
  Giao diện ONNX và bảng embedding vẫn tương thích; không đổi sampler hay số worker.
- Đồng bộ 25 preset trong SDK revision `d350c63fceb0792d7b2db9a51d61cc040b1f8efa`,
  giữ 3 giọng bổ sung Latradio, Việt Sử, Kim Cúc: tổng 28 giọng đi kèm. Bản gốc SDK nằm
  ở asset `vieneu-v3-5f2a3e9-voices.json`. Giọng người dùng tự thêm vẫn được hợp nhất như trước.
- Tăng `phienBanAm('vieneu')` từ 1 lên 2; không đổi cache của v2, Matcha, Piper và hệ thống.

Đã chạy model mới bằng Rust với giọng Minh Quân Pro, câu 22 âm: tạo 5,28 giây tiếng nói
trong 1,53 giây trên máy phát triển; wav2vec2 nhận 22/22 âm. Đây chỉ là một mẫu kiểm tra,
không thay thế đánh giá chất lượng toàn bộ giọng hay số đo hiệu năng trên Android.

Bộ kiểm thử Flutter: 317 bài qua, 10 bài cần mô hình/biến môi trường khác bỏ qua.
Kiểm riêng tải thật qua `ModelStore` từ GitHub → kiểm SHA-256 → Dart isolate → Rust:
Minh Quân Pro, Kim Thanh và Việt Sử đều sinh WAV hợp lệ, wav2vec2 đếm 22/22 âm của mẫu.
Speaker encoder mới trùng SHA-256 với gói enroll cũ nên không đổi gói thêm giọng.

Tái hiện phép thử tải và đọc thật (từ `app/`, cần DLL Rust mới):

```powershell
$env:THU_V3_THAT = '<thư mục thử nghiệm để giữ model và WAV>'
$env:ORT_DYLIB_PATH = '<onnxruntime.dll>'
flutter test test/cap_nhat_v3_test.dart
```
