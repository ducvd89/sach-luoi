/// Canh hai lỗi chỉ lộ ra trên Android, không lộ trên Windows.
///
/// Cả hai đều nằm ở bước bung gói tải về, và cả hai đều im lặng: một cái báo
/// "vẫn thiếu file" sau khi bung xong, cái kia thì ứng dụng biến mất không để
/// lại dòng nào.
library;

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sach_noi/services/storage.dart';
import 'package:sach_noi/services/tts/model_store.dart';
import 'package:sach_noi/services/tts/voice_pack.dart';

void main() {
  group('Tên mục trong gói nén', () {
    // Đặc tả zip bắt dùng "/", nhưng gói v3 Turbo dựng trên Windows lại mang
    // dấu gạch ngược. Windows không lộ ra vì ở đó nó cũng là dấu phân cách;
    // Android thì coi cả cụm là tên file rồi thả vào thư mục gốc, nên phép
    // kiểm đủ file trượt dù bung không lỗi. Vì lẽ ấy phép kiểm này phải xét
    // thẳng chuỗi chứ không đi qua đường dẫn thật của máy đang chạy test.
    test('đổi dấu gạch ngược thành "/"', () {
      expect(tenTrongGoi(r'model\config.json'), 'model/config.json');
      expect(
        tenTrongGoi(r'codec\moss_audio_tokenizer_decode_step.onnx'),
        'codec/moss_audio_tokenizer_decode_step.onnx',
      );
    });

    test('giữ nguyên tên đã đúng chuẩn', () {
      expect(tenTrongGoi('model/config.json'), 'model/config.json');
      expect(tenTrongGoi('voices.json'), 'voices.json');
    });
  });

  group('Tải gói giọng Piper', () {
    late Directory root;

    setUp(() async {
      root = Directory.systemTemp.createTempSync('sachnoi_giong_');
      await Storage.init(overrideRoot: root);
    });
    tearDown(() => root.deleteSync(recursive: true));

    /// Dựng một `.tar.bz2` đúng hình dạng gói của sherpa-onnx.
    List<int> guiGoi(String thuMuc) {
      final kho = Archive()
        ..add(ArchiveFile.bytes('$thuMuc/vi_VN-vais1000-medium.onnx',
            List.filled(2048, 7)))
        ..add(ArchiveFile.bytes('$thuMuc/tokens.txt', List.filled(64, 8)));
      return BZip2Encoder().encodeBytes(TarEncoder().encodeBytes(kho));
    }

    test('bung ra đúng thư mục và thấy được file mô hình', () async {
      final pack = availableVoicePacks.first;
      final client = MockClient(guiGoi(pack.folder));

      final moc = <double>[];
      await downloadVoicePack(
        pack,
        onProgress: (p) => moc.add(p.value ?? 0),
        client: client,
      );

      expect(findVoicePack(pack.folder), isNotNull);
      expect(
        File(p.join(voicePackDir.path, pack.folder, pack.modelFile)).existsSync(),
        isTrue,
      );
      // Thanh tiến trình phải chạy tới cuối, không dừng giữa chừng.
      expect(moc.last, 1);
    });

    test('không để lại file tạm', () async {
      final pack = availableVoicePacks.first;
      await downloadVoicePack(
        pack,
        onProgress: (_) {},
        client: MockClient(guiGoi(pack.folder)),
      );

      final rac = voicePackDir
          .listSync()
          .where((e) => e.path.endsWith('.part'))
          .toList();
      expect(rac, isEmpty);
    });

    test('gói hỏng thì báo lỗi chứ không im lặng coi như xong', () async {
      final pack = availableVoicePacks.first;
      // Gói đúng định dạng nhưng bung ra không có file .onnx nào.
      final kho = Archive()
        ..add(ArchiveFile.bytes('${pack.folder}/doc.txt', List.filled(16, 1)));
      final hong = BZip2Encoder().encodeBytes(TarEncoder().encodeBytes(kho));

      await expectLater(
        downloadVoicePack(pack, onProgress: (_) {}, client: MockClient(hong)),
        throwsA(isA<Exception>()),
      );
    });

    test('máy chủ trả lỗi thì ném ra, không nuốt', () async {
      await expectLater(
        downloadVoicePack(
          availableVoicePacks.first,
          onProgress: (_) {},
          client: MockClient(const <int>[], status: 404),
        ),
        throwsA(isA<Exception>()),
      );
    });
  });
}

/// Máy chủ giả trả về một mớ byte định sẵn, chia nhỏ như mạng thật.
class MockClient extends http.BaseClient {
  MockClient(this.body, {this.status = 200});

  final List<int> body;
  final int status;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    Stream<List<int>> tung() async* {
      const buoc = 8192;
      for (var i = 0; i < body.length; i += buoc) {
        yield body.sublist(i, i + buoc > body.length ? body.length : i + buoc);
      }
    }

    return http.StreamedResponse(
      status == 200 ? tung() : const Stream<List<int>>.empty(),
      status,
      contentLength: status == 200 ? body.length : 0,
    );
  }
}
