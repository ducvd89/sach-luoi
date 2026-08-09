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

  bool get isPlaying => _player.state.playing;
  bool isLoading = false;
  String? error;

  /// Thời lượng thật của các đoạn đã biết, dùng để vẽ thanh tiến trình cả sách.
  final Map<int, double> _durations = {};

  Duration position = Duration.zero;
  Duration chunkDuration = Duration.zero;

  Timer? _saveTimer;
  Timer? _sleepTimer;
  DateTime? sleepAt;

  /// Khoảng lặng (ms) đã ghép vào đầu file đang mở — 0 nếu mở thẳng bản gốc.
  ///
  /// Trừ ra khỏi [position]/[chunkDuration] khi báo cho giao diện, để đồng hồ
  /// và thanh tiến trình cả sách vẫn tính đúng thời lượng LỜI ĐỌC, không lẫn
  /// phần lặng nướng thêm vào chỉ để giữ luồng âm thanh không đứt quãng.
  int _openSilenceMs = 0;

  /// File tạm của lượt ghép lặng gần nhất, dọn khi có file mới thay vào —
  /// xem [_duongDanPhat].
  File? _fileGhepTruoc;
  int _loadToken = 0;
  AppSettings _settings = AppSettings();

  final List<StreamSubscription<dynamic>> _subscriptions = [];

  void attachStreams() {
    _giuThietBiAmThanh();
    _subscriptions.addAll([
      _player.stream.position.listen((value) {
        final thuc = value - Duration(milliseconds: _openSilenceMs);
        position = thuc.isNegative ? Duration.zero : thuc;
        notifyListeners();
      }),
      _player.stream.duration.listen((value) {
        if (value > Duration.zero) {
          final thuc = value - Duration(milliseconds: _openSilenceMs);
          chunkDuration = thuc.isNegative ? Duration.zero : thuc;
          _durations[index] = chunkDuration.inMilliseconds / 1000;
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
    return b.charCount / charsPerSecond / b.chunkCount;
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
    final dangPhat = isPlaying;
    _settings = settings;
    _player.setRate(settings.speed);
    if (voiceChanged && book != null) {
      _durations.clear();
      if (dangPhat) {
        // Đang nghe: không ngắt đoạn hiện tại giữa chừng, chỉ tổng hợp trước
        // đoạn kế bằng giọng mới cho khỏi phải chờ đúng lúc chuyển sang đoạn đó.
        unawaited(_doiGiongKhiDangNghe(settings.engineId, settings.voiceNghe));
      } else {
        unawaited(playChunk(index, autoplay: false));
      }
    }
    notifyListeners();
  }

  /// Đổi giọng khi đang nghe: đoạn đang phát vẫn giữ nguyên giọng cũ tới hết,
  /// chỉ tổng hợp trước đoạn KẾ TIẾP bằng giọng mới. Đổi ngay giữa đoạn thì
  /// tiếng đang nghe cụt lủn nửa chừng; đợi đoạn xong mới tổng hợp thì khựng
  /// đúng chỗ chuyển đoạn — tổng hợp trước trong lúc đoạn này còn đang phát là
  /// né được cả hai.
  ///
  /// [dangTongHopTruocGiong] khác null suốt lúc này, để giao diện khoá không
  /// cho chọn giọng khác chồng lên và hiện tiến trình.
  Future<void> _doiGiongKhiDangNghe(String engineId, String voiceId) async {
    if (_dangTongHopTruocGiong != null) return; // giao diện đã khoá, chặn kép cho chắc
    final target = index + 1;
    if (target >= chunks.length) return;

    _dangTongHopTruocGiong = voiceId;
    notifyListeners();
    try {
      // Không truyền ngữ cảnh: giọng mới không có gì để nối từ đoạn cũ, đoạn
      // kế coi như mở đầu một mạch mới — xem thêm kiểm tra giọng/engine ở
      // playChunk khi tính noiTiep.
      await _tts.audioFor(
        engineId: engineId,
        voiceId: voiceId,
        speed: _synthesisSpeed,
        text: chunks[target].speech,
      );
    } catch (_) {
      // Tổng hợp trước hỏng thì thôi — lúc sang thật đoạn kế sẽ tổng hợp lại
      // và báo lỗi tử tế nếu vẫn hỏng.
    } finally {
      _dangTongHopTruocGiong = null;
      notifyListeners();
    }
  }

  /// Giọng đang được tổng hợp trước cho đoạn kế (đổi giọng lúc đang nghe), null
  /// nghĩa là không có việc này đang chạy. Giao diện dùng để khoá ô chọn giọng
  /// và hiện tiến trình.
  String? _dangTongHopTruocGiong;
  String? get dangTongHopTruocGiong => _dangTongHopTruocGiong;

  // -- điều khiển ------------------------------------------------------------

  /// [leadingSilenceMs] là khoảng nghỉ nướng vào đầu file trước khi mở, dùng
  /// đúng một lần cho lượt tự động sang đoạn kế — xem [_onChunkFinished]. Mọi
  /// lượt gọi khác (bấm nút, tua, tiếp tục nghe) đều là 0: nhảy tới đâu thì
  /// nghe ngay ở đó, không có khoảng nghỉ nào cả.
  Future<void> playChunk(
    int target, {
    bool autoplay = true,
    double offsetSeconds = 0,
    int leadingSilenceMs = 0,
  }) async {
    final b = book;
    if (b == null || target < 0 || target >= chunks.length) return;

    final token = ++_loadToken;
    index = target;
    isLoading = true;
    error = null;
    notifyListeners();

    try {
      // Ngữ cảnh chỉ dùng khi đọc tiếp đúng đoạn liền sau đoạn vừa nghe, VÀ
      // bằng đúng giọng đã sinh ra đuôi đó. Nhảy lung tung, hay giọng vừa đổi
      // giữa chừng, thì bỏ — đuôi của giọng cũ nối vào giọng mới chỉ làm giọng
      // mới bị kéo lệch về giọng cũ.
      final noiTiep = _settings.nguCanhNghe != NguCanh.khong &&
          target == _doanCoDuoi + 1 &&
          _duoiGiong == _settings.voiceNghe &&
          _duoiEngine == _settings.engineId;
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
      _duoiGiong = _settings.voiceNghe;
      _duoiEngine = _settings.engineId;
      _durations[target] = audio.seconds;

      final (duongDan, lang) = await _duongDanPhat(audio.file, leadingSilenceMs);
      if (token != _loadToken) return; // nhảy đoạn khác ngay trong lúc ghép file
      _openSilenceMs = lang;
      await _player.open(Media(duongDan), play: autoplay);
      await _player.setRate(_settings.speed);
      _dongBoGiuNhip(autoplay);
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
      // play: false — chỉ nạp sẵn, chưa phát. Người dùng tự bấm dừng thì nên
      // dừng thật, không có lý do gì giữ giả một luồng chạy trong lúc đó; luồng
      // này chỉ bật đúng lúc có tiếng thật đang phát, xem _dongBoGiuNhip.
      await _giuNhip.open(Media(file.path), play: false);
    } catch (_) {
      // Mở không được thì thôi, chỉ mất phần chống nuốt chữ.
    }
  }

  /// Luồng im lặng chạy vòng lặp để thiết bị âm thanh không ngủ giữa hai đoạn.
  ///
  /// Chỉ chạy trong lúc THẬT SỰ đang phát — xem [_dongBoGiuNhip]. Bấm dừng thì
  /// dừng thật, không giả vờ giữ thiết bị thức trong lúc người nghe không nghe
  /// gì cả.
  final Player _giuNhip = Player();

  /// Bật/tắt luồng giữ nhịp theo đúng ý định phát/dừng của người dùng.
  void _dongBoGiuNhip(bool dangPhat) {
    if (dangPhat) {
      unawaited(_giuNhip.play());
    } else {
      unawaited(_giuNhip.pause());
    }
  }

  /// Mã đuôi của đoạn vừa đọc, chỉ số của nó, và giọng/engine đã sinh ra nó —
  /// để nối ngữ cảnh cho đoạn kế. Phải nhớ cả giọng/engine vì đổi giọng lúc
  /// đang nghe không huỷ ngay đuôi cũ, chỉ đoạn kế mới hết dùng được nó.
  List<int> _duoi = const [];
  int _doanCoDuoi = -2;
  String _duoiGiong = '';
  String _duoiEngine = '';

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

    // Chụp giọng/engine ngay từ đây: đổi giọng lúc đang nghe không tăng
    // _loadToken (đoạn đang phát vẫn giữ nguyên), nên nếu đọc thẳng từ
    // _settings mỗi vòng thì đọc trước có thể lỡ đổi giọng giữa chừng mà vẫn
    // nối vào đuôi của giọng cũ.
    final engineId = _settings.engineId;
    final voiceId = _settings.voiceNghe;

    var ngu = _duoi;
    for (var i = from + 1; i <= min(from + _sauDocTruoc, chunks.length - 1); i++) {
      // Người dùng nhảy sang chỗ khác thì bỏ dở, đừng đốt CPU cho đoạn không ai
      // còn nghe nữa.
      if (token != _loadToken || ngu.isEmpty) return;
      try {
        final audio = await _tts.audioFor(
          engineId: engineId,
          voiceId: voiceId,
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
    if (_player.state.playing) {
      await _player.pause();
      _dongBoGiuNhip(false);
      await saveProgress();
    } else if (_player.state.duration == Duration.zero) {
      await playChunk(index, offsetSeconds: book!.progress.offsetSeconds);
    } else {
      await _player.play();
      _dongBoGiuNhip(true);
    }
    // Không chỉ trông chờ luồng `playing` của trình phát: đã thấy trên Android
    // nút phát/tạm dừng đổi icon rất trễ hoặc không đổi, dù tiếng vẫn phát hay
    // dừng đúng — báo thẳng ngay tại đây cho chắc, khỏi phụ thuộc luồng đó.
    notifyListeners();
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

  /// Hết một đoạn thì mở đoạn kế NGAY — không còn đứng im chờ một khoảng
  /// Timer rồi mới mở file mới.
  ///
  /// Bản trước dừng hẳn giữa hai đoạn trong lúc chờ (đúng khoảng nghỉ người
  /// nghe muốn có). Khoảng đứng im đó là lúc thiết bị âm thanh của máy có cơ
  /// hội ngủ, và phần đầu đoạn kế mở ra sau đó hay bị hụt tiếng — xác nhận bằng
  /// cách bật phần mềm ghi âm màn hình lên thì hết hụt, vì nó vô tình giữ thiết
  /// bị luôn thức.
  ///
  /// Giờ khoảng nghỉ được nướng thành mẫu âm lặng ngay ở ĐẦU file đoạn kế
  /// ([playChunk] gọi [_duongDanPhat]), rồi phát nối liền tức thì. Luồng âm
  /// thanh gửi cho thiết bị không có lúc nào ngừng hẳn nên không có gì để ngủ.
  /// Cùng lúc vẫn giữ luồng lặng chạy nền ([_giuThietBiAmThanh]) phòng khi
  /// người nghe tự bấm dừng lâu — trường hợp đó không đoán trước được nên
  /// không nướng lặng vào file được.
  void _onChunkFinished() {
    if (index + 1 >= chunks.length) {
      unawaited(saveProgress(finished: true));
      return;
    }
    final pauseMs = pauseAfterChunk(
      heading: currentChunk?.heading ?? false,
      pauseMs: _settings.chunkPauseMs,
    ).inMilliseconds;
    unawaited(_sangDoanKe(pauseMs));
  }

  /// Đợi bộ đệm phần cứng xả hết tiếng đoạn vừa xong rồi mới mở đoạn kế.
  ///
  /// Không đợi thì [_player.open] xảy ra ngay lúc bộ đệm mpv (mặc định đệm
  /// trước 200 ms — audio-buffer) còn đang xả xuống loa; mở file mới xen vào
  /// đúng lúc đó cắt mất một âm ở cuối đoạn vừa đọc. Đo được đúng triệu chứng
  /// này sau khi bỏ khoảng chờ Timer cũ.
  ///
  /// 200 ms (đúng bằng audio-buffer) vẫn còn hụt nhẹ trên máy thật — bộ đệm
  /// thật của thiết bị (driver + hệ điều hành, không chỉ phần mpv tự khai) rõ
  /// ràng dày hơn con số mpv báo. Nâng lên 400 ms.
  ///
  /// Ngắn hơn nhiều so với khoảng nghỉ người dùng đặt, và [_giuNhip] vẫn đang
  /// chạy suốt lúc này (đang phát thật mà) nên thiết bị không có gì phải ngủ
  /// trong nhịp chờ ngắn này. Phần còn lại của khoảng nghỉ vẫn nướng vào đầu
  /// file đoạn kế như cũ.
  static const _nhipXaDem = 400;

  Future<void> _sangDoanKe(int pauseMs) async {
    final token = _loadToken;
    await Future<void>.delayed(const Duration(milliseconds: _nhipXaDem));
    if (token != _loadToken) return; // đã nhảy đi chỗ khác trong lúc đợi
    final lang = max(0, pauseMs - _nhipXaDem);
    await playChunk(index + 1, leadingSilenceMs: lang);
  }

  /// Đường dẫn thật sự đưa cho trình phát.
  ///
  /// [leadingSilenceMs] > 0 thì ghép khoảng lặng vào đầu [file] rồi ghi ra một
  /// file tạm và trả đường dẫn của nó; không ghép được (không dương, không
  /// phải WAV hợp lệ, hay lỗi đọc/ghi) thì trả thẳng đường dẫn gốc. Trả kèm số
  /// mili giây lặng THẬT SỰ đã ghép, để [playChunk] biết trừ bù cho đồng hồ.
  Future<(String, int)> _duongDanPhat(File file, int leadingSilenceMs) async {
    if (leadingSilenceMs <= 0) return (file.path, 0);
    try {
      final goc = await file.readAsBytes();
      final ghep = wavWithLeadingSilence(goc, leadingSilenceMs);
      if (identical(ghep, goc)) return (file.path, 0); // không phải WAV, hoặc lặng = 0

      // Tên file mới mỗi lượt, không ghi đè: file cũ có thể vẫn đang được trình
      // phát đọc dở (trên Windows, ghi đè file đang mở là lỗi). Đến lượt sau,
      // đoạn vừa phát chắc chắn đã đọc xong (completed đã bắn) nên xoá được.
      final tmp = File(p.join(
        Storage.instance.cacheDir.path,
        'phat',
        'ghep_${DateTime.now().microsecondsSinceEpoch}.wav',
      ));
      await tmp.parent.create(recursive: true);
      await tmp.writeAsBytes(ghep, flush: true);

      final cu = _fileGhepTruoc;
      _fileGhepTruoc = tmp;
      if (cu != null) unawaited(cu.delete().catchError((_) => cu));

      return (tmp.path, leadingSilenceMs);
    } catch (_) {
      return (file.path, 0); // ghép hỏng thì phát thẳng bản gốc, mất mỗi khoảng lặng
    }
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
        _dongBoGiuNhip(false);
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
    if (book != null) await saveProgress();
    await _player.stop();
    _dongBoGiuNhip(false);
    position = Duration.zero;
    chunkDuration = Duration.zero;
    _openSilenceMs = 0;
  }

  @override
  void dispose() {
    unawaited(_giuNhip.dispose());
    _saveTimer?.cancel();
    _sleepTimer?.cancel();
    final ghep = _fileGhepTruoc;
    if (ghep != null) unawaited(ghep.delete().catchError((_) => ghep));
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_player.dispose());
    super.dispose();
  }
}
