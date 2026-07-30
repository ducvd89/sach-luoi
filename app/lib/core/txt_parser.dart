/// Đọc sách dạng .txt: đoán bảng mã, chuẩn hoá xuống dòng và tự tách chương
/// dựa trên các tiêu đề thường gặp trong sách tiếng Việt.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../models/book.dart';

/// Nhận diện bảng mã qua BOM; mặc định UTF-8, tự lùi về Latin-1 nếu UTF-8 hỏng.
String decodeTextFile(Uint8List bytes) {
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: false);
  }

  final text = utf8.decode(bytes, allowMalformed: true);
  // U+FFFD xuất hiện nhiều nghĩa là dữ liệu không phải UTF-8.
  final bad = '�'.allMatches(text).length;
  if (text.isNotEmpty && bad / text.length > 0.002) return latin1.decode(bytes, allowInvalid: true);
  return text;
}

String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(littleEndian ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1]);
  }
  return String.fromCharCodes(units);
}

final _chapterPatterns = [
  RegExp(
    r'^\s*(?:chương|chuong|chapter|phần|phan|hồi|quyển|tập|part|book)\s+([0-9]{1,4}|[ivxlcdm]{1,8})\b[.:\-–—]?\s*(.*)$',
    caseSensitive: false,
  ),
  RegExp(r'^\s*#{1,3}\s+(.+)$'),
  RegExp(r'^\s*(?:chương|chapter)\s*[.:]\s*(.+)$', caseSensitive: false),
];

bool _isChapterHeading(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty || trimmed.length > 120) return false;
  return _chapterPatterns.any((re) => re.hasMatch(trimmed));
}

class _Section {
  _Section(this.title);
  String title;
  final List<String> lines = [];
}

/// Đọc file văn bản thành danh sách chương.
ParsedBook parseTxt(String raw, String fallbackTitle) {
  final text = raw
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(' ', ' ')
      .replaceAll(RegExp(r'[­​-‏﻿]'), '');
  final lines = text.split('\n');

  final sections = <_Section>[];
  _Section? current;

  for (final line in lines) {
    if (_isChapterHeading(line)) {
      if (current != null && current.lines.join().trim().isEmpty && current.title.isNotEmpty) {
        // Hai tiêu đề liền nhau (ví dụ "Phần 1" rồi "Chương 1") — gộp lại.
        current.title = '${current.title} — ${line.trim()}';
        continue;
      }
      current = _Section(line.trim().replaceFirst(RegExp(r'^#{1,3}\s*'), ''));
      sections.add(current);
      continue;
    }
    current ??= (() {
      final s = _Section('');
      sections.add(s);
      return s;
    })();
    current.lines.add(line);
  }

  var chapters = sections
      .map((s) => RawChapter(
            s.title,
            s.lines.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim(),
          ))
      .where((c) => c.text.isNotEmpty || c.title.isNotEmpty)
      .toList();

  // Không tìm thấy tiêu đề chương nào: cắt theo khối ~12.000 ký tự cho dễ điều hướng.
  if (chapters.length <= 1 && text.length > 20000) {
    chapters = _splitBySize(text, 12000);
  }

  if (chapters.isEmpty) chapters = [RawChapter(fallbackTitle, text.trim())];

  return ParsedBook(
    title: _guessTitle(lines) ?? fallbackTitle,
    author: '',
    language: 'vi',
    chapters: [
      for (var i = 0; i < chapters.length; i++)
        RawChapter(chapters[i].title.isEmpty ? 'Phần ${i + 1}' : chapters[i].title, chapters[i].text),
    ],
  );
}

List<RawChapter> _splitBySize(String text, int size) {
  final out = <RawChapter>[];
  final buffer = <String>[];
  var length = 0;

  for (final paragraph in text.split(RegExp(r'\n{2,}'))) {
    buffer.add(paragraph);
    length += paragraph.length + 2;
    if (length >= size) {
      out.add(RawChapter('Phần ${out.length + 1}', buffer.join('\n\n').trim()));
      buffer.clear();
      length = 0;
    }
  }
  if (buffer.isNotEmpty) out.add(RawChapter('Phần ${out.length + 1}', buffer.join('\n\n').trim()));
  return out;
}

String? _guessTitle(List<String> lines) {
  for (final line in lines.take(10)) {
    final t = line.trim();
    if (t.length >= 3 && t.length <= 100 && !_isChapterHeading(t)) return t;
  }
  return null;
}
