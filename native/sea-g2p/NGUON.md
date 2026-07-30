# Nguồn gốc và phần đã sửa

Thư mục này là bản fork của [sea-g2p](https://github.com/pnnbao97/sea-g2p) v0.7.20 —
bộ chuyển chữ sang âm vị cho tiếng Đông Nam Á, tác giả **Phạm Nguyễn Ngọc Bảo**
(pnnbao97), giấy phép **Apache-2.0** (xem `LICENSE`).

Bản gốc chỉ phát hành binding PyO3 cho Python, mà điện thoại thì không có Python.
Fork này thêm một cổng C để gọi được từ Dart trên Android và iOS.

## Đã sửa những gì

| File | Thay đổi |
|---|---|
| `src/ffi.rs` | **Thêm mới** — 7 hàm `extern "C"` bọc quanh chuỗi việc mà `SEAPipeline.run` làm bên Python |
| `Cargo.toml` | Thêm hai feature `python` / `ffi`, để `cdylib` và `rlib` cùng dựng được |
| `src/lib.rs` | Gói phần PyO3 vào `#[cfg(feature = "python")]` |
| `src/vi_normalizer/mod.rs` | Đổi thuộc tính PyO3 sang `cfg_attr` để dựng được khi không có Python |
| `.cargo/config.toml` | **Thêm mới** — trỏ trình liên kết sang Android NDK |

**Lõi xử lý ngôn ngữ giữ nguyên, không sửa một dòng nào** — toàn bộ `src/g2p/`,
`src/punc.rs` và phần thân của `src/vi_normalizer/`.

Kết quả đã được đối chiếu với bản Python trên 12 câu (số, ngày tháng, đơn vị,
viết tắt, tỉ số): âm vị và văn bản chuẩn hoá **khớp từng ký tự**. Xem
`app/test/sea_g2p_test.dart`.

## Dựng lại

```bash
# Cho máy tính (Python vẫn dùng được bản gốc từ pip)
cargo build --release --no-default-features --features ffi

# Cho Android
cargo build --release --no-default-features --features ffi --target aarch64-linux-android
```

File từ điển `sea_g2p.bin` (~48 MB) không nằm trong repo này; lấy từ gói pip
`sea-g2p` và chép vào `app/assets/`.
