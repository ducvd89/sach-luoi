/// Nơi cất dữ liệu của ứng dụng và các hàm đọc/ghi JSON dùng chung.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class Storage {
  Storage._(this.root);

  static Storage? _instance;
  static Storage get instance {
    final value = _instance;
    if (value == null) throw StateError('Storage chưa được khởi tạo — gọi Storage.init() trước');
    return value;
  }

  final Directory root;

  /// Tên thư mục dữ liệu của các phiên bản trước, theo thứ tự mới đến cũ.
  ///
  /// Trên Windows, path_provider lấy đường dẫn từ ProductName ghi trong file
  /// exe. Đổi tên ứng dụng là đổi luôn thư mục — nếu không dời dữ liệu sang thì
  /// người dùng mở lên thấy thư viện trống trơn và phải tải lại mô hình 145 MB.
  static const _legacyDirNames = ['Sach noi tieng Viet'];

  /// [overrideRoot] chỉ dùng khi kiểm thử, để không đụng vào dữ liệu thật.
  static Future<Storage> init({Directory? overrideRoot}) async {
    final base = overrideRoot ?? await getApplicationSupportDirectory();
    if (overrideRoot == null) await migrateLegacyRoot(base);
    final storage = Storage._(base);
    for (final dir in [storage.booksDir, storage.cacheDir, storage.jobsDir]) {
      await dir.create(recursive: true);
    }
    return _instance = storage;
  }

  /// Dời dữ liệu của tên ứng dụng cũ sang [base] nếu [base] còn trống.
  ///
  /// Đổi tên thư mục nên xong tức thì kể cả khi bộ nhớ đệm đang nặng vài trăm
  /// MB. Thất bại thì bỏ qua: mất chỗ đang nghe còn đỡ hơn không mở được app.
  static Future<void> migrateLegacyRoot(Directory base) async {
    try {
      if (await base.exists() && !await base.list().isEmpty) return;
      final parent = base.parent;
      for (final name in _legacyDirNames) {
        final legacy = Directory(p.join(parent.path, name));
        if (legacy.path == base.path || !await legacy.exists()) continue;
        if (await legacy.list().isEmpty) continue;
        // Thư mục mới có thể vừa được path_provider tạo ra, rỗng — phải bỏ đi
        // trước, không thì rename báo lỗi "đã tồn tại".
        if (await base.exists()) await base.delete();
        await legacy.rename(base.path);
        return;
      }
    } catch (_) {
      // ổ đĩa khác, thiếu quyền, hoặc bản cũ đang chạy — cứ dùng thư mục mới
    }
  }

  Directory get booksDir => Directory(p.join(root.path, 'books'));
  Directory get cacheDir => Directory(p.join(root.path, 'cache'));
  Directory get jobsDir => Directory(p.join(root.path, 'jobs'));
  File get settingsFile => File(p.join(root.path, 'settings.json'));

  Directory bookDir(String id) => Directory(p.join(booksDir.path, id));

  /// Bản riêng của ứng dụng cho từng phần đã xuất, chỉ để PHÁT LẠI trong ứng
  /// dụng — tách khỏi bản đã đăng ký ra ngoài (thư viện nhạc hệ thống hay thư
  /// mục người dùng chọn).
  ///
  /// Chỉ Android mới cần tới: MediaStore và Storage Access Framework đều xoá
  /// bản gốc sau khi chép và chỉ trả về một chuỗi hiển thị chứ không phải
  /// đường dẫn hay URI dùng lại được, nên đây là cách duy nhất mở lại đúng
  /// file đó từ trong ứng dụng. Trên máy tính không dùng tới — file thật vẫn
  /// nằm nguyên trong outputDir của job.
  Directory exportPlaybackDir(String jobId) => Directory(p.join(root.path, 'xuat_nghe', jobId));

  /// Thử ghi thật vào [dir] xem có được không.
  ///
  /// Trả về null khi ghi được, hoặc câu giải thích khi không. Kiểm trước khi bắt
  /// đầu còn hơn để người dùng chờ nửa tiếng rồi mới báo lỗi ở file đầu tiên —
  /// và đường dẫn mà bộ chọn thư mục của Android trả về thường là loại không
  /// ghi thẳng được.
  static Future<String?> checkWritable(String dir) async {
    final target = Directory(dir);
    try {
      await target.create(recursive: true);
    } catch (err) {
      return 'Không tạo được thư mục $dir ($err)';
    }
    final probe = File(p.join(dir, '.sachluoi-thu-ghi'));
    try {
      await probe.writeAsString('x', flush: true);
      await probe.delete();
      return null;
    } catch (err) {
      return 'Không ghi được vào $dir. Trên Android, ứng dụng chỉ ghi thẳng được '
          'vào thư mục riêng của nó — chọn lại thư mục mặc định, hoặc chép file '
          'ra sau khi xuất xong. ($err)';
    }
  }

  /// Ghi qua file tạm rồi đổi tên: mất điện giữa chừng cũng không hỏng dữ liệu cũ.
  static Future<void> writeJson(File file, Object value) => writeJsonText(file, jsonEncode(value));

  /// Như [writeJson] nhưng nhận sẵn chuỗi JSON — dùng khi việc mã hoá đã được
  /// làm ở isolate nền để không chặn giao diện.
  static Future<void> writeJsonText(File file, String json) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(json, encoding: utf8, flush: true);
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
  }

  static Future<Map<String, dynamic>?> readJsonMap(File file) async {
    try {
      if (!await file.exists()) return null;
      return jsonDecode(await file.readAsString(encoding: utf8)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Tổng dung lượng và số file trong bộ nhớ đệm âm thanh.
  Future<({int bytes, int files})> cacheStats() async {
    var bytes = 0;
    var files = 0;
    if (!await cacheDir.exists()) return (bytes: 0, files: 0);
    await for (final entity in cacheDir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        files++;
        try {
          bytes += await entity.length();
        } catch (_) {
          // file vừa bị xoá
        }
      }
    }
    return (bytes: bytes, files: files);
  }

  Future<void> clearCache() async {
    if (await cacheDir.exists()) await cacheDir.delete(recursive: true);
    await cacheDir.create(recursive: true);
  }

  /// Xoá bớt đoạn âm thanh cũ nhất cho tới khi bộ nhớ đệm nằm dưới hạn.
  ///
  /// Bỏ file cũ nhất trước: đoạn vừa nghe hay nghe lại thì mới, đoạn của cuốn
  /// sách bỏ dở từ tháng trước thì cũ — chính là thứ nên nhường chỗ.
  ///
  /// Xoá xuống dưới hạn một quãng ([keepRatio]) chứ không xoá vừa đúng hạn, để
  /// mỗi đoạn mới thêm vào không kích hoạt một lượt dọn nữa.
  ///
  /// Trả về số byte đã xoá. [limitBytes] bằng 0 hoặc âm nghĩa là không hạn.
  Future<int> trimCache(int limitBytes, {double keepRatio = 0.9}) async {
    if (limitBytes <= 0 || !await cacheDir.exists()) return 0;

    final files = <({File file, int bytes, DateTime at})>[];
    var total = 0;
    await for (final entity in cacheDir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      try {
        final stat = await entity.stat();
        files.add((file: entity, bytes: stat.size, at: stat.modified));
        total += stat.size;
      } catch (_) {
        // file vừa bị xoá giữa lúc đang liệt kê
      }
    }
    if (total <= limitBytes) return 0;

    files.sort((a, b) => a.at.compareTo(b.at));
    final target = (limitBytes * keepRatio).round();
    var removed = 0;
    for (final entry in files) {
      if (total <= target) break;
      try {
        await entry.file.delete();
        total -= entry.bytes;
        removed += entry.bytes;
      } catch (_) {
        // đang được trình phát mở — để lượt sau
      }
    }
    return removed;
  }
}

/// Bỏ các ký tự không đặt được trong tên file Windows.
String sanitizeFileName(String name, {int maxLength = 60}) {
  final clean = name
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return clean.length > maxLength ? clean.substring(0, maxLength).trim() : clean;
}

String formatBytes(int bytes) {
  if (bytes <= 0) return '0 MB';
  final mb = bytes / 1024 / 1024;
  return mb >= 1024 ? '${(mb / 1024).toStringAsFixed(2)} GB' : '${mb.toStringAsFixed(1)} MB';
}
