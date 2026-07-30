//! Chạy mô hình VieNeu-TTS v3 Turbo ngay trên máy, không cần Python.
//!
//! Bản gốc là một file numpy 577 dòng chạy cùng ONNX Runtime. Phần này dịch
//! sang Rust để chạy được trên điện thoại: đồ thị vẫn do ONNX Runtime lo, còn
//! những việc quanh nó — dựng prompt, tra embedding, các đầu ra, lấy mẫu, quản
//! lý KV cache — thì làm bằng mảng số thuần.
//!
//! Vì sao không để Dart làm phần quanh đó: mỗi giây âm thanh cần 12,5 khung,
//! mỗi khung 16 phép nhân ma trận 768×1024 cộng lấy mẫu. Đó là vòng chạy nóng,
//! đặt ở Rust thì nhanh ngang numpy, còn mảng typed của Dart chậm hơn vài lần.

// Bộ mã hoá khi xuất file — chỉ có trên máy tính, Android dùng MediaCodec.
#[cfg(not(target_os = "android"))]
pub mod ma_hoa;

pub mod engine;
pub mod enroll;
pub mod fbank;
pub mod ffi;
pub mod model;
pub mod npz;

/// Phiên bản cổng C, để Dart biết mình đang nói chuyện với bản nào.
pub const ABI_VERSION: i32 = 1;
