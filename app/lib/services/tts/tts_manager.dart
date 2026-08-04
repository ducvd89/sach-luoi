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
import 'system_tts_engine.dart';
import 'vieneu_engine.dart';

class CachedAudio {
  const CachedAudio(this.file, this.seconds, this.fromCache, {this.duoi = const []});
  final File file;
  final double seconds;
  final bool fromCache;

  /// Mã đuôi của đoạn này, để làm ngữ cảnh cho đoạn kế. Rỗng nếu không có.
  final List<int> duoi;
}

class TtsManager {
  /// [themEngine] chỉ dùng trong kiểm thử: cắm thêm engine giả để soi những
  /// phần gọi engine mà không cần mô hình thật trên máy.
  TtsManager({ModelStore? store, List<TtsEngine> themEngine = const []})
      : modelStore = store ?? ModelStore() {
    onDevice = OnDeviceVieNeuEngine(modelStore);
    // Ba engine, cùng chạy thẳng trên máy: VieNeu cho chất lượng, Piper cho
    // nhẹ, TTS hệ thống cho máy đã có sẵn giọng mà không muốn tải gì thêm.
    // Không còn đường nào phải nhờ máy khác đọc hộ.
    _engines = {
      onDevice.id: onDevice,
      piper.id: piper,
      systemTts.id: systemTts,
      for (final e in themEngine) e.id: e,
    };
  }

  final ModelStore modelStore;
  late final OnDeviceVieNeuEngine onDevice;
  final OnDeviceTtsEngine piper = OnDeviceTtsEngine();
  final SystemTtsEngine systemTts = SystemTtsEngine();
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
  /// Thư mục và tên file cho một đoạn.
  ///
  /// Tên chia làm hai phần: phần đầu băm từ (engine, giọng, tốc độ, văn bản),
  /// phần đuôi băm từ ngữ cảnh — mọi bản của cùng một đoạn nằm cạnh nhau.
  ///
  /// Nhảy vào giữa sách thì đoạn ấy đọc mới, không ngữ cảnh, và chỉ nhận đúng
  /// bản không-ngữ-cảnh trong cache. Không đi mò bản đã nối với đoạn khác: nghe
  /// nó rồi lấy đuôi của nó làm mốc thì cả chuỗi sau đó bám theo một ngữ cảnh
  /// chẳng liên quan gì tới chỗ đang nghe.
  (Directory, String) _viTri(String engineId, String voiceId, double speed, String text) {
    final key = sha1
        .convert(utf8.encode('$engineId|$voiceId|${speed.toStringAsFixed(2)}|$text'))
        .toString();
    final dir = Directory(p.join(
      Storage.instance.cacheDir.path,
      // Mã giọng có thể chứa dấu cách, dấu tiếng Việt hoặc ':' ("Phạm Tuyên",
      // "mau:cua-toi") — đưa hết về dạng đặt được tên thư mục. Khoá cache thật
      // nằm ở chuỗi băm phía dưới nên rút gọn ở đây không gây trùng lẫn.
      '${engineId}_${voiceId.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')}_${(speed * 100).round()}',
      key.substring(0, 2),
    ));
    return (dir, key.substring(2));
  }

  /// [lanThu] > 0 là bản đọc lại của cùng đoạn ấy (xem `export_service.dart`) —
  /// mỗi lần một file riêng, để lần chạy tiếp sau khi tạm dừng vẫn lấy lại đúng
  /// bản đọc đã chọn chứ không phải đọc lại từ đầu. Lần đầu giữ nguyên tên cũ
  /// nên bộ nhớ đệm của các bản trước vẫn dùng được.
  File _cacheFile(String engineId, String voiceId, double speed, String text, String dauNguCanh,
      int lanThu) {
    final (dir, goc) = _viTri(engineId, voiceId, speed, text);
    final lan = lanThu > 0 ? '-l$lanThu' : '';
    return File(p.join(dir.path, '$goc$dauNguCanh$lan.${engine(engineId).audioFormat}'));
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
    List<int>? nguCanh,
    int lanThu = 0,
  }) async {
    final co = nguCanh != null && nguCanh.isNotEmpty;
    final dau = co ? sha1.convert(_bytesOf(nguCanh)).toString().substring(0, 12) : '';
    final file = _cacheFile(engineId, voiceId, speed, text, dau, lanThu);

    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      if (bytes.isNotEmpty) {
        // Chạm vào file để nó không bị coi là cũ: đoạn đang nghe lại phải sống
        // lâu hơn đoạn của cuốn sách bỏ dở từ tháng trước.
        unawaited(file.setLastModified(DateTime.now()).catchError((Object _) {}));
        return CachedAudio(file, _durationOf(engineId, bytes), true, duoi: await _docDuoi(file));
      }
    }

    final key = file.path;
    final existing = _inflight[key];
    if (existing != null) return existing;

    // Chú ý thân hàm phải là câu lệnh, không phải biểu thức: Map.remove trả về
    // chính future đang lưu, mà whenComplete lại chờ giá trị trả về nếu đó là
    // Future — thành ra future tự chờ chính nó và treo mãi mãi.
    final future =
        _synthesizeToFile(engineId, voiceId, speed, text, file, nguCanh, lanThu).whenComplete(() {
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
    List<int>? nguCanh,
    int lanThu,
  ) async {
    final result = await engine(engineId).synthesize(
      text: text,
      voiceId: voiceId,
      speed: speed,
      nguCanh: nguCanh,
      lanThu: lanThu,
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
    if (result.duoi.isNotEmpty) await _ghiDuoi(file, result.duoi);
    return CachedAudio(file, result.seconds, false, duoi: result.duoi);
  }

  /// Mã đuôi cất cạnh file âm thanh, để lần nghe sau lấy lại được từ cache mà
  /// vẫn nối được ngữ cảnh cho đoạn kế. Khoảng 6 KB mỗi đoạn.
  File _fileDuoi(File audio) => File('${audio.path}.duoi');

  Uint8List _bytesOf(List<int> ma) => Int32List.fromList(ma).buffer.asUint8List();

  Future<void> _ghiDuoi(File audio, List<int> duoi) async {
    try {
      await _fileDuoi(audio).writeAsBytes(_bytesOf(duoi), flush: true);
    } catch (_) {
      // Mất đuôi thì đoạn sau đọc không ngữ cảnh, không đáng để hỏng cả lượt đọc.
    }
  }

  Future<List<int>> _docDuoi(File audio) async {
    try {
      final f = _fileDuoi(audio);
      if (!await f.exists()) return const [];
      final b = await f.readAsBytes();
      return Int32List.view(b.buffer, b.offsetInBytes, b.lengthInBytes ~/ 4);
    } catch (_) {
      return const [];
    }
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
