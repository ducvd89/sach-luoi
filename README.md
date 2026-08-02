# 📖 Sách lười

Ứng dụng **Windows và Android** chuyển sách **EPUB / TXT** thành **sách nói tiếng Việt**. Nghe trực
tiếp trong ứng dụng hoặc xuất ra file, tự lưu tiến trình để lần sau mở lên nghe tiếp đúng chỗ cũ.

Mọi thứ chạy **hoàn toàn trên máy**: không cần mạng, không gửi sách đi đâu, không cần cài Python.
Mô hình giọng nói chạy trong chính tiến trình của ứng dụng qua ONNX Runtime.

---

## Cài đặt

**Windows** — chạy bộ cài `SachLuoi-Setup-1.3.0.exe` (~33 MB). Không cần quyền quản trị: nó cài vào
`%LOCALAPPDATA%\Programs\SachLuoi`, tạo lối tắt Start Menu và trình gỡ cài. Lúc gỡ có **hỏi riêng**
trước khi xoá thư viện sách — mặc định giữ lại.

**Android** — cài `SachLuoi-android-arm64.apk` (~78 MB). Cần Android 7 trở lên, máy 64-bit.

Sau khi cài, mở *Cài đặt → Giọng đọc* và bấm **Tải mô hình (206 MB)** một lần. Từ đó đọc được kể cả
khi bật chế độ máy bay.

---

## Giọng đọc

Hai engine, đổi qua lại trong **Cài đặt**:

| | VieNeu-TTS | Giọng nhẹ (Piper) |
|---|---|---|
| Chạy ở đâu | ngay trong ứng dụng | ngay trong ứng dụng |
| Cần mạng | không | không |
| Windows / Android | cả hai | cả hai |
| Giọng | **14 giọng dựng sẵn** + giọng bạn tự thêm | 3 gói tải sẵn |
| Vùng miền | Bắc, Trung, Nam | Bắc |
| Chất lượng | cao nhất (48 kHz) | khá, hơi máy (22 kHz) |
| Tốc độ | ~2–3× thời gian thực | nhanh hơn nhiều |
| Dung lượng tải | 206 MB | 21–64 MB mỗi gói |
| File xuất ra | Opus / MP3 / WAV¹ | Opus / MP3 / WAV¹ |
| Giấy phép | CC BY-NC 4.0 — phi thương mại² | Apache-2.0 / MIT |

¹ Chọn trong *Xuất file → Định dạng file*: **Opus 32 kbps** (mặc định, nhỏ nhất), Opus 64 kbps,
  MP3 128 kbps, hoặc WAV không nén. Đo trên một file thật 29,9 phút: WAV 164 MB · Opus 32k 6,8 MB ·
  Opus 64k 14 MB · MP3 128k 27 MB. Opus nhỏ hơn hẳn ở cùng chất lượng vì nó thiết kế cho dải bitrate
  thấp; MP3 giữ lại vì đầu đĩa và dàn xe hơi cũ chỉ đọc được nó. Trên **Android** việc nén do `MediaCodec`
  của hệ điều hành làm, không thêm gì vào APK: Opus cần Android 10 trở lên, còn chọn MP3 thì file ra
  là `.m4a` (AAC) vì Android không có bộ mã hoá MP3.
² Mô hình và bộ giọng của VieNeu-TTS chỉ dùng cho mục đích phi thương mại và cần ghi công tác giả
  (Phạm Nguyễn Ngọc Bảo — pnnbao-ump). Mỗi đoạn âm thanh sinh ra đều được đóng dấu chìm.

> **Về hai giọng thêm sẵn trong repo.** Ngoài 14 giọng của VieNeu, `app/assets/giong.json` còn hai
> giọng *Latradio* và *Việt Sử* được nhân bản từ bản ghi của người khác, kèm file mẫu trong
> `tts_service/voices/`. Đây là giọng của người thật: dùng riêng để nghe sách thì được, còn phát
> hành hay dùng vào việc gì công khai thì phải xin phép chủ giọng trước. Muốn bỏ hai giọng này thì
> xoá hai mục tương ứng trong `giong.json` và hai file wav.

**Chọn cái nào:** VieNeu cho gần như mọi trường hợp. Giọng nhẹ khi máy yếu, khi không muốn tải
206 MB, hoặc khi cần đọc thật nhanh một cuốn dài.

### 14 giọng dựng sẵn của VieNeu

Mỗi giọng đi kèm một phong cách đọc:

| Phong cách | Giọng |
|---|---|
| Kể chuyện (hợp sách nói nhất) | Thái Sơn (nam Nam), Thanh Bình (nam Bắc), Ngọc Linh (nữ Bắc), Thục Đoan (nữ Nam) |
| Tự nhiên | Phạm Tuyên (nam Bắc), Xuân Vĩnh (nam Nam), Quang Sơn (nam Trung), Trúc Ly (nữ Bắc), Đoan Trang (nữ Bắc), Ngọc Trân (nữ Trung) |
| Tin tức | Minh Đức (nam Bắc), Minh Triết (nam Nam), Mai Anh (nữ Bắc), Thùy Dung (nữ Nam) |

### Thêm giọng của riêng bạn

*Cài đặt → Giọng đọc → **Thêm giọng từ file ghi âm***. Chọn một file `.wav` dài 3–15 giây, một
người nói rõ, không nhạc nền, rồi đặt tên. **Không cần chép lời** — bản v3 nhân bản thẳng từ sóng âm.

Giọng tự thêm có nút xoá bên cạnh; 14 giọng dựng sẵn thì không xoá được.

Lần đầu thêm giọng sẽ tải thêm ~70 MB (bộ mã hoá giọng và bộ mã hoá âm) — ai không thêm giọng thì
khỏi tốn. Toàn bộ việc nhân bản chạy trên máy, kể cả trên điện thoại.

Bản ghi dài hoặc có nhạc/quãng lặng thì cắt sẵn bằng script kèm theo — nó chọn đoạn có tiếng nói
liền mạch nhất, trộn về mono và cân bằng âm lượng:

```
cd tts_service
.venv-vieneu\Scripts\python.exe them_giong.py "D:\ghi-am.wav" voices\TenGiong.wav
```

### Dọn quảng cáo của trang đăng truyện

Bật sẵn ở *Cài đặt → Cách đọc*. Sách tải trên mạng gần như luôn kèm thứ không phải nội dung:

- tên trang web, tên sách, tên tác giả lặp ở **đầu mỗi chương**
- dòng ghi công người dịch/convert, lời kêu gọi ủng hộ ở cuối chương
- trang bìa liệt kê "Tác giả: … Thể loại: … Nguồn: …"
- **cả một chương mục lục** — thứ tốn thời gian nhất, vì nó là danh sách hàng nghìn tên chương

Nhận rác bằng hai cách bổ sung nhau: theo mẫu quen thuộc (tên miền, "Nguồn:", "Converter:",
"Đọc truyện tại…", dòng trang trí), và theo tần suất — dòng ngắn nào lặp ở rìa của trên 40% số
chương thì gần như chắc chắn là rác, kể cả khi trang web đó chưa từng biết tên. Chỉ xét vài dòng
đầu và cuối mỗi chương, và không bao giờ dọn tới mức trắng chương hay trắng sách.

Đo trên hai bộ truyện thật:

| Sách | Bỏ được | Tiết kiệm |
|---|---|---|
| Phàm Nhân Tu Tiên (2.467 chương) | 1 chương mục lục + 7.474 dòng header | ~3 giờ 39 phút |
| Mô Phỏng Tội Phạm (50 chương) | 1 mục lục + 1 trang bìa | ~49 phút |

Sách nhập từ trước khi bật thì bấm nút hình cây chổi trên thẻ sách trong Thư viện để dọn lại từ
file gốc — giữ nguyên chỗ đang nghe.

### Khoảng nghỉ giữa các đoạn

*Cài đặt → Cách đọc → Khoảng nghỉ giữa các đoạn* (mặc định **0,9 giây**, kéo được tới 2 giây; hết
một tiêu đề chương thì nghỉ gấp 1,8 lần). Con số này chọn theo số đo chứ không theo cảm giác: nhịp
nghỉ mà mô hình tự sinh ra giữa hai câu có trung vị 0,23 s và **dài nhất 0,50 s**, nên khoảng nghỉ
giữa đoạn phải vượt hẳn khỏi dải đó mới nghe ra là ranh giới đoạn. Bản 1.0.1 đặt 0,55 s — chỉ hơn
cái nghỉ dài nhất giữa hai câu 0,05 s, nghe như các đoạn dính liền nhau. Khoảng nghỉ được chèn lúc phát và lúc ghép file chứ không nằm trong âm thanh đã
tổng hợp, nên kéo thanh trượt là nghe khác ngay, không phải đọc lại cuốn sách và không mất bộ nhớ
đệm đã có.

---

## Tính năng

**Đọc sách** — EPUB (v2 và v3) và TXT (tự nhận UTF-8/UTF-16, có hay không BOM). Chương lấy từ mục lục
EPUB, hoặc tự nhận "Chương 1", "Phần II", "# Tiêu đề" trong file TXT. Tự bỏ chú thích cuối trang,
đường link và ký tự rác.

**Chuẩn hoá tiếng Việt trước khi đọc** (tắt được trong Cài đặt) — máy đọc vấp nhiều nhất ở chỗ này:

| Văn bản gốc | Được đọc thành |
|---|---|
| `1.234.567` | một triệu hai trăm ba mươi tư nghìn năm trăm sáu mươi bảy |
| `12,5%` | mười hai phẩy năm phần trăm |
| `20/11/1954` | ngày hai mươi tháng mười một năm một nghìn chín trăm năm mươi tư |
| `10:30` | mười giờ ba mươi |
| `Chương IV`, `VI.` | Chương bốn, Sáu |
| `PGS.TS`, `NXB`, `tr. 25` | Phó giáo sư tiến sĩ, Nhà xuất bản, trang hai mươi lăm |
| `250.000đ`, `35°C`, `21km` | hai trăm năm mươi nghìn đồng, ba mươi lăm độ C, hai mươi mốt ki lô mét |

**Nghe** — văn bản hiện bên cạnh, đoạn đang đọc được tô sáng và tự cuộn theo; bấm vào đoạn nào là
nhảy tới đó. Tua ±15 giây, kéo thanh tiến trình trên toàn bộ sách, hẹn giờ tắt 10–60 phút.
Trên điện thoại có thanh chương mở lên từ dưới để nhảy tới chương bất kỳ.
Phím tắt trên máy tính: `Space` phát/dừng · `←` `→` tua · `↑` `↓` chuyển đoạn.

Đổi tốc độ (0.75×–2.0×) có hiệu lực ngay vì áp vào lúc phát, không phải tạo lại âm thanh.

**Điều khiển ngoài ứng dụng (Android)** — sách đang nghe hiện ở phần "Đang phát" của hệ điều hành:
điều khiển được từ màn hình khoá, từ khu thông báo và bằng nút trên tai nghe. Thanh tua trong thông
báo tính theo cả cuốn sách.

**Xuất file** — chọn độ dài mỗi file (5–120 phút), hoặc mỗi chương một file, hoặc gộp tất cả làm một.
Chọn xuất từ chương nào đến chương nào. Có tuỳ chọn *ưu tiên kết thúc file ở cuối chương*.

Trên máy tính, việc xuất file chạy **nhiều đoạn cùng lúc**: ứng dụng mở thêm vài bản mô hình, mỗi
bản một luồng riêng. Đo trên máy 12 nhân — 2,87× thời gian thực khi chạy một luồng, **8,94×** khi
chạy sáu luồng, tức sách 10 giờ mất hơn một tiếng thay vì ba tiếng rưỡi. Số luồng lấy theo số nhân
của máy, tối đa sáu. Chỉ bật lúc xuất file: nghe trực tiếp một luồng đã nhanh hơn tốc độ nghe, mở
thêm chỉ tốn RAM (mỗi bản mô hình khoảng 250 MB) và làm máy nóng. Điện thoại luôn giữ một luồng.

Không dùng GPU. Lý do nằm ở chỗ mô hình được xuất ra ONNX với chiều batch **cố định bằng 1** — GPU
chỉ thắng khi gộp được nhiều đoạn vào một lượt, mà đồ thị hiện tại không cho gộp; chạy từng đoạn
một thì card rời còn chậm hơn CPU (đo được 1,83× so với 2,94×).

**Lưu tiến trình**

- *Nghe*: lưu tự động mỗi 10 giây, khi tạm dừng và khi đóng ứng dụng — mở lại là nghe tiếp
  đúng giây đang dở.
- *Xuất file*: tạm dừng lúc nào cũng được, kể cả tắt hẳn ứng dụng rồi bật lại. Bấm *Chạy tiếp* là
  làm tiếp từ đúng chỗ; phần đã xong không phải làm lại.
- *Bộ nhớ đệm*: mỗi đoạn âm thanh đã tạo được giữ lại, nên nghe lại hoặc xuất file sau khi đã nghe
  gần như tức thì. Trần dung lượng chọn trong *Cài đặt → Dữ liệu*: 100 MB, 200 MB, 500 MB (mặc
  định), 1 GB hoặc *Không hạn*. Vượt trần thì đoạn lâu không nghe bị xoá trước — đoạn vừa nghe
  được đánh dấu là mới nên sống lâu hơn đoạn của cuốn sách bỏ dở. Xoá rồi nghe lại thì máy đọc
  lại đoạn đó, chỉ mất thời gian chứ không mất dữ liệu. Chọn *Không hạn* sẽ hiện cảnh báo đỏ:
  ứng dụng không tự dọn nữa và bộ đệm có thể ngốn vài GB.

---

## Cấu trúc dự án

```
app/                     Ứng dụng Flutter (Windows + Android)
  lib/
    core/                Logic thuần, không phụ thuộc giao diện
      vi_number.dart       đọc số thành chữ (một nghìn, hai mươi mốt, ba mươi tư…)
      text_normalizer.dart chuẩn hoá tiếng Việt trước khi đọc
      boilerplate.dart     bỏ quảng cáo, tên trang web và mục lục của sách tải trên mạng
      chunker.dart         cắt sách thành đoạn theo ranh giới câu
      epub_parser.dart     EPUB -> danh sách chương
      txt_parser.dart      TXT -> danh sách chương, đoán bảng mã
      mp3.dart             đo thời lượng, thẻ ID3, khung im lặng — không cần ffmpeg
      wav.dart             dựng/ghép WAV cho engine chạy trong ứng dụng
    models/              Book, Chunk, Progress, ExportJob, AppSettings, WorkProgress
    services/
      library_service.dart   thư viện sách và tiến trình nghe
      import_worker.dart     phân tích sách ở isolate nền + báo tiến trình
      player_controller.dart điều khiển phát, tổng hợp trước, lưu vị trí
      export_service.dart    xuất file, tạm dừng và chạy tiếp
      media_session.dart     đưa sách lên phần "Đang phát" của hệ điều hành
      tts/
        tts_engine.dart      giao diện chung cho các engine
        vieneu_native.dart   nạp thư viện Rust, chạy mô hình ở isolate riêng
        vieneu_engine.dart   engine VieNeu: liệt kê giọng, đọc, thêm/xoá giọng
        model_store.dart     tải và quản lý bộ file mô hình
        ondevice_engine.dart giọng nhẹ Piper (sherpa-onnx, isolate riêng)
        voice_pack.dart      tải và quản lý gói giọng Piper
        sea_g2p.dart         binding Dart cho bộ chuyển chữ sang âm vị
        tts_manager.dart     chọn engine + bộ nhớ đệm
    ui/                  Các màn hình
  assets/
    sea_g2p.bin          từ điển âm vị tiếng Việt (48 MB)
    giong.json           hồ sơ 16 giọng: đặc trưng giọng + mã tham chiếu
  android/app/src/main/jniLibs/arm64-v8a/
    libonnxruntime.so    ONNX Runtime bản chính thức của Microsoft
    libsachnoi_vieneu.so engine VieNeu
    libsea_g2p_rs.so     chuyển chữ sang âm vị
  test/                  Kiểm thử logic, engine và kiểm thử đầu-cuối

native/                  Mã Rust — chạy mô hình mà không cần Python
  vieneu/                engine VieNeu
    src/model.rs           nạp mô hình, embedding, các đầu ra, lấy mẫu
    src/engine.rs          vòng sinh: prefill, decode_step, acoustic, giải mã âm
    src/enroll.rs          nhân bản giọng từ file .wav
    src/fbank.rs           Kaldi fbank + lấy mẫu lại (khớp torchaudio)
    src/npz.rs             đọc trọng số .npz của numpy
    src/ffi.rs             cổng C cho Dart
  sea-g2p/               bản fork của sea-g2p, thêm cổng C (xem mục Ghi công)

tts_service/             Công cụ chuẩn bị dữ liệu, KHÔNG cần để chạy ứng dụng
  nap_giong.py           tính sẵn hồ sơ 16 giọng -> app/assets/giong.json
  them_giong.py          cắt một bản ghi dài thành mẫu 3-15 giây
  sinh_mau_am_vi.py      sinh dữ liệu đối chiếu âm vị cho bài test
  doc_wav.py             vá torchaudio 2.11 để đọc được .wav mà không cần torchcodec
  Cai-dat-cong-cu-python.bat (ở thư mục gốc) dựng môi trường Python cho ba script trên

dong-goi.ps1             build bản release, dựng dist\SachLuoi\ rồi tạo bộ cài
installer.iss            kịch bản Inno Setup cho bộ cài Windows
```

---

## Phát triển

Dựng thư viện Rust trước (cần [Rust](https://rustup.rs)):

```bash
cd native/vieneu && cargo build --release
cd ../sea-g2p && cargo build --release
```

Chạy ứng dụng:

```bash
cd app && flutter run -d windows
```

Kiểm thử. Các bài cần mô hình sẽ tự bỏ qua nếu chưa có; muốn chạy đủ thì trỏ `ORT_DYLIB_PATH` vào
một bản ONNX Runtime:

```bash
cd app && flutter test
```

Đóng gói bản Windows (kèm bộ cài nếu có Inno Setup):

```bash
powershell -ExecutionPolicy Bypass -File dong-goi.ps1
```

Dựng APK. Cần Android SDK + NDK; thư viện Rust cho aarch64 phải build trước và chép vào `jniLibs/`:

```bash
cd native/vieneu && cargo build --release --target aarch64-linux-android
cp target/aarch64-linux-android/release/libsachnoi_vieneu.so ../../app/android/app/src/main/jniLibs/arm64-v8a/
cd ../../app && flutter build apk --release --target-platform android-arm64
```

Cập nhật hồ sơ giọng sau khi thêm file .wav vào `tts_service/voices/`:

```bash
cd tts_service && .venv-vieneu\Scripts\python.exe nap_giong.py
copy voices\giong.json ..\app\assets\giong.json
```

---

## Ghi chú kỹ thuật

**Vì sao có mã Rust.** Mô hình VieNeu không trả về âm thanh trong một lần gọi: nó sinh từng khung,
12,5 khung cho mỗi giây âm thanh, và giữa hai lần gọi phải tra embedding, chạy 16 phép nhân ma trận
768×1024, lấy mẫu token rồi đẩy KV cache. Đồ thị mạng do ONNX Runtime lo, nhưng phần logic quanh nó
thì bản gốc viết bằng numpy. Đặt phần đó ở Rust chạy nhanh ngang numpy; để ở Dart thì vòng lặp nóng
này chậm hơn vài lần. Dart chỉ gọi đúng một hàm: `vieneu_synthesize(text, voice) → mẫu âm`.

**Mọi thứ nặng nằm ở isolate riêng.** Nạp mô hình mất hơn một giây, đọc một đoạn mất vài giây. Cả
hai engine đều chạy trong isolate nền sống suốt phiên — nạp một lần rồi phục vụ mọi yêu cầu, còn
isolate giao diện không bao giờ bị chặn. Việc nhập sách (giải nén EPUB, cắt đoạn, chuẩn hoá) cũng
vậy.

**Nhân bản giọng phải khớp từng con số.** Đặc trưng giọng đi qua Kaldi fbank rồi mới tới mô hình.
Sai một chi tiết trong fbank hay trong bộ lấy mẫu lại thì giọng nhân bản nghe không giống mẫu, mà
nhìn mã nguồn chẳng thấy gì sai. Nên `fbank.rs` được đối chiếu với torchaudio tới khi đặc trưng
trích ra đạt **cosine 1,0000** — chỗ lệch cuối cùng hoá ra nằm ở cửa sổ của bộ lấy mẫu lại
(Kaiser rộng 64, chặn tần 0,95).

**Kết quả phải ổn định giữa các lần chạy.** Mô hình sinh có lấy mẫu ngẫu nhiên, nên hạt giống được
suy từ nội dung đoạn — nếu không, mỗi lần đọc lại ra một giọng khác và bộ nhớ đệm mất hết ý nghĩa.

**VieNeu tự lo phần cắt câu.** Thư viện chuẩn hoá rồi cắt đoạn dài thành từng mảnh ≤256 ký tự và
chèn khoảng lặng theo đúng loại ranh giới, nên ứng dụng đưa nguyên đoạn ~400 ký tự vào chứ không
cắt sẵn — cắt sẵn chỉ làm nhịp đọc vụn hơn.

**Khoảng nghỉ nằm ngoài âm thanh đã tổng hợp.** Lúc phát thì hẹn giờ, lúc xuất file thì chèn khung
im lặng dựng từ chính header của luồng đang ghép (`core/mp3.dart`) hoặc mẫu 0 với WAV. Nhờ vậy đổi
khoảng nghỉ không làm hỏng bộ nhớ đệm.

**Chỉ arm64 trên Android.** Thư viện Rust chỉ dựng cho kiến trúc này; bản 32-bit hay x86 sẽ cài
được mà không đọc được, nên chúng bị loại thẳng ở bước đóng gói.

---

## Ghi công

- [**VieNeu-TTS**](https://github.com/pnnbao97/VieNeu-TTS) — Phạm Nguyễn Ngọc Bảo (pnnbao-ump).
  Bản dùng ở đây là v3 Turbo (48 kHz), đồ thị ONNX lượng tử hoá int8. Mô hình và bộ giọng theo giấy
  phép **CC BY-NC 4.0**: phi thương mại, và nhớ ghi công tác giả.
- [**sea-g2p**](https://github.com/pnnbao97/sea-g2p) — cùng tác giả, Apache-2.0. Bản trong
  `native/sea-g2p/` là fork từ v0.7.20, **chỉ thêm** một cổng C (`src/ffi.rs`) và tách chế độ build
  để cùng mã nguồn vừa dựng được bản Python vừa dựng được thư viện cho Android. Lõi xử lý ngôn ngữ
  giữ nguyên không sửa.
- [**MOSS-Audio-Tokenizer-Nano**](https://huggingface.co/OpenMOSS-Team/MOSS-Audio-Tokenizer-Nano) —
  OpenMOSS Team, bộ mã/giải mã âm thanh 48 kHz.
- [**Piper**](https://github.com/rhasspy/piper) chạy qua
  [**sherpa-onnx**](https://github.com/k2-fsa/sherpa-onnx) — giọng nhẹ, cùng bộ file mô hình cho
  Windows và Android.
- [**ONNX Runtime**](https://github.com/microsoft/onnxruntime) — Microsoft, MIT.

Hãy tôn trọng bản quyền sách bạn chuyển đổi và chỉ dùng cho mục đích cá nhân.
