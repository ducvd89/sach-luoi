/// Khung chính: thanh điều hướng bên trái và thanh phát cố định dưới cùng.
library;

import 'package:flutter/material.dart';

import 'app_scope.dart';
import 'kinh.dart';
import 'nut_sac.dart';
import 'export_page.dart';
import 'library_page.dart';
import 'mini_player.dart';
import 'player_page.dart';
import 'settings_page.dart';
import 'theme.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => HomeShellState();
}

class HomeShellState extends State<HomeShell> {
  int _index = 0;

  /// Cho các màn hình khác chuyển tab (ví dụ bấm "Nghe" ở thư viện).
  static HomeShellState? of(BuildContext context) => context.findAncestorStateOfType<HomeShellState>();

  void goTo(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final hasBook = state.currentBook != null;
    // Máy gập mở ra là đủ rộng để ăn bố cục như bản máy tính.
    final wide = manHinhRong(context);

    final pages = [
      const LibraryPage(),
      hasBook ? const PlayerPage() : const _NoBook(message: 'Chọn một cuốn sách trong thư viện để bắt đầu nghe'),
      // Không đòi phải mở sách trước: màn hình xuất tự cho chọn sách.
      const ExportPage(),
      const SettingsPage(),
    ];

    // Mỗi mục một cặp màu riêng, như bộ nút mẫu — nhìn màu là biết đang ở đâu,
    // khỏi phải đọc chữ. Mục đang chọn đeo vòng tròn chuyển sắc, đúng dấu hiệu
    // dùng ở đầu mọi nút trong ứng dụng.
    final destinations = <({IconData icon, IconData selected, String label, List<Color> sac})>[
      (icon: Icons.library_books_outlined, selected: Icons.library_books_rounded,
       label: 'Thư viện', sac: SacNut.phu),
      (icon: Icons.headphones_outlined, selected: Icons.headphones_rounded,
       label: 'Nghe', sac: SacNut.chinh),
      (icon: Icons.save_alt_outlined, selected: Icons.save_alt_rounded,
       label: 'Xuất file', sac: SacNut.them),
      (icon: Icons.settings_outlined, selected: Icons.settings_rounded,
       label: 'Cài đặt', sac: SacNut.nguyHiem),
    ];

    return Scaffold(
      // Trên điện thoại, nội dung phải né thanh trạng thái và khu vực tai thỏ.
      // Cạnh dưới để thanh điều hướng tự lo, nên không cắt ở đây.
      body: SafeArea(
        bottom: false,
        child: Stack(
        children: [
          // Nội dung trải hết bề ngang rồi chừa lề cho thanh điều hướng nổi lên
          // trên. Nhờ vậy mép các thẻ trôi qua sau tấm kính lúc cuộn — không thì
          // sau kính chỉ là nền phẳng, nhìn hệt một mảng xám.
          Padding(
            padding: EdgeInsets.only(left: wide ? 92 : 0),
            child: Column(
              children: [
                const _EngineBanner(),
                _BusyBar(tabIndex: _index),
                Expanded(child: pages[_index]),
                if (state.currentBook != null && _index != 1) const MiniPlayer(),
              ],
            ),
          ),
          if (wide)
            Positioned(
              left: 8,
              top: 8,
              bottom: 8,
              width: 76,
              child: Kinh(
                bo: 26,
                child: NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: goTo,
              labelType: NavigationRailLabelType.all,
              backgroundColor: Colors.transparent,
              // Vòng tròn chuyển sắc đã là dấu hiệu "đang chọn" rồi; để thêm
              // mảng nền của Material nữa thì thành hai lớp chỉ dấu chồng nhau.
              indicatorColor: Colors.transparent,
              // Nhưng hình dạng thì vẫn phải đổi: mảng sáng lúc rê chuột hay
              // bấm giữ vẫn vẽ theo indicatorShape, mặc định là viên thuốc bầu
              // dục — lệch hẳn với vòng tròn của mục đang chọn.
              indicatorShape: const CircleBorder(),
              destinations: [
                for (final d in destinations)
                  NavigationRailDestination(
                    // Hai trạng thái phải chiếm đúng một khung: mục đang chọn
                    // đeo vòng tròn 40px, mục thường chỉ có biểu tượng 24px —
                    // để nguyên thì chọn sang mục khác là cả cột xô lên xuống.
                    icon: SizedBox.square(dimension: 40, child: Center(child: Icon(d.icon))),
                    selectedIcon: HinhTronSac(hinh: d.selected, sac: d.sac),
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    label: Text(d.label),
                  ),
              ],
                ),
              ),
            ),
        ],
        ),
      ),
      // Thanh dưới đáy cũng là kính nổi: nội dung cuộn qua phía sau nó.
      extendBody: true,
      bottomNavigationBar: wide
          ? null
          : Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Kinh(
                bo: 28,
                child: NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: goTo,
              backgroundColor: Colors.transparent,
              indicatorColor: Colors.transparent,
              indicatorShape: const CircleBorder(),
              destinations: [
                for (final d in destinations)
                  NavigationDestination(
                    // Cùng lý do như thanh dọc: hai trạng thái một khung.
                    icon: SizedBox.square(dimension: 36, child: Center(child: Icon(d.icon))),
                    selectedIcon: HinhTronSac(hinh: d.selected, sac: d.sac, canh: 36),
                    label: d.label,
                  ),
              ],
                ),
              ),
            ),
    );
  }
}

/// Dải tiến trình cho việc chạy nền: nhập sách hoặc xuất MP3.
///
/// Chỉ hiện khi người dùng đang ở tab khác — để rời màn hình vẫn biết việc còn
/// chạy, thay vì tưởng ứng dụng đã đứng.
class _BusyBar extends StatelessWidget {
  const _BusyBar({required this.tabIndex});
  final int tabIndex;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);

    final importing = state.importProgress;
    if (importing != null && tabIndex != 0) {
      return _bar(
        context,
        icon: Icons.auto_stories_outlined,
        text: 'Đang thêm sách ${state.importLabel} — ${importing.phase}',
        value: importing.value,
        trailing: importing.value == null ? null : '${importing.percent}%',
      );
    }

    final job = state.runningJob;
    if (job != null && tabIndex != 2) {
      final remaining = state.exports.remainingFor(job);
      return _bar(
        context,
        icon: Icons.save_alt_outlined,
        text: 'Đang xuất MP3 "${job.bookTitle}"'
            '${remaining == null ? '' : ' — còn khoảng ${formatTime(remaining.inSeconds.toDouble())}'}',
        value: job.progress,
        trailing: '${(job.progress * 100).round()}%',
      );
    }

    return const SizedBox.shrink();
  }

  Widget _bar(
    BuildContext context, {
    required IconData icon,
    required String text,
    required double? value,
    String? trailing,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 7, 16, 6),
            child: Row(
              children: [
                Icon(icon, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                  ),
                ),
                if (trailing != null)
                  Text(trailing, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          LinearProgressIndicator(value: value, minHeight: 3),
        ],
      ),
    );
  }
}

/// Dải thông báo khi engine giọng đọc chưa sẵn sàng.
class _EngineBanner extends StatelessWidget {
  const _EngineBanner();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final status = state.engineStatus;
    if (status.ready) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final loading = status.loading;

    return Material(
      color: loading ? scheme.surfaceContainerHighest : scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            if (loading)
              const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
            else
              Icon(Icons.warning_amber_rounded, size: 19, color: scheme.onErrorContainer),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                status.message,
                style: TextStyle(
                  fontSize: 13,
                  color: loading ? scheme.onSurfaceVariant : scheme.onErrorContainer,
                ),
              ),
            ),
            TextButton(
              onPressed: () => AppScope.read(context).refreshEngine(),
              child: const Text('Kiểm tra lại'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoBook extends StatelessWidget {
  const _NoBook({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.menu_book_outlined, size: 44, color: Theme.of(context).disabledColor),
          const SizedBox(height: 12),
          Text(message, style: TextStyle(color: Theme.of(context).hintColor)),
          const SizedBox(height: 16),
          NutSac(
            nhan: 'VỀ THƯ VIỆN',
            hinh: Icons.library_books_rounded,
            sac: SacNut.phu,
            vienRong: true,
            onNhan: () => HomeShellState.of(context)?.goTo(0),
          ),
        ],
      ),
    );
  }
}
