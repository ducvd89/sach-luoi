# 📖 Sách lười

Ứng dụng **Windows và Android** chuyển sách **EPUB / TXT** thành **sách nói tiếng Việt**. Nghe trong
ứng dụng hoặc xuất ra file, tự nhớ chỗ đang nghe.

Chạy **hoàn toàn trên máy**: không cần mạng, không gửi sách đi đâu, không cần cài Python.

---

## Cài đặt

| | |
|---|---|
| **Windows** | Chạy `SachLuoi-Setup-1.5.3.exe`. Không cần quyền quản trị, cài vào `%LOCALAPPDATA%`. |
| **Android** | Cài `SachLuoi-android-arm64.apk`. Cần Android 7 trở lên, máy 64-bit. |

Sau khi cài, mở *Cài đặt → Giọng đọc* và bấm **Tải mô hình (206 MB)** một lần. Từ đó đọc được cả
khi không có mạng.

---

## Giọng đọc

Ba engine, đổi trong **Cài đặt**:

| | VieNeu-TTS | Giọng nhẹ (Piper) | TTS hệ thống |
|---|---|---|---|
| Giọng | 14 dựng sẵn + tự thêm | 3 gói tải sẵn | giọng có sẵn của máy |
| Vùng miền | Bắc, Trung, Nam | Bắc | tuỳ máy |
| Chất lượng | cao nhất (48 kHz) | khá, hơi máy | tuỳ máy |
| Tốc độ | ~2–3× thời gian thực | nhanh hơn nhiều | nhanh |
| Dung lượng tải | 206 MB | 21–64 MB mỗi gói | không phải tải |
| Nền tảng | Windows, Android | Windows, Android | Android |

**Chọn cái nào:** VieNeu cho gần như mọi trường hợp. Giọng nhẹ khi máy yếu hoặc cần đọc thật nhanh
một cuốn dài. TTS hệ thống khi không muốn tải gì thêm.

**Thêm giọng của bạn:** *Cài đặt → Thêm giọng từ file ghi âm*. Chọn một file `.wav` 3–15 giây, một
người nói rõ, không nhạc nền. Không cần chép lời. Lần đầu tải thêm ~70 MB.

> Hai giọng *Latradio* và *Việt Sử* trong `app/assets/giong.json` được nhân bản từ bản ghi của người
> khác. Dùng riêng thì được, phát hành hay dùng công khai phải xin phép chủ giọng. Muốn bỏ thì xoá
> hai mục đó cùng hai file wav trong `tts_service/voices/`.

---

## Tính năng

**Đọc sách** — EPUB (v2, v3) và TXT (tự nhận bảng mã). Chương lấy từ mục lục EPUB hoặc tự nhận
"Chương 1", "Phần II" trong TXT.

**Chuẩn hoá tiếng Việt** — chỗ máy đọc hay vấp nhất:

| Gốc | Đọc thành |
|---|---|
| `1.234.567` | một triệu hai trăm ba mươi tư nghìn năm trăm sáu mươi bảy |
| `20/11/1954` | ngày hai mươi tháng mười một năm một nghìn chín trăm năm mươi tư |
| `PGS.TS`, `35°C`, `21km` | Phó giáo sư tiến sĩ, ba mươi lăm độ C, hai mươi mốt ki lô mét |

**Dọn quảng cáo** — bỏ tên trang web, dòng ghi công người convert, lời kêu gọi ủng hộ, và cả chương
mục lục của sách tải trên mạng. Nhận rác theo mẫu quen thuộc lẫn theo tần suất lặp. Đo trên Phàm
Nhân Tu Tiên (2.467 chương): bỏ được 1 mục lục + 7.474 dòng header, tiết kiệm ~3 giờ 39 phút nghe.

**Nghe** — văn bản hiện bên cạnh, đoạn đang đọc tô sáng và tự cuộn; bấm vào đoạn nào nhảy tới đó.
Tua ±15 giây, hẹn giờ tắt, đổi tốc độ 0.4×–2.0× có hiệu lực ngay. Phím tắt: `Space` phát/dừng ·
`←` `→` tua · `↑` `↓` chuyển đoạn.

**Tay cầm chơi game** — lái được cả ứng dụng không cần chạm màn hình. Cần trái đi giữa các điểm
chọn, `A` chọn, `B` quay lại, `Y` phát/dừng, `L`/`R` chuyển tab, cần phải cuộn phần chữ. Windows
đọc qua XInput, Android qua `KeyEvent`/`MotionEvent`.

**Điều khiển ngoài ứng dụng (Android)** — hiện ở phần "Đang phát" của hệ điều hành: điều khiển từ
màn hình khoá, khu thông báo và nút tai nghe.

**Xuất file** — chọn độ dài mỗi file, mỗi chương một file, hoặc gộp tất cả. Định dạng Opus 32/64
kbps, AAC 64 kbps, MP3 128 kbps hoặc WAV. Tạm dừng và chạy tiếp bất cứ lúc nào, kể cả sau khi tắt
ứng dụng. Trên máy tính chạy nhiều luồng song song (đo trên máy 12 nhân: 8,94× thời gian thực).

**Soi âm khi xuất** — đếm số âm nghe được trong đoạn vừa tạo rồi so với số từ trong văn bản, lệch
quá thì đọc lại bằng hạt giống khác, tối đa năm lần. Bắt được lỗi lặp chữ, nuốt câu, lảm nhảm không
dừng. Màn hình xuất có khung nhật ký chạy theo thời gian thực.

**Lưu tiến trình** — chỗ đang nghe lưu tự động. Mỗi đoạn âm thanh đã tạo được giữ lại nên nghe lại
gần như tức thì; trần dung lượng chọn trong *Cài đặt → Dữ liệu* (mặc định 500 MB).

---

## Cấu trúc dự án

```
app/                  Ứng dụng Flutter (Windows + Android)
  lib/core/             logic thuần: đọc số, chuẩn hoá, cắt đoạn, EPUB/TXT, WAV, soi âm
  lib/models/           Book, Chunk, Progress, ExportJob, AppSettings
  lib/services/         thư viện sách, phát, xuất file, tay cầm, media session
  lib/services/tts/     các engine giọng nói + bộ nhớ đệm
  lib/ui/               các màn hình
  assets/               từ điển âm vị và hồ sơ giọng

native/vieneu/        Rust: chạy mô hình VieNeu, nhân bản giọng, mã hoá âm thanh
native/sea-g2p/       Rust: chuyển chữ sang âm vị (fork của sea-g2p, thêm cổng C)
tts_service/          Script Python chuẩn bị dữ liệu — KHÔNG cần để chạy ứng dụng

dong-goi.ps1          build Windows + tạo bộ cài
installer.iss         kịch bản Inno Setup
```

---

## Phát triển

```bash
cd native/vieneu && cargo build --release
cd ../sea-g2p && cargo build --release
cd ../../app && flutter run -d windows
```

Kiểm thử (bài cần mô hình sẽ tự bỏ qua; muốn chạy đủ thì trỏ `ORT_DYLIB_PATH` vào một bản ONNX
Runtime):

```bash
cd app && flutter test
```

Đóng gói Windows:

```bash
powershell -ExecutionPolicy Bypass -File dong-goi.ps1
```

Dựng APK (cần Android SDK + NDK; thư viện Rust cho aarch64 phải build trước và chép vào `jniLibs/`):

```bash
cd native/vieneu && cargo build --release --target aarch64-linux-android
cp target/aarch64-linux-android/release/libsachnoi_vieneu.so ../../app/android/app/src/main/jniLibs/arm64-v8a/
cd ../../app && flutter build apk --release --target-platform android-arm64
```

---

## Ghi chú kỹ thuật

**Vì sao có mã Rust.** Mô hình VieNeu sinh từng khung một; giữa hai lần gọi phải tra embedding, chạy
16 phép nhân ma trận 768×1024, lấy mẫu token rồi đẩy KV cache. Bản gốc viết phần đó bằng numpy — đặt
ở Rust thì nhanh ngang, để ở Dart thì vòng lặp nóng này chậm hơn vài lần. Dart chỉ gọi đúng một hàm.

**Mọi thứ nặng nằm ở isolate riêng.** Nạp mô hình, đọc một đoạn, nhập sách — đều chạy nền nên giao
diện không bao giờ bị chặn.

**Nhân bản giọng phải khớp từng con số.** `fbank.rs` được đối chiếu với torchaudio tới khi đặc trưng
trích ra đạt cosine 1,0000; chỗ lệch cuối cùng nằm ở cửa sổ của bộ lấy mẫu lại.

**Kết quả phải ổn định giữa các lần chạy.** Hạt giống suy từ nội dung đoạn, nếu không thì mỗi lần
đọc lại ra một giọng khác và bộ nhớ đệm mất hết ý nghĩa.

**Khoảng nghỉ nằm ngoài âm thanh đã tổng hợp.** Chèn lúc phát và lúc ghép file, nên kéo thanh trượt
là nghe khác ngay, không phải đọc lại cả cuốn sách.

**Không dùng GPU.** Mô hình xuất ra ONNX với chiều batch cố định bằng 1; chạy từng đoạn một thì card
rời còn chậm hơn CPU (1,83× so với 2,94×).

**Chỉ một bản ONNX Runtime, đến từ gói `sherpa_onnx`.** Đừng chép thêm `libonnxruntime.so` vào
`jniLibs/` — xem chú thích trong `app/android/app/build.gradle.kts`.

---

## Ghi công

- [**VieNeu-TTS**](https://github.com/pnnbao97/VieNeu-TTS) — Phạm Nguyễn Ngọc Bảo (pnnbao-ump).
  Bản v3 Turbo, ONNX int8. Giấy phép **CC BY-NC 4.0**: phi thương mại và phải ghi công tác giả.
- [**sea-g2p**](https://github.com/pnnbao97/sea-g2p) — cùng tác giả, Apache-2.0. Bản trong
  `native/sea-g2p/` là fork từ v0.7.20, chỉ thêm cổng C và tách chế độ build.
- [**MOSS-Audio-Tokenizer-Nano**](https://huggingface.co/OpenMOSS-Team/MOSS-Audio-Tokenizer-Nano) —
  OpenMOSS Team.
- [**Piper**](https://github.com/rhasspy/piper) qua
  [**sherpa-onnx**](https://github.com/k2-fsa/sherpa-onnx).
- [**ONNX Runtime**](https://github.com/microsoft/onnxruntime) — Microsoft, MIT.

Hãy tôn trọng bản quyền sách bạn chuyển đổi và chỉ dùng cho mục đích cá nhân.
