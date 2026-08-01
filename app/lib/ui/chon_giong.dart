/// Chọn giọng đọc và cách nối ngữ cảnh — dùng chung cho trang Nghe và trang
/// Xuất file.
///
/// Hai trang giữ thiết lập RIÊNG: nghe thử bằng giọng này rồi xuất bằng giọng
/// khác là chuyện thường, và mỗi bên khoá lúc đang chạy mà không cản bên kia.
///
/// Khoá khi đang chạy vì cả hai thứ này quyết định âm thanh sinh ra. Đổi giữa
/// chừng thì nửa cuốn một kiểu, mà đoạn đang phát cũng đang dựa vào giá trị cũ.
/// Tạm dừng, đổi, rồi chạy tiếp — phần còn lại theo giá trị mới.
///
/// Gói gọn trong một hàng: đây là thanh công cụ nằm giữa màn hình làm việc chứ
/// không phải trang cài đặt, chiếm chỗ nhiều là lấn mất phần đang đọc. Phần giải
/// thích dài đưa vào tooltip.
library;

import 'package:flutter/material.dart';

import '../models/settings.dart';
import 'kinh.dart';
import '../services/tts/tts_engine.dart';

class BangChonGiong extends StatelessWidget {
  const BangChonGiong({
    super.key,
    required this.voices,
    required this.voiceId,
    required this.onVoice,
    required this.nguCanh,
    required this.onNguCanh,
    this.khoa,
  });

  final List<TtsVoice> voices;
  final String voiceId;
  final ValueChanged<String> onVoice;
  final NguCanh nguCanh;
  final ValueChanged<NguCanh> onNguCanh;

  /// Lý do đang không đổi được, null nghĩa là đổi được.
  final String? khoa;

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final dangChon = voices.any((v) => v.id == voiceId) ? voiceId : (voices.firstOrNull?.id ?? '');
    final tat = khoa != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.record_voice_over_outlined, size: 17, color: hint),
            const SizedBox(width: 7),
            Expanded(
              flex: 3,
              child: _O(
                child: DropdownButton<String>(
                  value: dangChon.isEmpty ? null : dangChon,
                  isExpanded: true,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  borderRadius: BorderRadius.circular(12),
                  // Menu bung ra không bọc kính được (Flutter dựng nó ở lớp
                  // khác, ngoài tầm BackdropFilter), nên chỉ làm nền trong mờ
                  // cho gần với ô chọn.
                  dropdownColor: Theme.of(context).colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.94),
                  hint: Text('Chưa có giọng', style: TextStyle(fontSize: 13.5, color: hint)),
                  items: [
                    for (final v in voices)
                      DropdownMenuItem(
                        value: v.id,
                        child: Text(
                          v.gender.isEmpty ? v.name : '${v.name} · ${v.gender}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13.5),
                        ),
                      ),
                  ],
                  onChanged: tat
                      ? null
                      : (v) {
                          if (v != null && v != dangChon) onVoice(v);
                        },
                ),
              ),
            ),
            const SizedBox(width: 12),
            Tooltip(
              message: 'Nối ngữ cảnh giữa các đoạn\n${nguCanh.description}',
              child: Icon(Icons.link_rounded, size: 17, color: hint),
            ),
            const SizedBox(width: 7),
            Expanded(
              flex: 2,
              child: _O(
                child: DropdownButton<NguCanh>(
                  value: nguCanh,
                  isExpanded: true,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  borderRadius: BorderRadius.circular(12),
                  dropdownColor: Theme.of(context).colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.94),
                  items: [
                    for (final v in NguCanh.values)
                      DropdownMenuItem(
                        value: v,
                        child: Text(v.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13.5)),
                      ),
                  ],
                  onChanged: tat
                      ? null
                      : (v) {
                          if (v != null && v != nguCanh) onNguCanh(v);
                        },
                ),
              ),
            ),
          ],
        ),
        if (tat)
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 24),
            child: Text(
              khoa!,
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }
}

/// Ô chọn bằng kính, để nó tách khỏi nội dung mà không cần viền đậm.
class _O extends StatelessWidget {
  const _O({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Kinh(
        bo: 12,
        mo: 14,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: child,
      );
}
