/// Đưa sách đang nghe lên phần "Đang phát" của hệ điều hành.
///
/// Nhờ vậy điều khiển được từ màn hình khoá, từ khu thông báo và từ nút trên
/// tai nghe — thứ gần như bắt buộc với một ứng dụng sách nói, vì người ta nghe
/// lúc đi đường chứ không mở app ra nhìn.
///
/// Lớp này chỉ là cầu nối: mọi việc phát vẫn do [PlayerController] làm, ở đây
/// chỉ dịch qua lại giữa lệnh của hệ điều hành và hàm của bộ phát, đồng thời
/// báo ngược trạng thái lên.
library;

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';

import 'player_controller.dart';

/// Hệ nào có khái niệm "Đang phát" để cắm vào.
bool get mediaSessionSupported => Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

class SachLuoiAudioHandler extends BaseAudioHandler with SeekHandler {
  SachLuoiAudioHandler(this._player) {
    // Bộ phát báo mỗi khi trạng thái đổi; đẩy tiếp lên hệ điều hành.
    _player.addListener(_publish);
    _publish();
  }

  final PlayerController _player;

  /// Tua nhanh/lùi bằng 15 giây, khớp với hai nút trong ứng dụng.
  static const _step = Duration(seconds: 15);

  @override
  Future<void> play() async {
    if (!_player.isPlaying) await _player.togglePlay();
  }

  @override
  Future<void> pause() async {
    if (_player.isPlaying) await _player.togglePlay();
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> skipToNext() => _player.next();

  @override
  Future<void> skipToPrevious() => _player.previous();

  @override
  Future<void> fastForward() => _player.seekRelative(_step);

  @override
  Future<void> rewind() => _player.seekRelative(-_step);

  /// Thanh tua trên thông báo tính theo cả cuốn sách, không phải theo đoạn.
  @override
  Future<void> seek(Duration position) async {
    final total = _player.totalSeconds;
    if (total <= 0) return;
    await _player.seekFraction((position.inMilliseconds / 1000 / total).clamp(0.0, 1.0));
  }

  /// Nút tai nghe: bấm một cái là phát/dừng.
  ///
  /// Nhiều tai nghe gửi lệnh này thay vì play/pause riêng lẻ, nên phải xử lý
  /// riêng chứ không thể bỏ qua.
  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    switch (button) {
      case MediaButton.media:
        await _player.togglePlay();
      case MediaButton.next:
        await _player.next();
      case MediaButton.previous:
        await _player.previous();
    }
  }

  void _publish() {
    final book = _player.book;
    if (book == null) return;

    final chapter = _player.currentChapter;
    mediaItem.add(MediaItem(
      id: book.id,
      title: chapter?.title ?? book.title,
      album: book.title,
      artist: book.author.isEmpty ? 'Sách nói' : book.author,
      duration: Duration(milliseconds: (_player.totalSeconds * 1000).round()),
    ));

    playbackState.add(PlaybackState(
      controls: [
        MediaControl.rewind,
        if (_player.isPlaying) MediaControl.pause else MediaControl.play,
        MediaControl.fastForward,
      ],
      systemActions: const {MediaAction.seek, MediaAction.skipToNext, MediaAction.skipToPrevious},
      // Ba nút hiện ngoài màn hình khoá; phần còn lại nằm trong khu mở rộng.
      androidCompactActionIndices: const [0, 1, 2],
      processingState:
          _player.isLoading ? AudioProcessingState.loading : AudioProcessingState.ready,
      playing: _player.isPlaying,
      updatePosition: Duration(milliseconds: (_player.elapsedSeconds * 1000).round()),
      speed: 1.0,
      queueIndex: _player.index,
    ));
  }

  void detach() => _player.removeListener(_publish);
}

/// Bật tích hợp "Đang phát". Trả về null trên hệ không hỗ trợ.
///
/// Lỗi ở đây không được làm sập ứng dụng: nghe trong app vẫn phải chạy được kể
/// cả khi hệ điều hành từ chối dựng phiên phát.
Future<SachLuoiAudioHandler?> startMediaSession(PlayerController player) async {
  if (!mediaSessionSupported) return null;
  try {
    return await AudioService.init(
      builder: () => SachLuoiAudioHandler(player),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.sachnoi.sach_noi.audio',
        androidNotificationChannelName: 'Sách lười',
        // Giữ thông báo cả khi tạm dừng: người nghe hay dừng vài phút rồi nghe
        // tiếp, mất thông báo là mất luôn chỗ bấm phát lại.
        androidStopForegroundOnPause: false,
        // Không đặt ongoing: thông báo không xoá được thì lại vướng khi đã nghe
        // xong, mà audio_service cũng không cho đi kèm tuỳ chọn ở trên.
        androidNotificationOngoing: false,
      ),
    );
  } catch (err) {
    // ignore: avoid_print
    print('Không bật được phần "Đang phát": $err');
    return null;
  }
}
