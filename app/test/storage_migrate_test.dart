/// Đổi tên ứng dụng làm đổi luôn thư mục dữ liệu trên Windows. Các bài dưới đây
/// giữ cho việc dời dữ liệu cũ sang tên mới không làm mất thư viện sách.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sach_noi/services/storage.dart';

void main() {
  late Directory parent;

  setUp(() async {
    parent = await Directory.systemTemp.createTemp('sachnoi_migrate_');
  });

  tearDown(() async {
    if (await parent.exists()) await parent.delete(recursive: true);
  });

  Directory dirOf(String name) => Directory(p.join(parent.path, name));

  Future<void> seed(Directory dir, String relative) async {
    final file = File(p.join(dir.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString('nội dung');
  }

  test('dời thư viện của tên cũ sang thư mục tên mới', () async {
    final legacy = dirOf('Sach noi tieng Viet');
    await seed(legacy, p.join('books', 'sach-1', 'meta.json'));
    final base = dirOf('Sach luoi');

    await Storage.migrateLegacyRoot(base);

    expect(await File(p.join(base.path, 'books', 'sach-1', 'meta.json')).exists(), isTrue);
    expect(await legacy.exists(), isFalse);
  });

  test('thư mục mới rỗng do path_provider vừa tạo vẫn dời được', () async {
    final legacy = dirOf('Sach noi tieng Viet');
    await seed(legacy, 'settings.json');
    final base = dirOf('Sach luoi');
    await base.create(recursive: true);

    await Storage.migrateLegacyRoot(base);

    expect(await File(p.join(base.path, 'settings.json')).exists(), isTrue);
  });

  test('thư mục mới đã có dữ liệu thì không đụng vào', () async {
    final legacy = dirOf('Sach noi tieng Viet');
    await seed(legacy, 'settings.json');
    final base = dirOf('Sach luoi');
    await seed(base, 'settings.json');

    await Storage.migrateLegacyRoot(base);

    // Cả hai còn nguyên: dữ liệu mới không bị bản cũ ghi đè.
    expect(await legacy.exists(), isTrue);
    expect(await File(p.join(base.path, 'settings.json')).readAsString(), 'nội dung');
  });

  test('không có thư mục cũ thì im lặng bỏ qua', () async {
    final base = dirOf('Sach luoi');
    await Storage.migrateLegacyRoot(base);
    expect(await base.exists(), isFalse);
  });

  test('thư mục cũ rỗng thì không dời', () async {
    final legacy = dirOf('Sach noi tieng Viet');
    await legacy.create(recursive: true);
    final base = dirOf('Sach luoi');

    await Storage.migrateLegacyRoot(base);

    expect(await legacy.exists(), isTrue);
    expect(await base.exists(), isFalse);
  });
}
