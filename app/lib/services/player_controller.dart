/// Điều khiển việc phát sách nói.
///
/// Mỗi đoạn là một file MP3 riêng. Trình phát luôn tổng hợp trước vài đoạn kế
/// tiếp nên khi hết đoạn này là có ngay đoạn sau, gần như không có khoảng lặng.
/// Vị trí đang nghe được lưu định kỳ để lần sau mở lên là nghe tiếp đúng chỗ.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

import '../core/wav.dart';
import '../models/book.dart';
import '../models/settings.dart';
import 'library_service.dart';
import 'storage.dart';
import 'tts/tts_manager.dart';

/// Tốc độ đọc được áp bằng cách chỉnh tốc độ phát chứ không tổng hợp lại —
/// đổi tốc độ là nghe thấy ngay, và bộ nhớ đệm vẫn dùng lại được.
const double _synthesisSpeed = 1.0;

class PlayerController extends ChangeNotifier {
  PlayerController(this._tts, this._library);

  final TtsManager _tts;
  final LibraryService _library;
  final Player _player = Player();

  Book? book;
  List<Chunk> chunks = const [];

  int index = 0;

  /// Đang trong khoảng nghỉ giữa hai đoạn thì vẫn tính là đang phát: nút bấm và
  /// thanh trạng thái không được nhấp nháy chỉ vì nửa giây im lặng.
  bool get isPlaying => _player.state.playing || _pauseTimer != null;
  bool isLoading = false;
  String? error;

  /// Thời lượng thật của các đoạn đã biết, dùng để vẽ thanh tiến trình cả sách.
  final Map<int, double> _durations = {};

  Duration position = Duration.zero;
  Duration chunkDuration = Duration.zero;

  Timer? _saveTimer;
  Timer? _sleepTimer;

  /// Đang đếm khoảng nghỉ trước khi sang đoạn kế tiếp.
  Timer? _pauseTimer;
  DateTime? sleepAt;
  int _loadToken = 0;
  AppSettings _settings = AppSettings();

  final List<StreamSubscription<dynamic>> _subscriptions = [];

  void attachStreams() {
    _giuThietBiAmThanh();
    _subscriptions.addAll([
      _player.stream.position.listen((value) {
        position = value;
        notifyListeners();
      }),
      _player.stream.duration.listen((value) {
        if (value > Duration.zero) {
          chunkDuration = value;
          _durations[index] = value.inMilliseconds / 1000;
          notifyListeners();
        }
      }),
      _player.stream.playing.listen((_) => notifyListeners()),
      _player.stream.completed.listen((completed) {
        if (completed) _onChunkFinished();
      }),
    ]);
  }

  // -- thông tin cho giao diện ----------------------------------------------

  Chunk? get currentChunk => index >= 0 && index < chunks.length ? chunks[index] : null;

  Chapter? get currentChapter {
    final chunk = currentChunk;
    if (chunk == null || book == null) return null;
    for (final chapter in book!.chapters) {
      if (chapter.index == chunk.chapter) return chapter;
    }
    return null;
  }

  double _chunkSeconds(int i) {
    final known = _durations[i];
    if (known != null) return known;
    final b = book;
    if (b == null || b.chunkCount == 0) return 8;
    return b.charCount / 14.5 / b.chunkCount;
  }

  /// Tổng thời lượng ước tính của cả sách (giây).
  double get totalSeconds {
    final b = book;
    if (b == null) return 0;
    var total = 0.0;
    for (var i = 0; i < b.chunkCount; i++) {
      total += _chunkSeconds(i);
    }
    return total / _settings.speed;
  }

  /// Đã nghe được bao nhiêu giây tính từ đầu sách.
  double get elapsedSeconds {
    var total = 0.0;
    for (var i = 0; i < index; i++) {
      total += _chunkSeconds(i);
    }
    return (total + position.inMilliseconds / 1000) / _settings.speed;
  }

  // -- mở sách ---------------------------------------------------------------

  Future<void> open(Book value, AppSettings settings) async {
    await stop();
    _settings = settings;
    book = value;
    chunks = await _library.loadChunks(value.id);
    index = value.progress.chunkIndex.clamp(0, max(0, chunks.length - 1));
    _durations.clear();
    error = null;
    notifyListeners();
  }

  void updateSettings(AppSettings settings) {
    final voiceChanged =
        settings.voiceNghe != _settings.voiceNghe || settings.engineId != _settings.engineId;
    _settings = settings;
    _player.setRate(settings.speed);
    if (voiceChanged) {
      _durations.clear();
      if (book != null) unawaited(playChunk(index, autoplay: isPlaying));
    }
    notifyListeners();
  }

  // -- điều khiển ------------------------------------------------------------

  Future<void> playChunk(int target, {bool autoplay = true, double offsetSeconds = 0}) async {
    final b = book;
    if (b == null || target < 0 || target >= chunks.length) return;

    final token = ++_loadToken;
    _cancelPause();
    index = target;
    isLoading = true;
    error = null;
    notifyListeners();

    try {
      // Ngữ cảnh chỉ dùng khi đọc tiếp đúng đoạn liền sau đoạn vừa nghe. Nhảy
      // lung tung thì bỏ, vì lúc ấy chẳng có gì để nối vào.
      final noiTiep = _settings.nguCanhNghe != NguCanh.khong && target == _doanCoDuoi + 1;
      final audio = await _tts.audioFor(
        engineId: _settings.engineId,
        voiceId: _settings.voiceNghe,
        speed: _synthesisSpeed,
        text: chunks[target].speech,
        nguCanh: noiTiep ? _duoi : null,
      );
      if (token != _loadToken) return; // người dùng đã nhảy sang đoạn khác

      _duoi = audio.duoi;
      _doanCoDuoi = audio.duoi.isEmpty ? -2 : target;
      _durations[target] = audio.seconds;
      await _player.open(Media(audio.file.path), play: autoplay);
      await _player.setRate(_settings.speed);
      if (offsetSeconds > 0.5) {
        // Trừ hao nửa giây để vị trí lưu lần trước không rơi đúng cuối đoạn
        // rồi nhảy ngay sang đoạn sau.
        final limit = max(0.0, audio.seconds - 0.5);
        await _player.seek(Duration(milliseconds: (min(offsetSeconds, limit) * 1000).round()));
      }

      _prefetchAround(target);
      _scheduleSave();
    } catch (err) {
      if (token == _loadToken) error = err.toString();
    } finally {
      if (token == _loadToken) {
        isLoading = false;
        notifyListeners();
      }
    }
  }

  /// Giữ thiết bị âm thanh luôn mở giữa các đoạn.
  ///
  /// Triệu chứng: chữ đầu đoạn kế thỉnh thoảng mất hẳn. Không phải mô hình sinh
  /// thiếu — file ghi ra đo được vẫn đủ tiếng, im lặng đầu đoạn chỉ 0,04-0,08
  /// giây. Manh mối quyết định: bật OBS lên ghi âm thì hết mất chữ, vì OBS mở
  /// một luồng thu và giữ thiết bị sống.
  ///
  /// Tức là giữa hai đoạn có khoảng nghỉ, hệ điều hành cho thiết bị nghỉ theo,
  /// rồi phần đầu luồng mới bị nuốt trong lúc nó thức dậy.
  ///
  /// `audio-stream-silence` bảo mpv phát im lặng ngầm lúc rảnh để thiết bị
  /// không kịp ngủ. Đúng thứ mpv làm ra cho mấy bộ giải mã HDMI hay cắt mất
  /// phần đầu. Không chèn im lặng vào chính file — làm thế là đoạn nào cũng bị
  /// trễ thêm, nghe trực tiếp thành ra ì ạch.
  Future<void> _giuThietBiAmThanh() async {
    // Cách một: bảo chính mpv phát im lặng ngầm lúc rảnh. Rẻ nhất, nhưng đã thử
    // và KHÔNG ăn thua — hoặc thuộc tính không được áp, hoặc luồng ấy vẫn tắt
    // theo file. Vẫn đặt vì không mất gì.
    final nen = _player.platform;
    if (nen is NativePlayer) {
      try {
        await nen.setProperty('audio-stream-silence', 'yes');
      } catch (_) {
        // Không đặt được thì thôi, còn cách hai ở dưới.
      }
    }

    // Cách hai: tự mở một luồng im lặng chạy vòng lặp riêng, âm lượng 0.
    //
    // Đây đúng là thứ OBS vô tình làm hộ: nó mở một luồng trên thiết bị âm
    // thanh và giữ sống, nên bật OBS lên là hết nuốt chữ. Luồng này độc lập với
    // trình phát chính nên không phụ thuộc mpv có tôn trọng tuỳ chọn nào không,
    // và không bao giờ dừng nên thiết bị không kịp ngủ giữa hai đoạn.
    try {
      final file = File(p.join(Storage.instance.cacheDir.path, 'giu-nhip.wav'));
      if (!await file.exists()) {
        await file.parent.create(recursive: true);
        // Một giây im lặng 48 kHz — đủ ngắn để lặp liên tục mà không tốn gì.
        await file.writeAsBytes(buildWav(Float32List(48000), 48000), flush: true);
      }
      await _giuNhip.setVolume(0);
      await _giuNhip.setPlaylistMode(PlaylistMode.loop);
      await _giuNhip.open(Media(file.path));
    } catch (_) {
      // Mở không được thì thôi, chỉ mất phần chống nuốt chữ.
    }
  }

  /// Luồng im lặng chạy vòng lặp để thiết bị âm thanh không ngủ giữa hai đoạn.
  final Player _giuNhip = Player();

  /// Mã đuôi của đoạn vừa đọc và chỉ số của nó, để nối ngữ cảnh cho đoạn kế.
  List<int> _duoi = const [];
  int _doanCoDuoi = -2;

  /// Đọc trước bao nhiêu đoạn khi có nối ngữ cảnh.
  ///
  /// Chỉ MỘT. Chuỗi phải đi lần lượt nên ba đoạn mất khoảng 4,2 giây — dài xấp
  /// xỉ chính đoạn đang phát, tức là mô hình vẫn đang chạy hết công suất đúng
  /// lúc trình phát mở đoạn kế, và đầu đoạn bị hụt tiếng. Một đoạn mất khoảng
  /// 1,4 giây rồi máy rảnh, thừa sức sẵn sàng trước khi cần tới.
  static const _sauDocTruoc = 1;

  /// Đọc trước mấy đoạn tới cho khỏi khựng ở chỗ chuyển đoạn.
  void _prefetchAround(int from) {
    if (_settings.nguCanhNghe == NguCanh.khong) {
      // Không nối ngữ cảnh thì các đoạn độc lập, bắn hết một lượt cho nhanh.
      final texts = <String>[];
      for (var i = from + 1; i <= min(from + 3, chunks.length - 1); i++) {
        texts.add(chunks[i].speech);
      }
      if (texts.isNotEmpty) {
        _tts.prefetch(
          engineId: _settings.engineId,
          voiceId: _settings.voiceNghe,
          speed: _synthesisSpeed,
          texts: texts,
        );
      }
      return;
    }
    unawaited(_docTruocTheoChuoi(from, _loadToken));
  }

  /// Đọc trước theo chuỗi khi có nối ngữ cảnh.
  ///
  /// Bản trước tắt hẳn việc đọc trước ở chế độ nối ngữ cảnh, nên mỗi lần sang
  /// đoạn mới là phải ngồi chờ mô hình — nghe giật cục ở đúng chỗ nối.
  ///
  /// Nhưng cái chặn không phải là NGHE XONG đoạn trước: chỉ cần đoạn trước tổng
  /// hợp xong là đã có đuôi để bắt đầu đoạn sau. Mà lúc ấy đoạn trước còn đang
  /// phát, tức là có sẵn vài giây rảnh. Mô hình chạy nhanh hơn nhịp nghe (đo
  /// được 2,87 lần thời gian thực) nên đọc trước ba đoạn là thừa sức bù.
  ///
  /// Phải đi lần lượt chứ không bắn song song được: đoạn sau cần đuôi của đoạn
  /// liền trước, chưa có thì chưa bắt đầu được.
  Future<void> _docTruocTheoChuoi(int from, int token) async {
    // Nhường một nhịp cho trình phát mở file và chạy êm đã rồi mới nạp CPU.
    // Mô hình ăn cả bốn luồng, khởi động nó đúng lúc đang mở file mới thì đầu
    // đoạn bị hụt tiếng.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (token != _loadToken) return;

    var ngu = _duoi;
    for (var i = from + 1; i <= min(from + _sauDocTruoc, chunks.length - 1); i++) {
      // Người dùng nhảy sang chỗ khác thì bỏ dở, đừng đốt CPU cho đoạn không ai
      // còn nghe nữa.
      if (token != _loadToken || ngu.isEmpty) return;
      try {
        final audio = await _tts.audioFor(
          engineId: _settings.engineId,
          voiceId: _settings.voiceNghe,
          speed: _synthesisSpeed,
          text: chunks[i].speech,
          nguCanh: ngu,
        );
        ngu = audio.duoi;
      } catch (_) {
        // Đọc trước hỏng thì thôi, lúc thật sự cần sẽ đọc lại và báo lỗi tử tế.
        return;
      }
    }
  }

  Future<void> togglePlay() async {
    if (book == null) return;
    if (_pauseTimer != null) {
      // Bấm dừng đúng lúc đang nghỉ giữa hai đoạn.
      _cancelPause();
      notifyListeners();
      await saveProgress();
    } else if (_player.state.playing) {
      await _player.pause();
      await saveProgress();
    } else if (_player.state.duration == Duration.zero) {
      await playChunk(index, offsetSeconds: book!.progress.offsetSeconds);
    } else {
      await _player.play();
    }
  }

  Future<void> next() => playChunk(min(index + 1, chunks.length - 1), autoplay: isPlaying);

  Future<void> previous() => playChunk(max(index - 1, 0), autoplay: isPlaying);

  Future<void> seekRelative(Duration delta) async {
    final target = position + delta;
    if (target.isNegative) {
      if (index > 0) {
        await playChunk(index - 1, autoplay: isPlaying, offsetSeconds: 9999);
      } else {
        await _player.seek(Duration.zero);
      }
    } else if (target > chunkDuration) {
      await next();
    } else {
      await _player.seek(target);
    }
  }

  /// Nhảy tới một vị trí bất kỳ trong cả cuốn sách (0..1).
  Future<void> seekFraction(double fraction) async {
    final targetSeconds = totalSeconds * fraction * _settings.speed;
    var accumulated = 0.0;
    var target = 0;
    while (target < chunks.length - 1 && accumulated + _chunkSeconds(target) < targetSeconds) {
      accumulated += _chunkSeconds(target);
      target++;
    }
    await playChunk(target, autoplay: isPlaying, offsetSeconds: max(0, targetSeconds - accumulated));
  }

  void _onChunkFinished() {
    if (index + 1 >= chunks.length) {
      unawaited(saveProgress(finished: true));
      return;
    }

    final pause = pauseAfterChunk(
      heading: currentChunk?.heading ?? false,
      pauseMs: _settings.chunkPauseMs,
    );
    if (pause <= Duration.zero) {
      unawaited(playChunk(index + 1));
      return;
    }

    // Nghỉ một nhịp rồi mới đọc tiếp. Người dùng bấm dừng hoặc nhảy đoạn giữa
    // chừng thì bỏ hẹn: [_loadToken] đã đổi nên lượt hẹn cũ tự vô hiệu.
    final token = _loadToken;
    _pauseTimer?.cancel();
    _pauseTimer = Timer(pause, () {
      _pauseTimer = null;
      if (token == _loadToken) unawaited(playChunk(index + 1));
    });
    notifyListeners();
  }

  void _cancelPause() {
    _pauseTimer?.cancel();
    _pauseTimer = null;
  }

  // -- hẹn giờ tắt -----------------------------------------------------------

  void setSleepTimer(Duration? duration) {
    _sleepTimer?.cancel();
    if (duration == null) {
      sleepAt = null;
    } else {
      sleepAt = DateTime.now().add(duration);
      _sleepTimer = Timer(duration, () {
        _player.pause();
        sleepAt = null;
        notifyListeners();
      });
    }
    notifyListeners();
  }

  // -- lưu tiến trình --------------------------------------------------------

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_player.state.playing) unawaited(saveProgress());
    });
  }

  Future<void> saveProgress({bool finished = false}) async {
    final b = book;
    if (b == null) return;
    b.progress
      ..chunkIndex = index
      ..offsetSeconds = position.inMilliseconds / 1000
      ..finished = finished || b.progress.finished;
    await _library.saveProgress(b.id, b.progress, chunkCount: b.chunkCount);
  }

  Future<void> stop() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    _cancelPause();
    if (book != null) await saveProgress();
    await _player.stop();
    position = Duration.zero;
    chunkDuration = Duration.zero;
  }

  @override
  void dispose() {
    unawaited(_giuNhip.dispose());
    _saveTimer?.cancel();
    _sleepTimer?.cancel();
    _pauseTimer?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_player.dispose());
    super.dispose();
  }
}
