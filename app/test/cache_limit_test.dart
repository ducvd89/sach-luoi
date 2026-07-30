/// Kiểm thử việc dọn bộ nhớ đệm khi vượt trần dung lượng.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sach_noi/models/settings.dart';
import 'package:sach_noi/services/storage.dart';

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('sachnoi_cache_');
    await Storage.init(overrideRoot: tempRoot);
  });

  tearDown(() async {
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  /// Tạo một file đệm giả, [ageMinutes] phút trước là bao nhiêu thì càng cũ.
  Future<File> writeChunk(String name, int bytes, int ageMinutes) async {
    final file = File(p.join(Storage.instance.cacheDir.path, 'vieneu_a_100', name));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(Uint8List(bytes), flush: true);
    await file.setLastModified(DateTime.now().subtract(Duration(minutes: ageMinutes)));
    return file;
  }

  test('không hạn thì không xoá gì', () async {
    await writeChunk('a.mp3', 4000, 60);
    expect(await Storage.instance.trimCache(0), 0);
    expect((await Storage.instance.cacheStats()).files, 1);
  });

  test('còn dưới trần thì không xoá gì', () async {
    await writeChunk('a.mp3', 1000, 60);
    await writeChunk('b.mp3', 1000, 10);
    expect(await Storage.instance.trimCache(10000), 0);
    expect((await Storage.instance.cacheStats()).files, 2);
  });

  test('vượt trần thì xoá file cũ nhất trước', () async {
    final oldest = await writeChunk('cu-nhat.mp3', 1000, 500);
    final middle = await writeChunk('giua.mp3', 1000, 100);
    final newest = await writeChunk('moi.mp3', 1000, 1);

    // Trần 2000, giữ lại 90% = 1800 -> phải xoá tới khi còn <= 1800 byte,
    // tức là bỏ đúng hai file cũ nhất.
    final removed = await Storage.instance.trimCache(2000);

    expect(removed, 2000);
    expect(await oldest.exists(), isFalse);
    expect(await middle.exists(), isFalse);
    expect(await newest.exists(), isTrue);
  });

  test('dọn xuống dưới trần một quãng để không phải dọn lại ngay', () async {
    for (var i = 0; i < 10; i++) {
      await writeChunk('doan-$i.mp3', 1000, 100 - i);
    }
    await Storage.instance.trimCache(5000);

    final after = await Storage.instance.cacheStats();
    // keepRatio 0.9: phải xuống dưới 4500 chứ không dừng ở đúng 5000.
    expect(after.bytes, lessThanOrEqualTo(4500));
    expect(after.bytes, greaterThan(3000));
  });

  test('lượt dọn thứ hai ngay sau đó không xoá thêm', () async {
    for (var i = 0; i < 6; i++) {
      await writeChunk('doan-$i.mp3', 1000, 60 - i);
    }
    await Storage.instance.trimCache(4000);
    expect(await Storage.instance.trimCache(4000), 0);
  });

  test('cài đặt đổi MB sang byte và giữ được qua JSON', () {
    final settings = AppSettings(cacheLimitMb: 200);
    expect(settings.cacheLimitBytes, 200 * 1024 * 1024);

    final again = AppSettings.fromJson(settings.toJson());
    expect(again.cacheLimitMb, 200);

    // Không hạn = 0, và mức mặc định phải nằm trong danh sách chọn được.
    expect(AppSettings(cacheLimitMb: 0).cacheLimitBytes, 0);
    expect(cacheLimitChoices, contains(defaultCacheLimitMb));
    expect(cacheLimitChoices, contains(0));
  });
}
