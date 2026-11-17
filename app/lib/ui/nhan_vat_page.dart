/// Trang Nhân vật: danh sách người nói trong sách đang mở và giọng đọc của từng người.
///
/// Laya phân tích TỪNG CHƯƠNG (chương đang nghe): hỏi Laya từng câu thoại mất ~0,1 giây, cả cuốn dày
/// là hàng chục phút. Danh sách nhân vật là danh bạ của cả sách, bồi dần qua các chương; người đã gặp
/// giữ giọng đã chọn khi xuất hiện lại ở chương khác. Hai điều trang này PHẢI làm rõ với người
/// dùng, vì đều đã đo:
///  - Laya đoán giới tính nhân vật nữ kém (khoảng một nửa bị đoán nam), nên giới tính sửa tay được
///    và giọng gợi ý theo giới tính chỉ là gợi ý.
///  - Bật/tắt đọc nhiều giọng KHÔNG cắt lại sách: mỗi lời nói đã là một đoạn riêng từ lúc nhập. Tắt
///    thì mọi đoạn đọc bằng giọng người dẫn.
library;

import 'package:flutter/material.dart';

import '../core/nhan_vat.dart';
import '../models/book.dart';
import '../services/tts/tts_engine.dart';
import '../state/app_state.dart';
import 'app_scope.dart';

class NhanVatPage extends StatelessWidget {
  const NhanVatPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final book = state.currentBook;
    return Scaffold(
      appBar: AppBar(title: Text(book == null ? 'Nhân vật' : 'Nhân vật — ${book.title}')),
      body: book == null
          ? const Center(child: Text('Chưa mở sách nào'))
          : _NoiDung(state: state, book: book),
    );
  }
}

class _NoiDung extends StatelessWidget {
  const _NoiDung({required this.state, required this.book});

  final AppState state;
  final Book book;

  @override
  Widget build(BuildContext context) {
    final nv = state.nhanVat;
    final dangPhanTich = state.nhanVatTienDo != null;
    final dangCat = state.importProgress != null;
    final hint = Theme.of(context).hintColor;
    final chuong = state.chuongHienTai;
    final tenChuong = book.chapters.where((c) => c.index == chuong).map((c) => c.title).firstOrNull ??
        'Chương ${chuong + 1}';
    final daXong = nv?.daPhanTich(chuong) ?? false;
    final trongChuong = nv?.trongChuong(chuong) ?? const <String>{};

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Text(
          'Mỗi nhân vật đọc bằng một giọng riêng. Laya phân tích từng chương (chương đang nghe) để tìm '
          'nhân vật và đoán ai nói câu nào; nhân vật đã gặp giữ nguyên giọng ở các chương sau.',
          style: TextStyle(fontSize: 13.5, color: hint),
        ),
        const SizedBox(height: 12),
        _ChuongHienTai(
          ten: tenChuong,
          daXong: daXong,
          soChuongXong: nv?.chuongDaPhanTich.length ?? 0,
          tongChuong: book.chapters.length,
        ),
        const SizedBox(height: 12),
        if (!state.coLaya) _ThieuLaya(thuMuc: state.tts.modelStore.layaDir.path),
        if (dangPhanTich) ...[
          LinearProgressIndicator(value: state.nhanVatTienDo!.value),
          const SizedBox(height: 6),
          Text(state.nhanVatTienDo!.phase, style: TextStyle(fontSize: 12.5, color: hint)),
          const SizedBox(height: 12),
        ] else
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: !state.coLaya || dangCat ? null : () => _phanTich(context),
              icon: const Icon(Icons.groups_2_outlined),
              label: Text(daXong ? 'Phân tích lại chương này' : 'Phân tích chương này'),
            ),
          ),
        if (nv != null && nv.nhanVat.isEmpty && !dangPhanTich) ...[
          const SizedBox(height: 16),
          Text(
            'Chưa tìm thấy nhân vật nào (ít lời thoại, hoặc lời dẫn không theo kiểu "Tên nói:"). '
            'Sách vẫn đọc bằng một giọng như thường.',
            style: TextStyle(fontSize: 13.5, color: hint),
          ),
        ],
        if (nv != null && nv.nhanVat.isNotEmpty) ...[
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: nv.bat,
            onChanged: dangCat || dangPhanTich ? null : (v) => _batNhieuGiong(context, v),
            title: const Text('Đọc nhiều giọng'),
            subtitle: Text(
              nv.bat
                  ? 'Đang đọc theo nhân vật (không nối ngữ cảnh). Lời dẫn và nhân vật chưa chọn giọng đọc bằng giọng người dẫn.'
                  : 'Đang đọc mọi đoạn bằng giọng người dẫn. Bật để đọc mỗi nhân vật một giọng.',
              style: TextStyle(fontSize: 12.5, color: hint),
            ),
          ),
          if (dangCat) ...[
            LinearProgressIndicator(value: state.importProgress!.value),
            const SizedBox(height: 4),
            Text(state.importProgress!.phase, style: TextStyle(fontSize: 12.5, color: hint)),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text('${nv.nhanVat.length} nhân vật · ${nv.nguoiNoi.length} câu thoại đã gán '
                    'ở ${nv.chuongDaPhanTich.length} chương',
                    style: TextStyle(fontSize: 12.5, color: hint)),
              ),
              TextButton(
                onPressed: () => _tuChonGiong(state, nv),
                child: const Text('Tự chọn giọng'),
              ),
            ],
          ),
          const _CanhBaoGioiTinh(),
          const Divider(height: 20),
          _HangNguoiDan(state: state, khoa: dangPhanTich),
          for (final n in nv.nhanVat)
            _HangNhanVat(
              key: ValueKey(n.ten),
              nhanVat: n,
              state: state,
              trongChuong: trongChuong.contains(n.ten),
              khoa: dangPhanTich,
            ),
        ],
      ],
    );
  }

  Future<void> _batNhieuGiong(BuildContext context, bool bat) async {
    final tin = ScaffoldMessenger.of(context);
    try {
      await state.batNhieuGiong(book, bat);
    } catch (e) {
      tin.showSnackBar(SnackBar(content: Text('Không đổi được: $e')));
    }
  }

  Future<void> _phanTich(BuildContext context) async {
    final tin = ScaffoldMessenger.of(context);
    try {
      await state.phanTichNhanVat(book);
    } catch (e) {
      tin.showSnackBar(SnackBar(content: Text('Không phân tích được: $e')));
    }
  }

  /// Chọn lại giọng cho nhân vật chưa có giọng (phân tích xong đã tự chọn; nút này để chọn bù khi
  /// người dùng vừa bỏ giọng hoặc thêm giọng mới).
  void _tuChonGiong(AppState state, NhanVatSach nv) {
    state.tuChonGiongChoNguoiMoi(nv);
    state.datGiongNhieuNhanVat({for (final n in nv.nhanVat) n.ten: n.giong});
  }
}

class _ChuongHienTai extends StatelessWidget {
  const _ChuongHienTai({
    required this.ten,
    required this.daXong,
    required this.soChuongXong,
    required this.tongChuong,
  });

  final String ten;
  final bool daXong;
  final int soChuongXong;
  final int tongChuong;

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Đang nghe: $ten', style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            daXong
                ? 'Chương này đã được phân tích.'
                : 'Chương này chưa phân tích — đọc bằng giọng người dẫn cho tới khi bạn phân tích nó.',
            style: TextStyle(fontSize: 12.5, color: hint),
          ),
          if (soChuongXong > 0)
            Text('Đã phân tích $soChuongXong/$tongChuong chương.', style: TextStyle(fontSize: 12.5, color: hint)),
        ],
      ),
    );
  }
}

class _ThieuLaya extends StatelessWidget {
  const _ThieuLaya({required this.thuMuc});

  final String thuMuc;

  @override
  Widget build(BuildContext context) {
    final mau = Theme.of(context).colorScheme.errorContainer;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: mau, borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Chưa có mô hình Laya (645 MB)', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text(
            'Đặt ba file laya.onnx, tokenizer.json và rl_agent_config.json vào thư mục dưới đây rồi mở lại '
            'trang này. Chưa có gói tải về trong ứng dụng.',
            style: TextStyle(fontSize: 12.5),
          ),
          const SizedBox(height: 6),
          SelectableText(thuMuc, style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace')),
        ],
      ),
    );
  }
}

class _CanhBaoGioiTinh extends StatelessWidget {
  const _CanhBaoGioiTinh();

  @override
  Widget build(BuildContext context) {
    return Text(
      'Giới tính do Laya đoán và thường sai ở nhân vật nữ (đo được khoảng một nửa). Bấm vào biểu '
      'tượng để sửa trước khi chọn giọng.',
      style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor),
    );
  }
}

/// Giọng người dẫn truyện: đọc lời dẫn và mọi câu thoại chưa rõ người nói. Chính là giọng nghe
/// mặc định của sách, nên đổi ở đây cũng đổi ở màn hình nghe.
class _HangNguoiDan extends StatelessWidget {
  const _HangNguoiDan({required this.state, this.khoa = false});

  final AppState state;
  final bool khoa;

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final dangChon = state.voices.any((v) => v.id == state.settings.voiceNghe) ? state.settings.voiceNghe : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
            child: const Icon(Icons.menu_book_outlined, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Người dẫn truyện', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                Text('Lời dẫn và câu thoại chưa rõ người nói', style: TextStyle(fontSize: 12.5, color: hint)),
              ],
            ),
          ),
          DropdownButton<String>(
            value: dangChon,
            underline: const SizedBox.shrink(),
            onChanged: khoa ? null : (v) {
              if (v != null) state.setVoiceNghe(v);
            },
            items: [
              for (final v in state.voices)
                DropdownMenuItem(value: v.id, child: Text(v.gender.isEmpty ? v.name : '${v.name} (${v.gender})')),
            ],
          ),
        ],
      ),
    );
  }
}

class _HangNhanVat extends StatelessWidget {
  const _HangNhanVat({
    super.key,
    required this.nhanVat,
    required this.state,
    required this.trongChuong,
    this.khoa = false,
  });

  final NhanVat nhanVat;
  final AppState state;

  /// Đang phân tích: khoá chọn giọng và giới tính để phân tích xong không đè mất lựa chọn.
  final bool khoa;

  /// Có câu thoại trong chương đang nghe — hiện dấu để biết ai đang nói ở đây.
  final bool trongChuong;

  @override
  Widget build(BuildContext context) {
    final nu = nhanVat.gioi == 'nu';
    final hint = Theme.of(context).hintColor;
    final dangChon = state.voices.any((v) => v.id == nhanVat.giong) ? nhanVat.giong : '';
    bool hopGioi(TtsVoice v) => giongHopGioi(v, nu ? 'nu' : 'nam');
    // Giọng cùng giới tính lên đầu cho dễ chọn; giọng khác giới vẫn chọn được.
    final giong = [...state.voices]..sort((a, b) => (hopGioi(b) ? 1 : 0).compareTo(hopGioi(a) ? 1 : 0));

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Tooltip(
            message: nu ? 'Nữ — bấm để đổi sang nam' : 'Nam — bấm để đổi sang nữ',
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: khoa ? null : () => state.datGioiNhanVat(nhanVat.ten, nu ? 'nam' : 'nu'),
              child: CircleAvatar(
                radius: 18,
                backgroundColor: nu ? Colors.pink.shade100 : Colors.blue.shade100,
                child: Text(nu ? '♀' : '♂', style: const TextStyle(fontSize: 18, color: Colors.black87)),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(nhanVat.ten, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                Text('${nhanVat.soCau} câu thoại${trongChuong ? ' · có trong chương này' : ''}',
                    style: TextStyle(fontSize: 12.5, color: hint)),
              ],
            ),
          ),
          DropdownButton<String>(
            value: dangChon,
            underline: const SizedBox.shrink(),
            onChanged: khoa ? null : (v) => state.datGiongNhanVat(nhanVat.ten, v ?? ''),
            items: [
              const DropdownMenuItem(value: '', child: Text('Giọng mặc định')),
              for (final v in giong)
                DropdownMenuItem(
                  value: v.id,
                  child: Text('${v.name}${hopGioi(v) ? '' : ' (khác giới)'}'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
