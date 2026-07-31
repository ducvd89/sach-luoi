/// Màn hình thư viện: thêm sách và chọn sách để nghe.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/work_progress.dart';
import 'app_scope.dart';
import 'nut_sac.dart';
import 'home_shell.dart';
import 'theme.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  bool _importing = false;
  String? _importMessage;
  bool _importFailed = false;

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['epub', 'txt'],
      dialogTitle: 'Chọn sách EPUB hoặc TXT',
    );
    if (result == null || !mounted) return;

    final state = AppScope.read(context);
    setState(() {
      _importing = true;
      _importFailed = false;
    });

    final files = result.files.where((f) => f.path != null).toList();
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      final path = file.path!;
      final counter = files.length > 1 ? ' (${i + 1}/${files.length})' : '';
      setState(() => _importMessage = 'Đang đọc "${file.name}"$counter');
      try {
        final result = await state.importFile(path, label: counter.trim());
        if (!mounted) return;
        final book = result.book;
        final cleanup = result.cleanupSummary.isEmpty ? '' : ' · ${result.cleanupSummary}';
        setState(() => _importMessage =
            'Đã thêm "${book.title}" — ${book.chapters.length} chương, '
            '~${formatTime(book.estimatedDuration.inSeconds.toDouble())}$cleanup');
      } catch (err) {
        if (!mounted) return;
        setState(() {
          _importFailed = true;
          _importMessage = 'Không đọc được "${file.name}": $err';
        });
      }
    }

    if (mounted) setState(() => _importing = false);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final books = state.books;

    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 26),
      children: [
        Row(
          children: [
            Text('Thư viện', style: Theme.of(context).textTheme.headlineSmall),
            const Spacer(),
            NutSac(
              nhan: 'THÊM SÁCH',
              hinh: Icons.add_rounded,
              dangChay: _importing,
              onNhan: _pickFiles,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Hỗ trợ file EPUB và TXT. Sách được cắt sẵn thành đoạn theo câu để đọc lên nghe tự nhiên.',
          style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13),
        ),
        if (_importing || _importMessage != null) ...[
          const SizedBox(height: 14),
          _ImportCard(
            importing: _importing,
            failed: _importFailed,
            message: _importMessage,
            progress: state.importProgress,
          ),
        ],
        const SizedBox(height: 22),
        if (books.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 60),
            child: Column(
              children: [
                Icon(Icons.auto_stories_outlined, size: 46, color: Theme.of(context).disabledColor),
                const SizedBox(height: 12),
                Text('Chưa có sách nào', style: TextStyle(color: Theme.of(context).hintColor)),
              ],
            ),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = (constraints.maxWidth / 330).floor().clamp(1, 4);
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: books.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 14,
                  mainAxisExtent: 186,
                ),
                itemBuilder: (context, i) => _BookCard(book: books[i]),
              );
            },
          ),
      ],
    );
  }
}

/// Thẻ báo trạng thái nhập sách: đang làm bước nào, xong bao nhiêu phần trăm.
///
/// Sách dày mất hàng chục giây để tách chương và chuẩn hoá, nên phải thấy con số
/// nhúc nhích thì mới yên tâm là ứng dụng còn sống chứ không phải bị treo.
class _ImportCard extends StatelessWidget {
  const _ImportCard({
    required this.importing,
    required this.failed,
    required this.message,
    required this.progress,
  });

  final bool importing;
  final bool failed;
  final String? message;
  final WorkProgress? progress;

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (importing)
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                else
                  Icon(
                    failed ? Icons.error_outline : Icons.check_circle_outline,
                    size: 18,
                    color: failed ? Theme.of(context).colorScheme.error : Colors.green,
                  ),
                const SizedBox(width: 11),
                Expanded(child: Text(message ?? 'Đang xử lý…', style: const TextStyle(fontSize: 13.5))),
                if (importing && progress?.value != null)
                  Text('${progress!.percent}%', style: TextStyle(fontSize: 13, color: hint)),
              ],
            ),
            if (importing) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(value: progress?.value, minHeight: 5),
              ),
              const SizedBox(height: 6),
              Text(progress?.phase ?? 'Đang chuẩn bị…', style: TextStyle(fontSize: 12.5, color: hint)),
            ],
          ],
        ),
      ),
    );
  }
}

class _BookCard extends StatefulWidget {
  const _BookCard({required this.book});
  final Book book;

  @override
  State<_BookCard> createState() => _BookCardState();
}

class _BookCardState extends State<_BookCard> {
  /// Mở sách phải nạp toàn bộ đoạn từ đĩa — sách dày mất một lúc, nên nút phải
  /// tự báo là đang chạy thay vì đứng im như bị kẹt.
  bool _opening = false;

  Future<void> _open(int tab) async {
    if (_opening) return;
    final state = AppScope.read(context);
    setState(() => _opening = true);
    try {
      await state.openBook(widget.book);
      if (mounted) HomeShellState.of(context)?.goTo(tab);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final book = widget.book;
    final percent = book.percentListened;
    final hint = Theme.of(context).hintColor;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              book.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, height: 1.3),
            ),
            const SizedBox(height: 5),
            Text(
              '${book.author.isEmpty ? '' : '${book.author} · '}'
              '${book.chapters.length} chương · ~${formatTime(book.estimatedDuration.inSeconds.toDouble())} · '
              '${book.format.toUpperCase()}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: hint),
            ),
            const Spacer(),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(value: percent, minHeight: 5),
            ),
            const SizedBox(height: 5),
            Text(
              percent > 0 ? 'Đã nghe ${(percent * 100).round()}%' : 'Chưa nghe',
              style: TextStyle(fontSize: 12, color: hint),
            ),
            const SizedBox(height: 9),
            Row(
              children: [
                NutSac(
                  nho: true,
                  nhan: percent > 0 && percent < 1 ? 'Nghe tiếp' : 'Nghe',
                  hinh: Icons.play_arrow_rounded,
                  dangChay: _opening,
                  onNhan: () => _open(1),
                ),
                const SizedBox(width: 8),
                NutSac(
                  nho: true,
                  vienRong: true,
                  sac: SacNut.phu,
                  nhan: 'Xuất file',
                  hinh: Icons.arrow_downward_rounded,
                  onNhan: _opening ? null : () => _open(2),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Dọn lại sách theo cài đặt hiện tại\n'
                      '(bỏ quảng cáo, mục lục, chuẩn hoá số)',
                  icon: const Icon(Icons.cleaning_services_outlined, size: 19),
                  onPressed: _opening ? null : _rebuild,
                ),
                IconButton(
                  tooltip: 'Xoá khỏi thư viện',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: _opening ? null : () => _confirmDelete(context),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Dựng lại sách từ file gốc theo cài đặt hiện tại.
  ///
  /// Sách nhập từ trước khi bật dọn quảng cáo vẫn còn nguyên rác; dựng lại thì
  /// sạch mà không mất chỗ đang nghe.
  Future<void> _rebuild() async {
    final state = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _opening = true);
    try {
      final result = await state.rebuildBook(widget.book);
      messenger.showSnackBar(SnackBar(
        content: Text(result.cleanupSummary.isEmpty
            ? 'Đã dọn lại "${result.book.title}" — không tìm thấy phần thừa nào'
            : 'Đã dọn lại "${result.book.title}" — ${result.cleanupSummary}'),
      ));
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text('Không dọn lại được: $err')));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final state = AppScope.read(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xoá sách?'),
        content: Text('"${widget.book.title}" sẽ bị xoá khỏi thư viện cùng với tiến trình nghe. '
            'Các file MP3 đã xuất ra vẫn được giữ nguyên.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Xoá')),
        ],
      ),
    );
    if (ok == true) await state.deleteBook(widget.book);
  }
}
