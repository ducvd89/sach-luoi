# 📖 Sách lười

Ứng dụng đọc và chuyển sách **EPUB / TXT** thành **sách nói tiếng Việt**, chạy **hoàn toàn offline** trên máy tính và điện thoại (không cần mạng, không gửi dữ liệu ra ngoài, không cần cài Python).

---

## Tải về & Cài đặt

| Nền tảng | Cài đặt |
|---|---|
| **Windows** | Chạy `SachLuoi-Setup-2.1.0.exe` (cài vào `%LOCALAPPDATA%`, không cần quyền quản trị). |
| **Android** | Cài `SachLuoi-android-arm64.apk` (Android 7 trở lên, thiết bị 64-bit). |
| **Linux (AppImage)** | Tải `SachLuoi-1.8.0-x86_64.AppImage`, cấp quyền chạy (`chmod +x`) và mở trực tiếp. |
| **Linux (Flatpak)** | Cài file bundle: `flatpak install vn.sachluoi.SachLuoi.flatpak` hoặc tự dựng qua `./flatpak/build-flatpak.sh`. |

> Sau khi cài đặt, vào **Cài đặt → Giọng đọc** và bấm **Tải mô hình** một lần để nghe khi không có mạng.

---

## Các mô hình giọng đọc (TTS Engines)

Sách lười tích hợp 5 bộ máy đọc chạy trực tiếp trên thiết bị (on-device):

| Engine | Đặc điểm & Chất lượng | Tốc độ | Dung lượng tải | Nền tảng |
|---|---|---|---|---|
| **VieNeu v3 Turbo** *(khuyên dùng)* | 48 kHz, âm thanh trong và tự nhiên nhất. 28 giọng đi kèm (Bắc/Trung/Nam), hỗ trợ thêm giọng từ file ghi âm (3–15 giây). | ~2,9× | 147 MB | Windows, Android, Linux |
| **VieNeu v2** | 24 kHz, ngắt nghỉ câu tự nhiên, đọc tốt từ tiếng Anh xen kẽ. Hỗ trợ nhân bản giọng từ file ghi âm kèm lời. | ~2,8× | 478 MB | Windows, Android, Linux |
| **Matcha-TTS** | 22 kHz, mô hình siêu nhẹ và mượt mà, tối ưu cho máy cấu hình yếu. | **~19×** | 59 MB | Windows, Android, Linux |
| **Giọng nhẹ (Piper)** | Giọng đọc chuẩn qua sherpa-onnx, tốc độ nhanh vượt trội. | Rất nhanh | 32–64 MB/gói | Windows, Android, Linux |
| **TTS hệ thống** | Tận dụng giọng đọc có sẵn của hệ điều hành. | Nhanh | 0 MB | Android |

---

## Tính năng chính

- **Đọc sách đa định dạng:** Hỗ trợ sách **EPUB** (v2, v3) và **TXT** (tự động nhận diện bảng mã và tự chia chương).
- **Chuẩn hoá tiếng Việt thông minh:** Tự động đọc đúng số tiền, ngày tháng, số thập phân, đơn vị đo lường và các từ viết tắt phổ biến (`1.234.567` ➔ một triệu hai trăm..., `20/11` ➔ ngày hai mươi...).
- **Tự động lọc rác văn bản:** Loại bỏ quảng cáo, liên kết web, thông tin người convert để nội dung nghe liền mạch.
- **Trình phát đồng bộ văn bản:** Đoạn đang đọc được tô sáng và tự động cuộn theo giọng nói; chạm vào đoạn bất kỳ để nhảy tới phát ngay.
- **Kiểm âm thông minh (Wav2Vec2):** Tùy chọn đối chiếu âm thanh phát ra với văn bản để tự động phát hiện và đọc lại khi phát âm sai/vấp.
- **Xuất sách nói thành file:** Xuất ra file **Opus**, **AAC**, **MP3** hoặc **WAV** theo từng chương hoặc gộp file, hỗ trợ xử lý đa luồng song song trên máy tính.
- **Tự động lưu tiến trình:** Ghi nhớ chính xác vị trí đang nghe của từng cuốn sách và lưu đệm âm thanh để nghe lại tức thì.

---

## Đóng gói & Phát triển

Yêu cầu môi trường: **Flutter SDK**, **Rust** (và Android NDK / Visual Studio C++ / CMake tùy theo nền tảng đích).

```bash
# Windows (PowerShell):
powershell -ExecutionPolicy Bypass -File dong-goi.ps1

# Android APK (arm64):
cd native/vieneu && cargo build --release --target aarch64-linux-android
cp target/aarch64-linux-android/release/libsachnoi_vieneu.so ../../app/android/app/src/main/jniLibs/arm64-v8a/
cd ../../app && flutter build apk --release --target-platform android-arm64

# Linux (Bundle, AppImage & Flatpak):
./dong-goi-linux.sh        # Dựng Linux release bundle
./build-appimage.sh        # Đóng gói AppImage độc lập (tự chứa libmpv)
./flatpak/build-flatpak.sh  # Dựng và cài đặt Flatpak
```

---

## Ghi công & Bản quyền

- [VieNeu-TTS](https://github.com/pnnbao97/VieNeu-TTS) & [sea-g2p](https://github.com/pnnbao97/sea-g2p) — Phạm Nguyễn Ngọc Bảo (pnnbao-ump).
- [Matcha-TTS tiếng Việt](https://huggingface.co/Cong123779/matcha-tts-vietnamese-onnx-int8) — Cong123779.
- [MOSS-Audio-Tokenizer-Nano](https://huggingface.co/OpenMOSS-Team/MOSS-Audio-Tokenizer-Nano) & [NeuCodec](https://huggingface.co/neuphonic/neucodec).
- [llama.cpp](https://github.com/ggml-org/llama.cpp), [Piper](https://github.com/rhasspy/piper), [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) & [ONNX Runtime](https://github.com/microsoft/onnxruntime).

*Vui lòng tôn trọng bản quyền sách và chỉ sử dụng cho mục đích cá nhân.*
