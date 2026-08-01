/// Engine Piper chạy thẳng trong ứng dụng qua sherpa-onnx.
///
/// Nhẹ hơn VieNeu khoảng mười lần và không cần tải mô hình 206 MB, đổi lại
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
  Future<void>? _starting;
  final _pending = <int, Completer<_Result>>{};
  var _nextId = 0;

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

  @override
  String get audioFormat => 'wav';

  @override
  Future<EngineStatus> status() async {
    if (installedVoicePacks().isEmpty) {
      return const EngineStatus(
        ready: false,
        message: 'Chưa tải gói giọng nào — bấm "Tải về" ở mục Gói giọng',
      );
    }
    return const EngineStatus(ready: true, message: 'Sẵn sàng', device: 'cpu');
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

  Future<void> _ensure(String voiceId) async {
    if (_send != null) return;
    if (_starting != null) return _starting;

    final packs = installedVoicePacks();
    if (packs.isEmpty) throw TtsException('Chưa tải gói giọng nào');
    final pack = packs.firstWhere((p) => p.folder == voiceId, orElse: () => packs.first);
    final dir = findVoicePack(pack.folder);
    if (dir == null) throw TtsException('Không tìm thấy gói giọng ${pack.name}');

    final completer = Completer<void>();
    _starting = completer.future;

    final receive = ReceivePort();
    receive.listen((message) {
      if (message is SendPort) {
        _send = message;
        if (!completer.isCompleted) completer.complete();
      } else if (message is _Result) {
        _pending.remove(message.id)?.complete(message);
      }
    });

    await Isolate.spawn(_worker, _Setup(receive.sendPort, dir.path, pack.modelFile),
        debugName: 'piper');
    await completer.future;
    _starting = null;
  }

  @override
  Future<TtsResult> synthesize({
    required String text,
    required String voiceId,
    double speed = 1.0,
    List<int>? nguCanh, // engine này không nối ngữ cảnh
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
    _send?.send(null);
    _send = null;
  }
}
