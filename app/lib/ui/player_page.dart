/// Màn hình nghe: danh sách chương, nội dung đang đọc và thanh điều khiển.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/book.dart';
import '../models/settings.dart';
import '../services/khoa_cam_ung.dart';
import '../services/player_controller.dart';
import '../services/tay_cam.dart';
import 'app_scope.dart';
import 'chon_giong.dart';
import 'danh_sach_chuong.dart';
import 'dieu_khien_tay_cam.dart';
import 'kinh.dart';
import 'nut_sac.dart';
import 'reading_pane.dart';
import 'theme.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  /// Nút X mở bảng chọn chương. Nghe thẳng dòng lệnh thay vì chờ tiêu điểm rơi
  /// vào thanh chương — đang nghe thì tay cầm thường đang trỏ ở đâu đó khác.
  StreamSubscription<LenhTayCam>? _tayCam;

  /// Bảng đang mở hay không, để bấm X liên tục không chồng nhiều bảng lên nhau.
  bool _dangMoBang = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tayCam?.cancel();
    _tayCam = LenhTayCamScope.cua(context)?.listen(_nhanLenh);
  }

  @override
  void dispose() {
    _tayCam?.cancel();
    super.dispose();
  }

  Future<void> _nhanLenh(LenhTayCam lenh) async {
    if (lenh != LenhTayCam.moChuong || !mounted || _dangMoBang) return;
    final state = AppScope.read(context);
    final book = state.currentBook;
    if (book == null) return;
    // Bố cục rộng đã có sẵn cột chương bên trái, không cần bảng mở lên.
    if (manHinhHaiCot(context) || manHinhRong(context)) return;

    _dangMoBang = true;
    try {
      // Future này hoàn tất khi bảng đóng lại.
      await moBangChuong(context, book, state.player.currentChapter);
    } finally {
      if (mounted) _dangMoBang = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final player = state.player;
    final book = state.currentBook;
    if (book == null) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final chapter = player.currentChapter;
        final wide = manHinhHaiCot(context);

        final reading = ReadingPane(
          // Đổi chương thì dựng lại khung để nó nhảy đúng đoạn đầu chương mới.
          key: ValueKey(chapter?.index),
          chapter: chapter,
          currentIndex: player.index,
          chunks: player.chunks,
          // Chạm vào một đoạn LÀ tua: cắt việc đang đọc trước và im tiếng ngay.
          onTapChunk: (i) =>
              player.playChunk(i, autoplay: player.isPlaying, nguoiDungTua: true),
        );

        return Focus(
          autofocus: true,
          onKeyEvent: (node, event) => _handleKey(event, player),
          child: Column(
            children: [
              // Màn hình hẹp không đủ chỗ cho danh sách chương cố định, nên nó
              // nằm sau một nút mở lên từ dưới — không có thì trên điện thoại
              // chẳng có cách nào nhảy tới chương mình muốn.
              if (!wide) _ChapterBar(book: book, chapter: chapter),
              Expanded(
                child: wide
                    ? Row(
                        children: [
                          SizedBox(
                            width: 280,
                            child: DanhSachChuong(
                              book: book,
                              currentChapter: chapter,
                              onChon: (chuong) => player.playChunk(
                                chuong.firstChunk,
                                autoplay: player.isPlaying,
                              ),
                            ),
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(child: reading),
                        ],
                      )
                    : reading,
              ),
              const Divider(height: 1),
              const _ChonGiongNghe(),
              // KHÔNG được const: build() đọc thẳng player.isPlaying/elapsed từ
              // AppScope thay vì tự bọc ListenableBuilder riêng như _ChonGiongNghe
              // — chỉ trông cậy đúng vào AnimatedBuilder(animation: player) phía
              // trên để được vẽ lại. const làm Flutter coi đây là widget "không
              // đổi" giữa các lượt build của Column cha, bỏ qua build() lại từ lần
              // thứ hai — nút phát/tạm dừng, đồng hồ, thanh tiến trình đứng hình.
              _PlayerBar(),
            ],
          ),
        );
      },
    );
  }

  KeyEventResult _handleKey(KeyEvent event, PlayerController player) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        player.togglePlay();
      case LogicalKeyboardKey.arrowRight:
        player.seekRelative(const Duration(seconds: 15));
      case LogicalKeyboardKey.arrowLeft:
        player.seekRelative(const Duration(seconds: -15));
      case LogicalKeyboardKey.arrowDown:
        player.next();
      case LogicalKeyboardKey.arrowUp:
        player.previous();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }
}

class _PlayerBar extends StatelessWidget {
  // Cố ý KHÔNG const — xem chú thích ở chỗ dựng widget này trong PlayerPage.
  // ignore: prefer_const_constructors_in_immutables
  _PlayerBar();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final player = state.player;
    final hint = Theme.of(context).hintColor;

    final total = player.totalSeconds;
    final elapsed = player.elapsedSeconds;
    final fraction = total > 0 ? (elapsed / total).clamp(0.0, 1.0) : 0.0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
      child: Column(
        children: [
          // Chỉ hiện tiến trình, không tua được: sách dài cả chục giờ, chạm hụt
          // một chút trên thanh này là nhảy vọt sang chỗ khác rất xa. Muốn tua
          // thì dùng nút lùi/tiến 15 giây hay chọn thẳng chương/đoạn.
          //
          // Đang tải/tổng hợp thì báo bằng một chấm tròn nhấp nháy đúng vị trí
          // trên thanh này — không dùng nút phát để báo việc đó nữa, kẻo icon
          // của nút lẫn với trạng thái đang phát/tạm dừng thật.
          LayoutBuilder(
            builder: (context, constraints) {
              const duongKinh = 14.0;
              final left = (constraints.maxWidth * fraction - duongKinh / 2)
                  .clamp(0.0, constraints.maxWidth - duongKinh);
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  ThanhKinh(phan: fraction, sac: SacNut.chinh, cao: 8),
                  if (player.isLoading)
                    Positioned(
                      left: left,
                      top: 4 - duongKinh / 2,
                      child: const IgnorePointer(child: _ChamDangTai()),
                    ),
                ],
              );
            },
          ),
          Row(
            children: [
              Text(formatTime(elapsed), style: TextStyle(fontSize: 12.5, color: hint)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  player.error ??
                      'Đoạn ${player.index + 1}/${player.chunks.length}'
                          '${player.currentChapter == null ? '' : ' · ${player.currentChapter!.title}'}',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: player.error != null ? Theme.of(context).colorScheme.error : hint,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(formatTime(total), style: TextStyle(fontSize: 12.5, color: hint)),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              IconButton(
                tooltip: 'Đoạn trước (↑)',
                onPressed: player.previous,
                icon: const Icon(Icons.skip_previous),
              ),
              _NutKinh(
                chuThich: 'Lùi 15 giây (←)',
                hinh: Icons.replay_10_rounded,
                onNhan: () => player.seekRelative(const Duration(seconds: -15)),
              ),
              SizedBox(
                width: 56,
                height: 56,
                // Luôn theo đúng isPlaying — không đổi sang vòng xoay lúc đang
                // tải nữa, xem chấm nhấp nháy trên thanh tiến trình ở trên.
                child: NutTron(
                  hinh: player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  chuThich: player.isPlaying ? 'Tạm dừng (Space)' : 'Phát (Space)',
                  onNhan: player.togglePlay,
                ),
              ),
              _NutKinh(
                chuThich: 'Tiến 15 giây (→)',
                hinh: Icons.forward_10_rounded,
                onNhan: () => player.seekRelative(const Duration(seconds: 15)),
              ),
              IconButton(
                tooltip: 'Đoạn sau (↓)',
                onPressed: player.next,
                icon: const Icon(Icons.skip_next),
              ),
              const SizedBox(width: 10),
              _SpeedSelector(),
              _SleepButton(),
              _SoiAmButton(),
              _KhoaCamUngButton(),
            ],
          ),
        ],
      ),
    );
  }
}

/// Chấm tròn nhấp nháy báo đang tải/tổng hợp — đặt đúng vị trí trên thanh tiến
/// trình, dáng giống nút kéo của thanh tua cũ nhưng không bắt cử chỉ nào cả.
class _ChamDangTai extends StatefulWidget {
  const _ChamDangTai();

  @override
  State<_ChamDangTai> createState() => _ChamDangTaiState();
}

class _ChamDangTaiState extends State<_ChamDangTai> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 650))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: Tween(begin: 0.7, end: 1.15).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
      child: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 3, offset: const Offset(0, 1))],
        ),
      ),
    );
  }
}

class _SpeedSelector extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return DropdownButton<double>(
      value: tocDoChon.contains(state.settings.speed) ? state.settings.speed : 1.0,
      underline: const SizedBox.shrink(),
      borderRadius: BorderRadius.circular(10),
      items: [
        for (final s in tocDoChon)
          DropdownMenuItem(value: s, child: Text(nhanTocDo(s))),
      ],
      onChanged: (value) {
        if (value != null) AppScope.read(context).setSpeed(value);
      },
    );
  }
}

/// Bật/tắt việc soi âm trước khi phát.
///
/// Đặt cạnh nút hẹn giờ chứ không ở bảng chọn giọng: cả hai đều là thứ bật một
/// cái rồi để đấy mà nghe, không phải thứ chỉnh theo từng đoạn.
///
/// Chỉ một cái icon, không kèm chữ: hàng điều khiển đã chật, mà trạng thái thì
/// đọc được bằng màu. Bản trước dùng `TextButton.icon` — nó luôn tô màu nhấn nên
/// bật hay tắt trông y hệt nhau, tức là cái nút không nói được điều duy nhất nó
/// cần nói.
///
/// Chỉ hiện với engine đọc lại ra bản khác — engine đọc theo luật (Piper, TTS hệ
/// thống) thì đọc lại vẫn ra đúng bản cũ, bật lên chỉ tốn thời gian.
class _SoiAmButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    if (!state.tts.engine(state.settings.engineId).docLaiRaKhac) {
      return const SizedBox.shrink();
    }
    final bat = state.settings.soiAmKhiNghe;

    // Dựng đúng kiểu nút "Hẹn giờ" ngay bên cạnh: `TextButton.icon`, và màu lấy
    // qua `foregroundColor` của nút chứ KHÔNG gán thẳng vào `Icon`.
    //
    // Ba bản trước đều dùng `IconButton` với `Icon(color: ...)` và lần nào icon
    // cũng không vẽ ra gì — chỉ còn cái vòng bấm rỗng, dù tooltip vẫn chạy. Nút
    // hẹn giờ dùng cách này thì hiện bình thường, nên cứ theo cách đang chạy
    // được thay vì tiếp tục đoán vì sao cách kia hỏng.
    //
    // Nút thể hiện TRẠNG THÁI ĐANG CÓ, không phải việc sẽ làm khi bấm:
    // vàng là đang bật, trắng là đang tắt.
    //
    // Màu trắng lấy từ `onSurface` chứ không gán cứng `Colors.white`: ở chế độ
    // tối nó ra gần như trắng, mà sang chế độ sáng thì tự thành gần đen — trắng
    // gán cứng ở đó là mất hút trên nền giấy.
    final mau = bat ? SacNut.chinh.first : Theme.of(context).colorScheme.onSurface;

    return Tooltip(
      message: bat
          ? 'Kiểm tra trước khi phát: ĐANG BẬT — đoạn đọc hỏng sẽ được đọc lại (tối đa 2 lần)'
          : 'Kiểm tra trước khi phát: đang tắt',
      child: TextButton.icon(
        style: TextButton.styleFrom(
          foregroundColor: mau,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: const Size(0, 40),
        ),
        onPressed: () {
          state.settings.soiAmKhiNghe = !bat;
          AppScope.read(context).saveSettings();
        },
        // MỘT icon cho cả hai trạng thái, chỉ đổi màu.
        //
        // Không phải chọn cho gọn: bản đặc (`check_circle`, trước đó là
        // `verified_rounded`) không vẽ ra gì trên máy này, trong khi bản viền
        // hiện bình thường — thử ba cặp icon đều đúng như vậy. Giữ một glyph đã
        // biết chắc vẽ được thì bỏ hẳn được biến gây lỗi ấy.
        icon: const Icon(Icons.check_circle_outline, size: 20),
        // Chữ ăn theo `foregroundColor` của nút nên luôn cùng màu với icon,
        // khỏi phải đặt màu ở hai chỗ rồi có ngày lệch nhau.
        label: const Text('Kiểm âm'),
      ),
    );
  }
}

/// Khoá cảm ứng — chắn mọi thao tác cho tới khi trượt để mở.
///
/// Đỏ để nổi hẳn khỏi hàng: đây là nút duy nhất ở đây làm giao diện ngừng nhận
/// thao tác, người dùng cần thấy ngay mình sắp bấm cái gì.
///
/// Chỉ có trên Android. Trên máy tính thì chạm nhầm không phải vấn đề, mà việc
/// hạ sáng cũng là API riêng của Android — xem `services/khoa_cam_ung.dart`.
class _KhoaCamUngButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    if (!khoaCamUngDungDuoc) return const SizedBox.shrink();

    return Tooltip(
      message: 'Khoá cảm ứng — hạ sáng màn hình, trượt để mở lại',
      child: TextButton.icon(
        style: TextButton.styleFrom(
          foregroundColor: SacNut.nguyHiem.first,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: const Size(0, 40),
        ),
        onPressed: () => AppScope.read(context).batKhoaCamUng(),
        icon: const Icon(Icons.lock_outline, size: 20),
        label: const Text('Khoá'),
      ),
    );
  }
}

class _SleepButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final player = AppScope.of(context).player;
    final active = player.sleepAt != null;

    return TextButton.icon(
      icon: Icon(active ? Icons.bedtime : Icons.bedtime_outlined, size: 18),
      label: Text(active ? 'Còn ${formatTime(player.sleepAt!.difference(DateTime.now()).inSeconds.toDouble())}' : 'Hẹn giờ'),
      onPressed: () async {
        final minutes = await showDialog<int>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Hẹn giờ tắt'),
            children: [
              for (final m in [10, 20, 30, 45, 60])
                SimpleDialogOption(onPressed: () => Navigator.pop(context, m), child: Text('$m phút')),
              SimpleDialogOption(onPressed: () => Navigator.pop(context, 0), child: const Text('Tắt hẹn giờ')),
            ],
          ),
        );
        if (minutes != null) {
          player.setSleepTimer(minutes == 0 ? null : Duration(minutes: minutes));
        }
      },
    );
  }
}

/// Thanh chương cho màn hình hẹp: tên chương đang nghe và nút mở danh sách.
class _ChapterBar extends StatelessWidget {
  const _ChapterBar({required this.book, required this.chapter});
  final Book book;
  final Chapter? chapter;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hint = Theme.of(context).hintColor;
    final position = chapter == null
        ? ''
        : '${book.chapters.indexWhere((c) => c.index == chapter!.index) + 1}/${book.chapters.length}';

    return Material(
      color: scheme.surfaceContainerHighest,
      child: InkWell(
        onTap: () => _openChapters(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 9, 10, 9),
          child: Row(
            children: [
              Icon(Icons.list_alt_outlined, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      chapter?.title ?? book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
                    ),
                    if (position.isNotEmpty)
                      Text('Chương $position', style: TextStyle(fontSize: 11.5, color: hint)),
                  ],
                ),
              ),
              Icon(Icons.expand_more, size: 20, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  void _openChapters(BuildContext context) => moBangChuong(context, book, chapter);
}

/// Mở bảng chọn chương từ dưới lên.
///
/// Tách khỏi [_ChapterBar] vì nút X trên tay cầm cũng gọi tới — xem
/// [_PlayerPageState._nhanLenh].
Future<void> moBangChuong(BuildContext context, Book book, Chapter? chapter) {
  final state = AppScope.read(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => AppScope(
      state: state,
      child: FractionallySizedBox(
        heightFactor: 0.85,
        // Chọn chương xong thì đóng luôn, khỏi phải bấm thêm lần nữa.
        child: DanhSachChuong(
          book: book,
          currentChapter: chapter,
          // Mở bảng ra là tay cầm lái được ngay, khỏi phải mò tiêu điểm.
          tuNhanTieuDiem: true,
          onChon: (chuong) => state.player.playChunk(
            chuong.firstChunk,
            autoplay: state.player.isPlaying,
          ),
          onPicked: () => Navigator.of(sheetContext).pop(),
        ),
      ),
    ),
  );
}

/// Chọn giọng và cách nối ngữ cảnh cho việc nghe.
///
/// Đặt ngay trên thanh phát chứ không giấu trong Cài đặt: đây là hai thứ người
/// nghe hay đổi nhất, mà đổi xong là nghe thấy khác ngay.
class _ChonGiongNghe extends StatelessWidget {
  const _ChonGiongNghe();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final settings = state.settings;
    // Trạng thái phát nằm ở PlayerController chứ không phải AppState, phải nghe
    // riêng — không thì bấm phát xong khoá vẫn chưa hiện.
    return ListenableBuilder(
      listenable: state.player,
      builder: (context, _) {
        final dangDoiGiong = state.player.dangTongHopTruocGiong;
        // Hỏi chính engine chứ đừng gán cứng mã: thêm engine mới mà quên sửa
        // chỗ này là ô hiện sai ngay.
        final engine = state.tts.engine(settings.engineId);
        final khongHoTroNguCanh = !engine.noiNguCanh;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
          child: BangChonGiong(
            voices: state.voices,
            voiceId: settings.voiceNghe,
            nguCanh: settings.nguCanhNghe,
            // Đang nghe vẫn đổi giọng được — đoạn kế được tổng hợp trước bằng
            // giọng mới trong lúc đoạn này còn đang phát. Chỉ khoá đúng lúc việc
            // tổng hợp trước đó đang chạy, và luôn khoá cách nối ngữ cảnh vì nó
            // gắn liền với đoạn đang phát.
            dangTaiGiong: dangDoiGiong != null,
            khoaGiong: dangDoiGiong != null ? 'Đang chuẩn bị giọng mới cho đoạn sau…' : null,
            khoaNguCanh: khongHoTroNguCanh
                ? 'Chỉ VieNeu hỗ trợ nối ngữ cảnh'
                : (state.player.isPlaying ? 'Tạm dừng nghe rồi mới đổi được' : null),
            onVoice: (v) => AppScope.read(context).setVoiceNghe(v),
            onNguCanh: (v) {
              settings.nguCanhNghe = v;
              AppScope.read(context).saveSettings();
            },
          ),
        );
      },
    );
  }
}

/// Nút tròn bằng kính cho hàng điều khiển.
///
/// Nút phát ở giữa vẫn là vòng chuyển sắc đặc — một màn hình chỉ nên có một thứ
/// nổi bật nhất, mấy nút phụ quanh nó lùi về làm kính.
class _NutKinh extends StatelessWidget {
  const _NutKinh({required this.hinh, required this.chuThich, required this.onNhan});

  final IconData hinh;
  final String chuThich;
  final VoidCallback onNhan;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: chuThich,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onNhan,
            child: KinhTron(
              canh: 42,
              child: Icon(hinh, size: 21, color: Theme.of(context).colorScheme.onSurface),
            ),
          ),
        ),
      ),
    );
  }
}
