/// Chọn engine và quản lý bộ nhớ đệm âm thanh.
///
/// Khoá cache gồm engine, giọng, tốc độ và nội dung đoạn. Nhờ vậy nghe thử rồi
/// mới xuất file thì phần đã nghe không phải tổng hợp lại, và việc xuất file có
/// thể dừng giữa chừng rồi chạy tiếp mà gần như không mất công.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/mp3.dart';
import '../../core/wav.dart';
import '../storage.dart';
import 'model_store.dart';
import 'tts_engine.dart';
import 'ondevice_engine.dart';
import 'vieneu_engine.dart';

class CachedAudio {
  const CachedAudio(this.file, this.seconds, this.fromCache);
  final File file;
  final double seconds;
  final bool fromCache;
}

class TtsManager {
  TtsManager({ModelStore? store}) : modelStore = store ?? ModelStore() {
    onDevice = OnDeviceVieNeuEngine(modelStore);
    // Hai engine, cùng chạy thẳng trên máy: VieNeu cho chất lượng, Piper cho
    // nhẹ. Không còn đường nào phải nhờ máy khác đọc hộ.
    _engines = {onDevice.id: onDevice, piper.id: piper};
  }

  final ModelStore modelStore;
  late final OnDeviceVieNeuEngine onDevice;
  final OnDeviceTtsEngine piper = OnDeviceTtsEngine();
  late final Map<String, TtsEngine> _engines;

  /// Các yêu cầu đang chạy, để hai nơi cùng xin một đoạn thì chỉ tổng hợp một lần.
  final _inflight = <String, Future<CachedAudio>>{};

  /// Trần bộ nhớ đệm theo byte, 0 nghĩa là không hạn. Cài đặt đổi thì đổi ở đây.
  int cacheLimitBytes = 0;

  /// Số byte đã ghi kể từ lượt dọn gần nhất.
  ///
  /// Quét cả thư mục đệm sau từng đoạn thì tốn vô ích — hàng nghìn file mà mỗi
  /// đoạn chỉ thêm vài trăm KB. Chỉ dọn khi đã ghi thêm một lượng đáng kể.
  int _writtenSinceTrim = 0;
  static const _trimEvery = 16 * 1024 * 1024;
  Future<void>? _trimming;

  List<TtsEngine> get engines => _engines.values.toList();

  TtsEngine engine(String id) => _engines[id] ?? onDevice;

  /// Khoá cache gồm mọi thứ ảnh hưởng tới âm thanh sinh ra — đổi bất kỳ thứ nào
  /// thì phải tổng hợp lại chứ không được lấy nhầm bản cũ.
  File _cacheFile(String engineId, String voiceId, double speed, String text) {
    final key = sha1
        .convert(utf8.encode('$engineId|$voiceId|${speed.toStringAsFixed(2)}|$text'))
        .toString();
    final dir = p.join(
      Storage.instance.cacheDir.path,
      // Mã giọng có thể chứa dấu cách, dấu tiếng Việt hoặc ':' ("Phạm Tuyên",
      // "mau:cua-toi") — đưa hết về dạng đặt được tên thư mục. Khoá cache thật
      // nằm ở chuỗi băm phía dưới nên rút gọn ở đây không gây trùng lẫn.
      '${engineId}_${voiceId.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')}_${(speed * 100).round()}',
      key.substring(0, 2),
    );
    return File(p.join(dir, '${key.substring(2)}.${engine(engineId).audioFormat}'));
  }

  /// Thời lượng của một file đã nằm trong bộ nhớ đệm.
  double _durationOf(String engineId, Uint8List bytes) =>
      engine(engineId).audioFormat == 'wav' ? wavDuration(bytes) : mp3Duration(bytes);

  /// Lấy âm thanh cho một đoạn, dùng lại cache nếu có.
  Future<CachedAudio> audioFor({
    required String engineId,
    required String voiceId,
    required double speed,
    required String text,
  }) async {
    final file = _cacheFile(engineId, voiceId, speed, text);

    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      if (bytes.isNotEmpty) {
        // Chạm vào file để nó không bị coi là cũ: đoạn đang nghe lại phải sống
        // lâu hơn đoạn của cuốn sách bỏ dở từ tháng trước.
        unawaited(file.setLastModified(DateTime.now()).catchError((Object _) {}));
        return CachedAudio(file, _durationOf(engineId, bytes), true);
      }
    }

    final key = file.path;
    final existing = _inflight[key];
    if (existing != null) return existing;

    // Chú ý thân hàm phải là câu lệnh, không phải biểu thức: Map.remove trả về
    // chính future đang lưu, mà whenComplete lại chờ giá trị trả về nếu đó là
    // Future — thành ra future tự chờ chính nó và treo mãi mãi.
    final future = _synthesizeToFile(engineId, voiceId, speed, text, file).whenComplete(() {
      _inflight.remove(key);
    });
    _inflight[key] = future;
    return future;
  }

  Future<CachedAudio> _synthesizeToFile(
    String engineId,
    String voiceId,
    double speed,
    String text,
    File file,
  ) async {
    final result = await engine(engineId).synthesize(
      text: text,
      voiceId: voiceId,
      speed: speed,
    );
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(result.audio, flush: true);
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);

    _writtenSinceTrim += result.audio.length;
    if (cacheLimitBytes > 0 && _writtenSinceTrim >= _trimEvery) {
      _writtenSinceTrim = 0;
      // Dọn ở nền: người nghe không phải chờ một lượt quét thư mục.
      _trimming ??= Storage.instance.trimCache(cacheLimitBytes).then((_) {
        _trimming = null;
      }).catchError((Object _) {
        _trimming = null;
      });
    }
    return CachedAudio(file, result.seconds, false);
  }

  /// Tổng hợp trước vài đoạn để lúc phát không bị khựng giữa chừng.
  void prefetch({
    required String engineId,
    required String voiceId,
    required double speed,
    required List<String> texts,
  }) {
    for (final text in texts) {
      unawaited(
        audioFor(engineId: engineId, voiceId: voiceId, speed: speed, text: text)
            .catchError((Object _) => CachedAudio(File(''), 0, false)),
      );
    }
  }
}
