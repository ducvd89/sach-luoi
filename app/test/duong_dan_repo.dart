/// Đường dẫn tới các file nằm ngoài gói `app/` mà một số bài test cần tới:
/// thư viện Rust vừa build, từ điển âm vị, mẫu giọng.
///
/// Trước đây mỗi bài tự gán cứng đường dẫn tuyệt đối trên máy tác giả, nên đem
/// repo đặt ở chỗ khác là mọi bài cần mô hình đều lặng lẽ bị bỏ qua — trông
/// như "chạy xanh" trong khi thật ra không kiểm gì cả. Suy từ thư mục đang chạy
/// thì đặt repo ở đâu cũng đúng.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// Gốc của repo. `flutter test` chạy với thư mục hiện hành là gói `app/`, nên
/// lùi một cấp là ra.
final String repoRoot = p.normalize(p.join(Directory.current.path, '..'));

/// Thư viện Rust chạy mô hình VieNeu — có sau `cargo build --release` trong
/// `native/vieneu/`.
final String vieneuLibPath = p.join(
  repoRoot,
  'native',
  'vieneu',
  'target',
  'release',
  Platform.isWindows ? 'sachnoi_vieneu.dll' : 'libsachnoi_vieneu.so',
);

/// Thư viện Rust chuyển chữ sang âm vị — có sau `cargo build --release` trong
/// `native/sea-g2p/`.
final String seaG2pLibPath = p.join(
  repoRoot,
  'native',
  'sea-g2p',
  'target',
  'release',
  Platform.isWindows ? 'sea_g2p_rs.dll' : 'libsea_g2p_rs.so',
);

/// Thư mục assets của ứng dụng (từ điển âm vị, hồ sơ giọng).
final String assetsDir = p.join(repoRoot, 'app', 'assets');

/// Thư mục script Python chuẩn bị dữ liệu.
final String ttsServiceDir = p.join(repoRoot, 'tts_service');
