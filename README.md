# 📖 Sách lười

Ứng dụng **Windows và Android** chuyển sách **EPUB / TXT** thành **sách nói tiếng Việt**. Nghe trong
ứng dụng hoặc xuất ra file, tự nhớ chỗ đang nghe.

Chạy **hoàn toàn trên máy**: không cần mạng, không gửi sách đi đâu, không cần cài Python.

---

## Cài đặt

| | |
|---|---|
| **Windows** | Chạy `SachLuoi-Setup-1.6.0.exe`. Không cần quyền quản trị, cài vào `%LOCALAPPDATA%`. |
| **Android** | Cài `SachLuoi-android-arm64.apk`. Cần Android 7 trở lên, máy 64-bit. |

Sau khi cài, mở *Cài đặt → Giọng đọc* và bấm **Tải mô hình (206 MB)** một lần. Từ đó đọc được cả
khi không có mạng.

---

## Giọng đọc

Bốn engine, đổi trong **Cài đặt**:

| | VieNeu v3 Turbo | VieNeu v2 | Giọng nhẹ (Piper) | TTS hệ thống |
|---|---|---|---|---|
| Giọng | 14 dựng sẵn + tự thêm | 9 dựng sẵn + tự thêm | 3 gói tải sẵn | giọng của máy |
| Vùng miền | Bắc, Trung, Nam | Bắc | Bắc | tuỳ máy |
| Âm thanh | 48 kHz, trong nhất | 24 kHz | khá, hơi máy | tuỳ máy |
| Đọc | chuẩn | tự nhiên hơn, biết cả tiếng Anh xen kẽ | hơi máy | tuỳ máy |
| Tốc độ | ~2,9× thời gian thực | ~2,8× | nhanh hơn nhiều | nhanh |
| Dung lượng tải | 206 MB | 478 MB | 21–64 MB mỗi gói | không phải tải |
| Nền tảng | Windows, Android | Windows, Android | Windows, Android | Android |

**Chọn cái nào:** v3 Turbo cho gần như mọi trường hợp — nó chở gấp 2,5 lần lượng thông tin âm cho
mỗi giây tiếng nên tiếng trong hơn. Đổi sang **v2** nếu sách có nhiều tên riêng nước ngoài, hoặc
nếu bạn thấy v3 đọc đều đều: v2 lớn gấp ba nên ngắt nghỉ tự nhiên hơn. Giọng nhẹ khi máy yếu hoặc
cần đọc thật nhanh một cuốn dài. TTS hệ thống khi không muốn tải gì thêm.

**Thêm giọng của bạn.** *Cài đặt → Thêm giọng từ file ghi âm*. Hai bản VieNeu làm việc này theo hai
cách khác nhau:

| | v3 Turbo | v2 |
|---|---|---|
| Cần gì | file `.wav` 3–15 giây | file `.wav` 3–10 giây **kèm lời trong đoạn ghi âm** |
| Bản ghi dài | được, ứng dụng tự chọn đoạn 8 giây sạch nhất | không cắt được, lời phải khớp cả đoạn |
| Tải thêm lần đầu | ~70 MB | ~519 MB |

v2 cần lời vì nó học giọng từ *cặp* âm thanh và lời tương ứng; v3 thì trích thẳng đặc trưng người
nói từ sóng âm nên không cần. Chép lời sai là v2 đọc sai, không phải chỉ giống giọng ít đi.

> Giọng đã nhân bản cho engine này **không chuyển sang engine kia được** — hai bên mô tả một giọng
> theo hai cách hoàn toàn khác nhau. Muốn có cùng giọng ở cả hai thì thêm hai lần từ cùng file.

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

**Kiểm tra trước khi phát** — nút cạnh nút hẹn giờ. Bật lên thì mỗi đoạn được soi âm trước khi
nghe: đếm số âm nghe được rồi so với số từ, lệch quá thì đọc lại (tối đa hai lần) và phát bản khớp
nhất. Bắt được lỗi lặp chữ, nuốt câu, đọc mãi không dừng. Mặc định tắt vì mỗi lần đọc lại tốn thời
gian như đọc một đoạn mới — bật khi thấy giọng hay vấp, máy chậm thì có thể nghe khựng ở chỗ
chuyển đoạn.

**Tay cầm chơi game** — lái được cả ứng dụng không cần chạm màn hình. Cần trái đi giữa các điểm
chọn, `A` chọn, `B` quay lại, `X` mở bảng chọn chương, `Y` phát/dừng, `L`/`R` chuyển tab, cần phải
cuộn trang ở mọi màn hình. Trỏ tới mục nằm ngoài màn hình thì trang tự cuộn tới; cuộn xong mà bấm
hướng thì bắt đầu lại từ mục đầu tiên đang hiện. Windows đọc qua XInput, Android qua
`KeyEvent`/`MotionEvent`.

**Điều khiển ngoài ứng dụng (Android)** — hiện ở phần "Đang phát" của hệ điều hành: điều khiển từ
màn hình khoá, khu thông báo và nút tai nghe.

**Khoá cảm ứng (Android)** — nút hình khoá màu đỏ ở màn hình Nghe. Bấm vào là cả giao diện ngừng
nhận thao tác, màn hình hạ còn 10% sáng và không tự tắt; muốn dùng lại thì trượt để mở khoá. Dành
cho lúc bỏ máy vào túi hay để cạnh gối — một cú chạm nhầm là nhảy mất mấy đoạn. Tiếng vẫn phát bình
thường, và nút trên tai nghe vẫn điều khiển được.

**Xuất file** — chọn độ dài mỗi file, mỗi chương một file, hoặc gộp tất cả. Định dạng Opus 32/64
kbps, AAC 64 kbps, MP3 128 kbps hoặc WAV. Tạm dừng và chạy tiếp bất cứ lúc nào, kể cả sau khi tắt
ứng dụng. Trên máy tính chạy nhiều luồng song song: v3 Turbo đạt 8,94× thời gian thực với 6 luồng
(đo trên máy 12 nhân), v2 thì 3,57× với 2 luồng — nó nghẽn ở băng thông bộ nhớ nên thêm luồng gần
như không nhanh thêm, mà mỗi luồng tốn ~750 MB.

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

native/vieneu/        Rust: chạy cả hai bản VieNeu, nhân bản giọng, mã hoá âm thanh
  src/engine.rs         v3 Turbo qua ONNX Runtime
  src/v2.rs             v2 qua llama.cpp + NeuCodec
native/sea-g2p/       Rust: chuyển chữ sang âm vị (fork của sea-g2p, thêm cổng C)
tts_service/          Script Python chuẩn bị dữ liệu — KHÔNG cần để chạy ứng dụng

dong-goi.ps1          build Windows + tạo bộ cài
installer.iss         kịch bản Inno Setup
```

---

## Phát triển

Cần Rust, Flutter, Visual Studio (workload "Desktop development with C++") và `nuget.exe`
trong PATH — gói `flutter_tts` kéo phụ thuộc WinRT qua NuGet lúc chạy CMake.

```bash
cd native/vieneu && cargo build --release
# sea-g2p mặc định dựng bản PyO3; cổng C cần đúng feature này
cd ../sea-g2p && cargo build --release --no-default-features --features ffi
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

**Hai bản VieNeu chạy trên hai bộ máy khác nhau.** v3 Turbo là ONNX đa codebook chạy qua ONNX
Runtime; v2 là Qwen3 0,3B lượng tử Q4 chạy qua llama.cpp, giải mã âm bằng NeuCodec. Chúng chỉ dùng
chung bộ chuyển âm vị. v2 gấp ba tham số mà vẫn nhanh ngang v3 vì sinh token là bài toán **đọc bộ
nhớ** chứ không phải bài toán tính — trọng số Q4 chỉ 189 MB so với ~300 MB của bản int8. Cũng chính
vì thế mà v2 không hưởng lợi mấy từ việc chạy nhiều luồng: chúng giành nhau cùng một băng thông.

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
  Dùng cả [bản v3 Turbo](https://huggingface.co/pnnbao-ump/VieNeu-TTS-v3-Turbo) (ONNX int8) và
  [bản v2](https://huggingface.co/pnnbao-ump/VieNeu-TTS-v2) (GGUF Q4). Giấy phép **CC BY-NC 4.0**:
  phi thương mại và phải ghi công tác giả.
- [**sea-g2p**](https://github.com/pnnbao97/sea-g2p) — cùng tác giả, Apache-2.0. Bản trong
  `native/sea-g2p/` là fork từ v0.7.20, chỉ thêm cổng C và tách chế độ build.
- [**MOSS-Audio-Tokenizer-Nano**](https://huggingface.co/OpenMOSS-Team/MOSS-Audio-Tokenizer-Nano) —
  OpenMOSS Team. Bộ giải mã âm của v3 Turbo.
- [**NeuCodec**](https://huggingface.co/neuphonic/neucodec) — Neuphonic. Bộ giải mã âm của v2;
  bộ mã hoá dùng bản [distill-neucodec](https://huggingface.co/neuphonic/distill-neucodec) đã xuất
  sang ONNX.
- [**llama.cpp**](https://github.com/ggml-org/llama.cpp) qua
  [**llama-cpp-2**](https://crates.io/crates/llama-cpp-2) — chạy mô hình v2.
- [**Piper**](https://github.com/rhasspy/piper) qua
  [**sherpa-onnx**](https://github.com/k2-fsa/sherpa-onnx).
- [**ONNX Runtime**](https://github.com/microsoft/onnxruntime) — Microsoft, MIT.

Hãy tôn trọng bản quyền sách bạn chuyển đổi và chỉ dùng cho mục đích cá nhân.
