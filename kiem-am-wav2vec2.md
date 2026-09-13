# Kiểm âm bằng wav2vec2

Bộ kiểm nhận WAV, nhận dạng âm vị, rồi đếm nhân nguyên âm. Phần đếm năng lượng/đỉnh sóng cũ
đã được gỡ. Văn bản gốc chỉ dùng sau nhận dạng để so số âm tiết; không đưa vào mô hình để
ép kết quả khớp sẵn.

## Cách dùng

Tại **Cài đặt → Kiểm âm · wav2vec2**, tải mô hình khoảng 122 MB. Khi nghe, bật **Kiểm tra
trước khi phát**; mặc định tắt. Khi xuất, mọi đoạn được kiểm nếu đã có mô hình. Nhận dạng
chạy offline trong một isolate, dùng chung ONNX Runtime với các engine hiện có, kể cả Android.
Không cần Python, PyTorch hay thêm một bản `libonnxruntime.so` vào ứng dụng.

Thiếu mô hình, DLL cũ không có cổng kiểm âm, hoặc WAV lỗi đều trở thành **chưa kiểm**. Ứng dụng
vẫn phát/xuất nhưng không coi là đã đạt và không bắt TTS đọc lại vì lỗi nhận dạng. Nhật ký xuất
lưu riêng số đoạn chưa kiểm, số âm nghe được và chuỗi âm vị; các job.json cũ vẫn đọc được.

Hai VieNeu được đọc lại tối đa 2 lần khi nghe, 5 lần khi xuất. Matcha/Piper/hệ thống vẫn kiểm
được nhưng không đọc lại vì bản đọc mới không khác bản cũ. Nếu nhận dạng lỗi sau một lượt đã
kiểm thành công, giữ bản đã kiểm tốt nhất. Thay bộ kiểm không đổi âm TTS, nên không tăng phiên
bản cache âm thanh và không buộc tổng hợp lại sách.

## Mô hình và nguồn gốc

- ONNX: [galamkhoahoc/wav2vec2-vi-phone-ONNX](https://huggingface.co/galamkhoahoc/wav2vec2-vi-phone-ONNX).
- Revision cố định: `ded9b63317d3efdb0d0422fd05592efb43cdee10`.
- Theo manifest của bản ONNX, mô hình gốc là
  [tuanio/wav2vec2-base-finetune-vi_phone-non_freeze-spec_aug-500epoch](https://huggingface.co/tuanio/wav2vec2-base-finetune-vi_phone-non_freeze-spec_aug-500epoch).
- `model_quantized.onnx`: 122435778 byte, SHA-256
  `c4c7503ce9c0ab43cdb31fb8b5a6cb1fc1d0693281ac9bc473cdf6cee09e8a29`.
- `phonemes.json`: 1636 byte, SHA-256
  `71616f1fad5bb7224c45852eaa629837635523f8c02d9dedcf89ea3c2b737181`.

Ứng dụng tải bản sao nguyên vẹn tại [sach-luoi-models · v1](https://github.com/ducvd89/sach-luoi-models/releases/tag/v1),
cùng nơi với các mô hình giọng nói. Hai asset là `wav2vec2-vi-phone-model_quantized.onnx`
và `wav2vec2-vi-phone-phonemes.json`; khi cài được lưu bằng tên gốc ở trên. Dung lượng và
SHA-256 được xác minh trước khi đánh dấu hoàn tất. File tải dở luôn mang đuôi `.part`;
tải lại dùng tiếp những file đã đủ và đúng hash. Bản đã tải từ Hugging Face vẫn dùng được,
không cần tải lại. Nguồn gốc và revision được giữ để đối chiếu; hai kho âm vị gốc chưa
công bố giấy phép tại thời điểm tích hợp, nên không gán cho trọng số giấy phép của ứng dụng.

## Cách đếm

WAV được đưa về mono 16 kHz, chuẩn hoá trung bình 0 và phương sai 1 với epsilon `1e-7`.
Mô hình nhận `input_values` float32 và trả `logits` `[1, số_khung, 123]`. Bộ giải CTC chọn
nhãn có điểm cao nhất từng khung, gộp nhãn lặp liên tiếp rồi bỏ blank 0. Thứ tự này quan
trọng: `a-0, blank, a-0` là **hai** âm, không được gộp thành một.

Trong bảng của mô hình, nguyên âm mang thanh điệu (`a-0`, `iə-3`, `ɨə-5`…) là một nhân âm;
nguyên âm đôi vẫn chỉ tính một. Bán nguyên âm cuối `iz`, `uz` và phụ âm không được tính.
Chuỗi âm vị được giữ trong nhật ký để có thể đối chiếu khi mô hình nhận sai.

Đoạn dài chia theo lưới khung 20 ms: giữ 6 giây ở giữa và thêm tối đa 1 giây ngữ cảnh mỗi
bên. Ghép mã khung của các phần giữa rồi mới giải CTC một lần, tránh đếm đôi âm tại biên.
Cửa sổ suy luận tối đa khoảng 8 giây; không gửi toàn bộ sách vào mạng cùng lúc.

Hai VieNeu đổi tốc độ xuất bằng lấy mẫu lại nên cần khôi phục cao độ trước nhận dạng.
Matcha, Piper và TTS hệ thống giữ cao độ nên không áp phép khôi phục này. Tốc độ phát khi
nghe không ảnh hưởng vì WAV cache vẫn ở nhịp tổng hợp 1×.

Ngưỡng đạt là **100–110% số âm dự kiến (expected)** cho mọi câu, không có ngoại lệ ±1 âm
ở câu ngắn và không làm tròn phần trăm khi chấm. Ví dụ expected 20 thì chỉ 20–22 âm đạt;
thiếu một âm cũng không đạt. WAV không nhận ra âm nào không đạt nếu văn bản có tiếng.

Expected cộng số âm của từng từ: tiếng Việt thường một âm, tiếng Anh dùng số âm tiết dự
đoán theo nhóm nguyên âm và các luật âm câm. Ví dụ “mở Windows lên” = 1 + 2 + 1 = 4 âm.
Nếu xuất phát từ số từ thì chỉ cộng phần âm vượt một của từ Anh, tránh đếm trùng. Thẻ
`<en>` không tạo thêm âm. Cách dự đoán này đã nằm trong `demAmChu` và dùng chung khi nghe/xuất.

Mô hình vẫn có thể nghe sai tên nước ngoài, giọng lạ hoặc tiếng ồn; phần dự đoán tiếng Anh
cũng có sai số. Một từ sai có cùng số âm vẫn có thể đạt. Đây không phải phép xác minh
nội dung từng từ.

## Kiểm chứng

Đã chạy qua Dart → isolate → DLL Rust → ONNX trên Windows, câu Matcha 22 âm tiết:

| Bản WAV | Số âm nhận dạng |
|---|---:|
| Nguyên câu | 22 |
| Cắt nửa | 11 |
| Lặp hai lần | 44 |
| Lặp năm lần, qua nhiều cửa sổ | 110 |

Cũng kiểm im lặng ở 16/22,05/24/48 kHz, khôi phục tốc độ 1,5×, WAV lỗi và tiếp tục dùng
isolate sau lỗi. Đây là một bộ mẫu hồi quy, không phải số đo độ chính xác trên toàn bộ sách.
Chưa đo tốc độ và RAM trên điện thoại Android thật.

Chạy kiểm thử thuần từ `app/`:

```powershell
flutter test test/kiem_am_test.dart test/soi_am_khi_nghe_test.dart test/xuat_doc_lai_test.dart test/nhat_ky_soi_am_test.dart test/kho_wav2vec2_test.dart
```

Kiểm thử mô hình thật cần build lại thư viện Rust trước, và đặt biến môi trường:

```powershell
$env:MO_HINH_KIEM_AM = '<thư mục chứa model_quantized.onnx và phonemes.json>'
$env:WAV_KIEM_AM = '<WAV tiếng Việt PCM16 mono>'
$env:LOI_KIEM_AM = '<lời gốc chính xác của WAV>'
$env:ORT_DYLIB_PATH = '<đường dẫn ONNX Runtime>'
flutter test test/wav2vec2_that_test.dart
```

Để kiểm cả tải thật từ GitHub, đặt `TAI_MO_HINH_KIEM_AM=1` và trỏ `MO_HINH_KIEM_AM`
vào thư mục rỗng. Bài thử đi qua bộ tải của app, xác minh SHA-256, rồi nhận dạng bằng
chính file vừa tải.

Nếu thiếu các đầu vào đó, bài mô hình thật báo bỏ qua rõ ràng. Công cụ Rust độc lập:

```powershell
# Từ native/vieneu
cargo run --release --example thu_kiem_am -- '<thư mục mô hình>' '<file.wav>'
```
