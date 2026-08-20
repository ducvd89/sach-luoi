/// Engine Piper chạy thẳng trong ứng dụng qua sherpa-onnx.
///
/// Nhẹ hơn VieNeu khoảng mười lần và không cần tải mô hình 145 MB, đổi lại
/// giọng máy hơn. Giữ làm lựa chọn cho máy yếu, cho lúc muốn đọc nhanh, hoặc
/// khi chưa muốn tải mô hình lớn.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../../core/wav.dart';
import 'tts_engine.dart';
import 'voice_pack.dart';

/// Yêu cầu gửi sang isolate nền.
class _Job {
  const _Job(this.id, this.text, this.speed);
  final int id;
  final String text;
  final double speed;
}

class _Result {
  const _Result(this.id, this.samples, this.sampleRate, this.error);
  final int id;
  final Float32List? samples;
  final int sampleRate;
  final String? error;
}

class _Setup {
  const _Setup(this.reply, this.dir, this.modelFile);
  final SendPort reply;
  final String dir;
  final String modelFile;
}

/// Sinh âm thanh ở isolate riêng — một đoạn mất vài trăm mili giây, đủ để làm
/// giật giao diện nếu chạy chung.
void _worker(_Setup setup) {
  sherpa.initBindings();

  final config = sherpa.OfflineTtsConfig(
    model: sherpa.OfflineTtsModelConfig(
      vits: sherpa.OfflineTtsVitsModelConfig(
        model: p.join(setup.dir, setup.modelFile),
        tokens: p.join(setup.dir, 'tokens.txt'),
        dataDir: p.join(setup.dir, 'espeak-ng-data'),
      ),
      numThreads: 2,
    ),
  );

  final tts = sherpa.OfflineTts(config);
  final inbox = ReceivePort();
  setup.reply.send(inbox.sendPort);

  inbox.listen((message) {
    if (message is! _Job) {
      tts.free();
      inbox.close();
      return;
    }
    try {
      final audio = tts.generate(text: message.text, sid: 0, speed: message.speed);
      setup.reply.send(_Result(message.id, audio.samples, audio.sampleRate, null));
    } catch (err) {
      setup.reply.send(_Result(message.id, null, 0, '$err'));
    }
  });
}

class OnDeviceTtsEngine implements TtsEngine {
  SendPort? _send;

  /// Lượt mở isolate đang chạy. Giữ chính Completer chứ không giữ Future của nó:
  /// isolate chết thì phải có đường làm nó vỡ ra thành lỗi — xem [_vo].
  Completer<void>? _dangMo;
  final _pending = <int, Completer<_Result>>{};
  var _nextId = 0;

  /// Lý do lần mở gần nhất hỏng, để [status] nói ra thay vì báo "Sẵn sàng" suông.
  String? _loi;

  /// Đang tự tay đóng isolate — xem [dispose].
  var _dongChuDong = false;

  /// Piper nhẹ tới mức một luồng đã nhanh hơn nhiều lần thời gian thực, mở thêm
  /// bản sao mô hình chỉ tốn RAM chứ không rút ngắn được gì đáng kể.
  @override
  Future<void> setBulkMode(bool on) async {}

  @override
  String get id => 'piper';

  @override
  String get displayName => 'Giọng nhẹ trong ứng dụng';

  @override
  bool get isLocal => true;

  @override
  String get description =>
      'Chỉ 21–64 MB, chạy được cả trên máy yếu và điện thoại. Giọng máy hơn '
      'VieNeu và file xuất ra là WAV nên nặng hơn MP3.';

  /// Đọc theo luật, không lấy mẫu ngẫu nhiên — đọc lại cũng ra đúng bản cũ.
  @override
  bool get docLaiRaKhac => false;

  /// Piper đọc theo luật, mỗi đoạn độc lập — không có gì để nối.
  @override
  bool get noiNguCanh => false;

  /// Piper đọc gần như tức thì nên không có gì đáng cắt giữa chừng.
  @override
  void huyDangDoc() {}

  @override
  Future<EngineStatus> status() async {
    if (installedVoicePacks().isEmpty) {
      return const EngineStatus(
        ready: false,
        message: 'Chưa tải gói giọng nào — bấm "Tải về" ở mục Gói giọng',
      );
    }
    // Có gói giọng chưa phải là chạy được: thư viện native có thể không nạp nổi.
    // Nói thẳng lý do ra chứ đừng báo "Sẵn sàng" rồi im lặng khi người dùng bấm.
    final loi = _loi;
    if (loi != null) return EngineStatus(ready: false, message: loi);
    return const EngineStatus(ready: true, message: 'Sẵn sàng');
  }

  @override
  Future<List<TtsVoice>> voices() async {
    return installedVoicePacks()
        .map((pack) => TtsVoice(
              id: pack.folder,
              name: pack.name,
              gender: pack.gender,
              description: pack.description,
            ))
        .toList();
  }

  /// Isolate nền chết thì mọi lời hứa đang chờ phải VỠ RA THÀNH LỖI.
  ///
  /// Chính chỗ này đã giấu mất lỗi Piper trên Android: `initBindings()` không
  /// nạp nổi libsherpa-onnx-c-api.so, isolate chết ngay từ dòng đầu, mà bên này
  /// chỉ ngồi `await` một Completer không bao giờ có ai gọi. Người dùng thấy
  /// ứng dụng đứng im, không một dòng lỗi, còn `status()` vẫn báo "Sẵn sàng".
  void _vo(Object loi) {
    _loi = '$loi';
    _send = null;
    final mo = _dangMo;
    _dangMo = null;
    if (mo != null && !mo.isCompleted) mo.completeError(TtsException(_loi!));
    final cho = _pending.values.toList();
    _pending.clear();
    for (final c in cho) {
      if (!c.isCompleted) c.completeError(TtsException(_loi!));
    }
  }

  Future<void> _ensure(String voiceId) {
    if (_send != null) return Future.value();
    final dangMo = _dangMo;
    if (dangMo != null) return dangMo.future;

    final packs = installedVoicePacks();
    if (packs.isEmpty) throw TtsException('Chưa tải gói giọng nào');
    final pack = packs.firstWhere((p) => p.folder == voiceId, orElse: () => packs.first);
    final dir = findVoicePack(pack.folder);
    if (dir == null) throw TtsException('Không tìm thấy gói giọng ${pack.name}');

    final completer = Completer<void>();
    _dangMo = completer;

    final receive = ReceivePort();
    receive.listen((message) {
      if (message is SendPort) {
        _send = message;
        _loi = null;
        _dangMo = null;
        if (!completer.isCompleted) completer.complete();
      } else if (message is _Result) {
        _pending.remove(message.id)?.complete(message);
      } else if (message is List) {
        // onError của Isolate.spawn gửi [lỗi, stack] dạng chuỗi.
        _vo(message.isEmpty ? 'Không nạp được engine nhẹ' : '${message.first}');
      } else if (message == null) {
        // onExit. Tự mình đóng thì đây là kết thúc bình thường, đừng ghi lỗi.
        if (!_dongChuDong) _vo('Engine nhẹ dừng đột ngột');
        receive.close();
      }
    });

    // onError/onExit là thứ bản trước thiếu — không có chúng thì isolate chết
    // trong im lặng và mọi lượt gọi sau đó treo mãi mãi.
    Isolate.spawn(
      _worker,
      _Setup(receive.sendPort, dir.path, pack.modelFile),
      onError: receive.sendPort,
      onExit: receive.sendPort,
      debugName: 'piper',
      errorsAreFatal: true,
    ).catchError((Object err) {
      _vo(err);
      return Isolate.current;
    });

    return completer.future;
  }

  @override
  Future<TtsResult> synthesize({
    required String text,
    required String voiceId,
    double speed = 1.0,
    List<int>? nguCanh, // engine này không nối ngữ cảnh
    int lanThu = 0, // đọc theo luật, lần nào cũng y hệt
  }) async {
    await _ensure(voiceId);
    final send = _send;
    if (send == null) throw TtsException('Không khởi động được engine nhẹ');

    final id = _nextId++;
    final completer = Completer<_Result>();
    _pending[id] = completer;
    send.send(_Job(id, text, speed));

    final result = await completer.future;
    if (result.error != null) throw TtsException(result.error!);
    final samples = normalizePeak(result.samples ?? Float32List(0));
    return TtsResult(
      buildWav(samples, result.sampleRate),
      result.sampleRate == 0 ? 0 : samples.length / result.sampleRate,
    );
  }

  Future<void> dispose() async {
    // Đóng có chủ ý thì lượt onExit sắp tới KHÔNG phải là sự cố — không có cờ
    // này thì [_vo] ghi luôn một dòng lỗi vào [status] cho lần mở sau.
    _dongChuDong = true;
    _send?.send(null);
    _send = null;
  }
}
