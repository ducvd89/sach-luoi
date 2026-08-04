/// Engine TTS hệ thống — dùng giọng đã cài sẵn trên máy qua `flutter_tts` thay
/// vì mô hình đóng gói trong ứng dụng.
///
/// Không tự tải giọng: người dùng cài giọng tiếng Việt qua Cài đặt của hệ điều
/// hành. Chỉ bật trên Android/iOS — hai nền tảng `flutter_tts` hỗ trợ
/// `synthesizeToFile` (bắt buộc để lấy được byte âm thanh cho bộ nhớ đệm và
/// xuất file). Trên Windows, `flutter_tts` chỉ phát trực tiếp qua loa và
/// Windows cũng chưa có giọng tiếng Việt hệ thống, nên engine luôn báo "không
/// sẵn sàng" ở đó.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/wav.dart';
import 'tts_engine.dart';

class SystemTtsEngine implements TtsEngine {
  final FlutterTts _tts = FlutterTts();
  bool _awaitConfigured = false;
  int _seq = 0;

  /// Bộ máy TTS của Android không cho hai lượt `synthesizeToFile` chạy chồng
  /// nhau — gọi chồng thì lượt sau bị từ chối ngay chứ không xếp hàng. Xâu
  /// chuỗi các lượt gọi qua đây để luôn chỉ có một lượt chạy tại một thời điểm.
  Future<void> _hangDoi = Future.value();

  List<TtsVoice>? _voiceCache;
  final Map<String, Map<String, String>> _raw = {};

  /// TTS hệ thống không cho hai lượt tổng hợp chạy chồng nhau (xem [_hangDoi]),
  /// nên mở thêm luồng lúc xuất file không giúp được gì.
  @override
  Future<void> setBulkMode(bool on) async {}

  @override
  String get id => 'system';

  @override
  String get displayName => 'TTS hệ thống';

  @override
  bool get isLocal => true;

  @override
  String get description => Platform.isAndroid || Platform.isIOS
      ? 'Dùng giọng đã cài sẵn trên máy, không cần tải mô hình. Chất lượng và '
          'việc có giọng tiếng Việt hay không tuỳ từng máy.'
      : 'Chưa hỗ trợ trên nền tảng này.';

  @override
  String get audioFormat => 'wav';

  /// Giọng của hệ thống đọc theo luật — đọc lại cũng ra đúng bản cũ.
  @override
  bool get docLaiRaKhac => false;

  bool get _hoTro => Platform.isAndroid || Platform.isIOS;

  @override
  Future<EngineStatus> status() async {
    if (!_hoTro) {
      return const EngineStatus(
        ready: false,
        message: 'TTS hệ thống chưa hỗ trợ trên nền tảng này — dùng VieNeu hoặc Giọng nhẹ.',
      );
    }
    final list = await voices();
    if (list.isEmpty) {
      return const EngineStatus(
        ready: false,
        message: 'Máy chưa có giọng tiếng Việt hệ thống — cài trong Cài đặt máy → '
            'Ngôn ngữ & nhập liệu → Chuyển văn bản thành giọng nói.',
      );
    }
    return const EngineStatus(ready: true, message: 'Sẵn sàng', device: 'hệ thống');
  }

  @override
  Future<List<TtsVoice>> voices() async {
    if (!_hoTro) return const [];
    final cached = _voiceCache;
    if (cached != null) return cached;

    try {
      final raw = await _tts.getVoices as List<dynamic>?;
      final list = <TtsVoice>[];
      _raw.clear();
      for (final item in raw ?? const []) {
        final map = Map<String, String>.from(item as Map);
        final locale = map['locale'] ?? '';
        if (!locale.toLowerCase().startsWith('vi')) continue;
        // Giọng cần mạng thì loại hẳn — engine này quảng cáo là chạy tại chỗ.
        if (map['network_required'] == '1') continue;
        final name = map['name'] ?? '';
        if (name.isEmpty || _raw.containsKey(name)) continue;
        _raw[name] = map;
        list.add(TtsVoice(id: name, name: name, gender: '', description: locale));
      }
      _voiceCache = list;
      return list;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _chuanBi(String voiceId) async {
    if (!_awaitConfigured) {
      await _tts.awaitSynthCompletion(true);
      _awaitConfigured = true;
    }
    final raw = _raw[voiceId];
    if (raw != null) {
      await _tts.setVoice({'name': raw['name'] ?? '', 'locale': raw['locale'] ?? ''});
    }
  }

  @override
  Future<TtsResult> synthesize({
    required String text,
    required String voiceId,
    double speed = 1.0,
    List<int>? nguCanh, // engine này không nối ngữ cảnh
    int lanThu = 0, // đọc theo luật, lần nào cũng y hệt
  }) {
    if (!_hoTro) throw TtsException('TTS hệ thống chưa hỗ trợ trên nền tảng này');

    final lot = _hangDoi.then((_) => _mot(text, voiceId, speed));
    // Lượt sau phải chờ đúng lượt này xong dù nó lỗi, không thì cả hàng đợi
    // kẹt lại theo lỗi của một đoạn.
    _hangDoi = lot.then((_) {}, onError: (_) {});
    return lot;
  }

  Future<TtsResult> _mot(String text, String voiceId, double speed) async {
    await voices(); // đảm bảo _raw đã có để _chuanBi tra được locale
    await _chuanBi(voiceId);
    await _tts.setSpeechRate(speed);

    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'system_tts_${DateTime.now().microsecondsSinceEpoch}_${_seq++}.wav'));

    final loi = Completer<void>();
    _tts.setErrorHandler((msg) {
      if (!loi.isCompleted) loi.completeError(TtsException('TTS hệ thống lỗi: $msg'));
    });

    try {
      await Future.any([
        _tts.synthesizeToFile(text, file.path, true),
        loi.future,
      ]).timeout(
        Duration(seconds: 20 + text.length ~/ 8),
        onTimeout: () => throw TtsException('TTS hệ thống không phản hồi'),
      );
    } finally {
      _tts.setErrorHandler((_) {});
    }

    if (!await file.exists()) throw TtsException('TTS hệ thống không tạo được file âm thanh');
    final bytes = await file.readAsBytes();
    unawaited(file.delete().catchError((_) => file));

    final info = readWavInfo(bytes);
    if (info == null) throw TtsException('TTS hệ thống trả về định dạng không đọc được');
    return TtsResult(bytes, info.seconds);
  }
}
