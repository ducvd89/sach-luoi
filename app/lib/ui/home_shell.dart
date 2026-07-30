/// Khung chính: thanh điều hướng bên trái và thanh phát cố định dưới cùng.
library;

import 'package:flutter/material.dart';

import 'app_scope.dart';
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
    final wide = MediaQuery.sizeOf(context).width >= 900;

    final pages = [
      const LibraryPage(),
      hasBook ? const PlayerPage() : const _NoBook(message: 'Chọn một cuốn sách trong thư viện để bắt đầu nghe'),
      hasBook ? const ExportPage() : const _NoBook(message: 'Chọn một cuốn sách trước khi xuất file MP3'),
      const SettingsPage(),
    ];

    final destinations = <({IconData icon, IconData selected, String label})>[
      (icon: Icons.library_books_outlined, selected: Icons.library_books, label: 'Thư viện'),
      (icon: Icons.headphones_outlined, selected: Icons.headphones, label: 'Nghe'),
      (icon: Icons.save_alt_outlined, selected: Icons.save_alt, label: 'Xuất file'),
      (icon: Icons.settings_outlined, selected: Icons.settings, label: 'Cài đặt'),
    ];

    return Scaffold(
      // Trên điện thoại, nội dung phải né thanh trạng thái và khu vực tai thỏ.
      // Cạnh dưới để thanh điều hướng tự lo, nên không cắt ở đây.
      body: SafeArea(
        bottom: false,
        child: Row(
        children: [
          if (wide)
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: goTo,
              labelType: NavigationRailLabelType.all,
              leading: const Padding(
                padding: EdgeInsets.only(top: 14, bottom: 6),
                child: Text('📖', style: TextStyle(fontSize: 26)),
              ),
              destinations: [
                for (final d in destinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selected),
                    label: Text(d.label),
                  ),
              ],
            ),
          if (wide) const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                const _EngineBanner(),
                _BusyBar(tabIndex: _index),
                Expanded(child: pages[_index]),
                if (state.currentBook != null && _index != 1) const MiniPlayer(),
              ],
            ),
          ),
        ],
        ),
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: goTo,
              destinations: [
                for (final d in destinations)
                  NavigationDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selected), label: d.label),
              ],
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
          FilledButton.tonal(
            onPressed: () => HomeShellState.of(context)?.goTo(0),
            child: const Text('Về thư viện'),
          ),
        ],
      ),
    );
  }
}
