# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Ngôn ngữ

Toàn bộ mã nguồn, comment, tên biến/hàm và tên file dùng **tiếng Việt** (không dấu cho
định danh, có dấu trong comment). Giữ nguyên quy ước này khi viết mã mới — đừng chen tên
tiếng Anh vào giữa. Comment ở đầu mỗi file giải thích *vì sao* chứ không phải *cái gì*, và
thường ghi kèm số đo thực nghiệm; khi sửa logic có số đo, cập nhật luôn con số.

## Lệnh thường dùng

Mọi lệnh Flutter chạy từ `app/`.

Build Windows cần **Visual Studio (workload C++)** và **`nuget.exe` trong PATH** — gói
`flutter_tts` kéo phụ thuộc WinRT qua NuGet lúc chạy CMake, thiếu nó thì dừng ngay ở bước
sinh build file với "nuget.exe not found".

Build crate Rust còn cần thêm hai thứ vì `llama-cpp-sys-2` (engine v2) dựng llama.cpp bằng
cmake và sinh binding bằng bindgen:

- **`cmake` trong PATH** — bản đi kèm VS Build Tools dùng được
  (`…\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin`)
- **`LIBCLANG_PATH`** trỏ vào thư mục chứa `libclang.dll` (cài LLVM: `winget install LLVM.LLVM`)

Đường dẫn checkout phải **ngắn**. MSBuild dựng llama.cpp sinh đường dẫn rất sâu và đụng
giới hạn MAX_PATH của Windows — build từ một thư mục tạm lồng nhiều cấp sẽ hỏng với
`MSB3491 … exceeds the OS max path limit`. Nếu cmake đã từng hỏng giữa chừng thì phải
`cargo clean`: lần sau nó thấy `CMakeCache.txt` nên bỏ qua bước configure rồi báo
`MSB1009: Project file does not exist`.

```bash
cd app && flutter run -d windows
```

```bash
cd app && flutter test
```

```bash
cd app && flutter test test/core_test.dart --reporter expanded
```

```bash
cd app && flutter test --plain-name "tên bài test"
```

```bash
cd app && flutter analyze
```

Thư viện Rust (phải build trước khi `flutter run` dùng được engine VieNeu):

```bash
cd native/sea-g2p && cargo build --release --no-default-features --features ffi
```

```bash
cd native/vieneu && cargo build --release
```

Đóng gói Windows (build release + Inno Setup nếu có):

```bash
powershell -ExecutionPolicy Bypass -File dong-goi.ps1
```

APK arm64 — cần Android SDK + NDK, và phải build .so trước rồi chép vào `jniLibs/`.

**Build Rust cho Android phải dùng `cmake` của Android SDK**, không phải bản đi kèm Visual
Studio: đặt `C:\Dev\android-sdk\cmake\3.22.1\bin` lên đầu PATH. Bản ấy kèm đúng `ninja` và
biết dùng toolchain của NDK; bản của VS thì sinh project MSBuild rồi chết ở
`MSB1009: Project file does not exist`. Lỡ build hỏng một lần thì phải **xoá hẳn**
`native/vieneu/target/aarch64-linux-android/` — cmake thấy `CMakeCache.txt` cũ là giữ
nguyên generator sai, `cargo clean` không gỡ được.

```bash
cd native/vieneu && cargo build --release --target aarch64-linux-android
```

```bash
cp native/vieneu/target/aarch64-linux-android/release/libsachnoi_vieneu.so app/android/app/src/main/jniLibs/arm64-v8a/ && cd app && flutter build apk --release --target-platform android-arm64
```

### Test cần mô hình

Nhiều bài test tự `markTestSkipped` khi máy chưa có mô hình — `flutter test` vẫn xanh mà
thực ra không kiểm gì. Muốn chạy đủ phải có **cả ba**:

1. Thư viện Rust đã `cargo build --release` (đường dẫn suy từ gốc repo — xem
   `app/test/duong_dan_repo.dart`).
2. Mô hình VieNeu trong cache HuggingFace tại `%USERPROFILE%\.cache\huggingface\hub\`
   (`models--pnnbao-ump--VieNeu-TTS-v3-Turbo` và
   `models--OpenMOSS-Team--MOSS-Audio-Tokenizer-Nano-ONNX`).
3. Biến môi trường `ORT_DYLIB_PATH` trỏ vào một bản ONNX Runtime — `ort` dùng
   `load-dynamic` nên nạp lúc chạy chứ không liên kết lúc build.

Đường dẫn tới file ngoài gói `app/` phải lấy qua `app/test/duong_dan_repo.dart`, đừng gán
cứng đường dẫn tuyệt đối — repo từng gán cứng đường dẫn máy tác giả nên mọi bài cần mô
hình đều lặng lẽ bị bỏ qua ở máy khác.

## Kiến trúc

### Đường đi của dữ liệu

```
file EPUB/TXT
  → core/epub_parser.dart | core/txt_parser.dart     tách chương + văn bản
  → core/boilerplate.dart                            dọn quảng cáo, mục lục
  → core/text_normalizer.dart + core/vi_number.dart  chuẩn hoá số, ngày, viết tắt
  → core/chunker.dart                                cắt thành Chunk
  → books/<mã>/chunks.json                           lưu sẵn, không cắt lại lúc chạy
  → services/tts/*                                   Chunk → WAV (có cache)
  → services/player_controller.dart                  nghe
  → services/export_service.dart                     xuất file
```

**Chunk là đơn vị của mọi thứ**: đơn vị phát, đơn vị cache, đơn vị lưu tiến trình, đơn vị
ghép file khi xuất. Việc cắt chunk xảy ra **một lần lúc nhập sách**, không phải lúc chạy.
Đổi cách cắt hay cách chuẩn hoá thì sách cũ phải `rebuildBook` mới thấy hiệu lực
(`AppState.rebuildBook` dựng lại từ bản sao file gốc, giữ nguyên chỗ đang nghe).

`chunkTargetChars = 256` và `chunkMaxChars = 280` trong `core/chunker.dart` **không phải
số tuỳ ý** — chúng suy thẳng từ `max_new_frames = 300` của mô hình
(`native/vieneu/src/model.rs`). Vượt trần thì mô hình không báo lỗi, nó chỉ hết lượt sinh
giữa chừng và đoạn đọc bị cụt. Đọc kỹ comment ở đầu file trước khi đổi.

### Trạng thái

`state/app_state.dart` là một `ChangeNotifier` duy nhất, đưa xuống cây widget qua
`ui/app_scope.dart` (InheritedWidget). Không có Provider/Riverpod/Bloc. Nó sở hữu
`LibraryService`, `TtsManager`, `PlayerController`, `ExportService` và toàn bộ
`AppSettings`. Mọi thay đổi đi qua `AppState` rồi `notifyListeners()`.

Hai đường ghi cài đặt, dùng đúng chỗ: `notifySettingsChanged()` chỉ vẽ lại (dùng khi kéo
thanh trượt), `saveSettings()` mới ghi xuống đĩa.

### Tầng TTS

`services/tts/tts_engine.dart` là giao diện chung; bốn bản cài đặt:

| Engine | id | File | Ghi chú |
|---|---|---|---|
| VieNeu v3 Turbo (mặc định) | `vieneu` | `vieneu_engine.dart` → `vieneu_native.dart` | ONNX, 48 kHz |
| VieNeu v2 | `vieneu_v2` | `vieneu_v2_engine.dart` → `vieneu_v2_native.dart` | llama.cpp, 24 kHz |

| Piper (Giọng nhẹ) | `piper` | `ondevice_engine.dart` qua `sherpa_onnx` | nhanh, nhẹ |
| TTS hệ thống | `system` | `system_tts_engine.dart` qua `flutter_tts` | chủ yếu Android |

**Hai bản VieNeu không dùng chung gì ngoài sea-g2p.** Đừng cố gộp chúng lại:

| | v3 Turbo | v2 |
|---|---|---|
| Mô hình | ONNX int8, đa codebook `n_vq=16` + local transformer | Qwen3 0,3B, GGUF Q4 |
| Chạy bằng | ONNX Runtime | llama.cpp (`native/vieneu/src/v2.rs`) |
| Codec | MOSS-Audio-Tokenizer-Nano, 12,5 khung/giây | NeuCodec, 50 code/giây, 480 mẫu mỗi code |
| Bitrate codec | 16 × 10 bit × 12,5 = 2.000 bit/s | 1 × 16 bit × 50 = 800 bit/s |
| Tần số | 48 kHz | 24 kHz |
| Hồ sơ giọng | vector 192 chiều + mã tham chiếu | mã tham chiếu + **lời** của đoạn ghi âm ấy |
| Nối ngữ cảnh | có (`duoi`) | không — bám giọng bằng mã tham chiếu cố định |
| Nhân bản giọng | có | **chưa** — cần bộ mã hoá NeuCodec, repo công khai chỉ có bộ giải mã |

Tải riêng: v3 là 206 MB, v2 là 478 MB (riêng bộ giải mã NeuCodec đã 298 MB). Người dùng
chọn engine nào thì Cài đặt hiện đúng mục tải của engine ấy. Nhân bản giọng cho v2 cần
thêm bộ **mã hoá** NeuCodec 519 MB, chỉ tải khi bấm thêm giọng lần đầu.

Đo trên máy 24 nhân, đoạn 250 ký tự: v3 2,87× thời gian thực, **v2 2,83–2,97×** — v2 ngang
ngửa dù gấp ba tham số, vì sinh token là bài toán đọc bộ nhớ và trọng số Q4 chỉ 189 MB so
với ~300 MB int8. Giọng có mã tham chiếu dài hơn thì chậm hơn: 445 code cho 2,52×.

**Hai engine chạy song song khác nhau hẳn, đừng chép số của nhau.** v3 mở tới 3 worker và
gần như nhân ba (2,87× → 6,85×); v2 phẳng ngay sau worker thứ hai:

| worker | v2 thông lượng | RAM đỉnh |
|---|---|---|
| 1 | 2,83× | 816 MB |
| 2 | **3,57×** | 1.541 MB |
| 3 | 3,86× | 2.321 MB |

Vì thế `_soWorker` của v2 chặn ở **2**. Lý do là chính điều làm v2 nhanh: sinh token nghẽn
ở băng thông bộ nhớ, nên các worker giành nhau. Và đừng tin lời hứa "mmap nên worker phụ
gần như miễn phí" — đo thật thì mỗi worker tốn ~750 MB.

Mọi engine **phải trả WAV**. Lý do ghi ở đầu `tts_engine.dart`: Android không có bộ mã hoá
MP3 nào dùng được, nên việc nén dời hẳn sang bước xuất file (`services/audio_encoder.dart`).

`tts_manager.dart` là cửa vào duy nhất. Khoá cache gồm **engine + giọng + tốc độ + nội
dung đoạn + ngữ cảnh + lần đọc thứ mấy**. Thêm bất cứ thứ gì ảnh hưởng tới âm thanh sinh
ra mà quên đưa vào khoá là lấy nhầm bản cũ.

#### Hai cờ năng lực của engine, và vì sao chúng quan trọng

`TtsEngine` khai hai cờ mà phần còn lại của ứng dụng phải hỏi thay vì đoán theo mã engine:

- **`noiNguCanh`** — engine có trả mã đuôi để nối đoạn không. Chỉ v3 có.
- **`docLaiRaKhac`** — đọc lại cùng một đoạn có ra bản khác không. Hai bản VieNeu có.

Đây không phải siêu hình. `player_controller` từng chọn cách đọc trước theo **cài đặt của
người dùng** chứ không theo cờ này, nên v2 rơi vào nhánh đọc trước tuần tự rồi thoát ngay
vòng đầu vì không có đuôi để nối — **không đoạn nào được đọc trước**, và mỗi lần chuyển
đoạn người dùng ngồi chờ 4–7 giây. Lỗi im lặng hoàn toàn: không exception, không cảnh báo.
`app/test/noi_ngu_canh_test.dart` canh chỗ này.

Gán cứng `engineId == 'vieneu'` ở bất cứ đâu ngoài `tts_manager` đều là mầm của đúng lỗi ấy.

### Ranh giới Dart ↔ Rust

`vieneu_native.dart` là **chỗ duy nhất** gọi FFI. Mô hình sống trong một isolate riêng
suốt phiên (nạp mất ~1,5 giây), giao tiếp bằng message. Quy tắc bộ nhớ đã ghi trong file:
mẫu âm phải `Float32List.fromList` rồi gọi `vieneu_samples_free` ngay; còn con trỏ "đuôi"
trỏ vào bộ đệm bên trong engine, chỉ sống tới lần đọc kế — **sao ra ngay và không được
giải phóng**.

Phía Rust: `native/vieneu/src/ffi.rs` là cổng C, `engine.rs` là vòng lặp sinh,
`model.rs` giữ các hằng số của mô hình, `fbank.rs` trích đặc trưng cho việc nhân bản giọng
(đã đối chiếu với torchaudio tới cosine 1,0000 — đừng "dọn dẹp" file này).

`native/sea-g2p/` là fork của sea-g2p v0.7.20, chỉ thêm cổng C và tách chế độ build. Feature
mặc định của nó là `python` (PyO3) — build trần `cargo build --release` sẽ **hỏng**, phải
`--no-default-features --features ffi` mới ra được `sea_g2p_rs.dll` mà ứng dụng cần. Crate
`vieneu` đã khai đúng feature nên build nó thì không dính. Sửa ở đây thì kiểm lại bằng
`app/test/sea_g2p_test.dart` — nó so từng ký tự âm vị với kết quả sinh từ bản Python, vì âm
vị lệch một ký tự là mô hình đọc sai mà tai rất khó bắt.

### Nghe và xuất file

Tốc độ đọc áp bằng cách chỉnh **tốc độ phát**, không tổng hợp lại — nên đổi tốc độ nghe
thấy ngay và cache vẫn dùng được. Khoảng nghỉ giữa các đoạn cũng chèn lúc phát/lúc ghép
file chứ không nằm trong âm thanh đã tổng hợp.

`export_service.dart`: job dừng và chạy tiếp được kể cả sau khi tắt ứng dụng — trạng thái ở
`job.json`, phần đang ghi dở ở file `.part`, âm thanh từng đoạn ở cache. Sau mỗi đoạn,
`core/kiem_am.dart` đếm số nhân âm nghe được rồi so với số từ; lệch quá thì đọc lại bằng
hạt giống khác, tối đa 5 lần, cuối cùng lấy bản gần đúng nhất.

Cùng phép soi ấy chạy được **lúc nghe**, bật bằng nút "Kiểm tra trước khi phát" cạnh nút
hẹn giờ (`settings.soiAmKhiNghe`, mặc định tắt). Khác lúc xuất ở hai chỗ: chỉ đọc lại **2**
lần thay vì 5, và phép soi phải nằm trong **cả ba đường đọc** — đọc lúc phát, đọc trước
song song, đọc trước tuần tự. Chỉ soi ở đường phát thì các bản đọc lại mới sinh ra đúng lúc
cần nghe, tức là mất sạch tác dụng của việc đọc trước.

Vì sao 2 mà không phải 5: xuất file chạy nền nên chờ thêm vài giây không ai biết, còn lúc
nghe thì mỗi lượt đọc lại ăn thẳng vào quỹ thời gian đọc trước. Engine chạy ~3× thời gian
thực nên ba lượt đọc cho một đoạn đúng là mức hoà.

Trên máy tính chạy nhiều bản mô hình song song. Số worker chặn theo **cả số nhân lẫn RAM**
(`_bulkWorkers` trong `vieneu_engine.dart`) — mỗi worker tốn 575–815 MB thường trực và
đỉnh bộ nhớ của bộ giải mã âm tỉ lệ **bình phương** độ dài đoạn. Đừng nới trần này mà
không đo lại (`app/test/ram_pool_test.dart` in mức RAM ra để đọc bằng mắt).

### Khoá cảm ứng (Android)

`ui/khoa_man_hinh.dart` bọc **ngoài cùng**, ngoài cả `DieuKhienTayCam` — nó phải chắn được
cả thao tác đi qua tay cầm lẫn mọi thứ Navigator dựng lên. Dùng `AbsorbPointer` quanh nội
dung chứ không chỉ vẽ lớp phủ lên trên: lớp phủ chặn chạm ở chỗ nó vẽ, nhưng cử chỉ cuộn
vẫn lọt xuống danh sách bên dưới.

Hạ sáng đi qua `MainActivity.khoaManHinh`, chỉnh thuộc tính **cửa sổ** chứ không đụng cài
đặt hệ thống: khỏi xin quyền `WRITE_SETTINGS`, và Android tự trả độ sáng về khi ứng dụng
rời tiền cảnh nên app có bị buộc dừng lúc đang khoá thì máy cũng không kẹt ở mức tối.

Trạng thái khoá **không lưu xuống đĩa** — mở app lên mà thấy màn hình khoá sẵn thì người
dùng không hiểu chuyện gì.

### Tay cầm chơi game

`services/tay_cam.dart` giữ phần dùng chung (đổi trạng thái thô thành lệnh, chống rung,
giữ để lặp). Hai nguồn khác hẳn nhau: Windows hỏi XInput 60 lần/giây
(`tay_cam_windows.dart`), Android nhận `KeyEvent`/`MotionEvent` từ `MainActivity.kt`.
`ui/dieu_khien_tay_cam.dart` bọc **ngoài** Navigator gốc nên lái được cả hộp thoại và
bottom sheet.

## Cạm bẫy

**ĐỪNG chép `libonnxruntime.so` vào `jniLibs/`.** ONNX Runtime đến từ gói `sherpa_onnx` và
cả hai engine dùng chung. Thêm bản thứ hai thì build vẫn xanh nhưng engine Giọng nhẹ chết
im lặng trên Android — hai file cùng SONAME, chỉ một bản sống sót, mà
`libsherpa-onnx-c-api.so` nhập symbol có gắn version. Windows không dính vì PE không có
symbol versioning. Xem comment dài trong `app/android/app/build.gradle.kts`.

**`libc++_shared.so` PHẢI nằm trong `jniLibs/arm64-v8a/`.** Engine v2 kéo llama.cpp (C++)
vào thư viện Rust, nên `libsachnoi_vieneu.so` cần runtime C++ của NDK. Thiếu nó thì build
vẫn xanh, APK vẫn cài được, chỉ đến lúc nạp engine mới vỡ:
`dlopen failed: library "libc++_shared.so" not found`. Chép từ
`<ndk>/toolchains/llvm/prebuilt/<host>/sysroot/usr/lib/aarch64-linux-android/`.

Đây là ngoại lệ của quy tắc ngay bên dưới, và ngoại lệ có điều kiện: hiện **không gói nào
khác** trong APK mang file này (sherpa-onnx liên kết tĩnh runtime C++ của nó). Nếu sau này
có thêm một gói mang theo bản riêng thì lại đúng cái bẫy trùng SONAME — lúc ấy phải chuyển
sang liên kết tĩnh (`ANDROID_STL=c++_static`) thay vì mang hai bản.

**Thêm icon mới thì phải `flutter clean` rồi build lại.** Flutter cắt font icon xuống chỉ
còn những glyph nó phát hiện được (bản dựng chở ~9 KB thay vì 1,6 MB của font gốc), nhưng
bản dựng **tăng dần không làm mới** phần cắt ấy — icon vừa thêm sẽ không có glyph và hiện
ra thành khoảng trống. Nút vẫn bấm được, tooltip vẫn chạy, chỉ là không thấy gì.

Đã mất bốn lượt đổi icon và đổi cả kiểu widget mới lần ra: `verified_rounded`,
`check_circle`, rồi `bolt_outlined` đều "không vẽ", trong khi icon cũ trong cùng file thì
bình thường. Cách kiểm nhanh: so kích thước
`build/windows/x64/runner/Release/data/flutter_assets/fonts/MaterialIcons-Regular.otf`
trước và sau khi build sạch — nó phải to ra khi có icon mới.

**Bản Android không có libopus/libmp3lame.** `native/vieneu/Cargo.toml` khai chúng theo
`cfg(not(target_os = "android"))`; Android dùng MediaCodec của hệ điều hành. Đừng thêm
dependency mã C vào phần dùng chung mà chưa thử cross-compile.

**Hạt giống phải suy từ nội dung đoạn.** Nếu không thì mỗi lần đọc lại ra một giọng khác và
bộ nhớ đệm mất hết ý nghĩa.

**Không dùng GPU.** Mô hình xuất ONNX với batch cố định bằng 1; card rời còn chậm hơn CPU
(1,83× so với 2,94×).

**Đổi tên ứng dụng là đổi thư mục dữ liệu** trên Windows (path_provider lấy từ ProductName
trong exe). `Storage.migrateLegacyRoot` dời dữ liệu sang — thêm tên cũ vào `_legacyDirNames`
nếu đổi tên lần nữa, không thì người dùng mở lên thấy thư viện trống.

**`native/vieneu/.cargo/config.toml` gán cứng đường dẫn NDK** (`.../ndk/28.2.13676358/...`).
Máy khác NDK hoặc khác phiên bản thì phải sửa file này trước khi cross-compile Android.

## Bản quyền

Mô hình VieNeu-TTS theo giấy phép **CC BY-NC 4.0** — phi thương mại và phải ghi công tác
giả. Hai giọng *Latradio* và *Việt Sử* trong `app/assets/giong.json` nhân bản từ bản ghi
của người khác: dùng riêng thì được, phát hành công khai phải xin phép.
