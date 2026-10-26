import 'package:flutter/material.dart';

import '../localization/app_strings.dart';
import '../services/share_picker.dart';

/// T135: 보낼 기록 파일·프레임 묶음을 고르는 화면. 기본 체크는 아직 보낸 적
/// 없는 줄([defaultSelection]). "보내기"를 누르면 고른 줄의 [ShareItem.path]
/// 집합을 돌려주고, 뒤로 가면 null을 돌려준다.
class SharePickerScreen extends StatefulWidget {
  const SharePickerScreen({
    super.key,
    required this.strings,
    required this.title,
    required this.items,
    this.frames = false,
  });

  final AppStrings strings;
  final String title;
  final List<ShareItem> items;

  /// 프레임 묶음이면 줄마다 장수를 보이고, 빌드 대신 장수를 적는다.
  final bool frames;

  @override
  State<SharePickerScreen> createState() => _SharePickerScreenState();
}

class _SharePickerScreenState extends State<SharePickerScreen> {
  // settings_screen.dart와 같은 강조색·그 위 글자색.
  static const _colorAccent = Color(0xFF3AA0FF);
  static const _colorAccentOnText = Color(0xFF08182A);

  late final Set<String> _selected = defaultSelection(widget.items);

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _stamp(DateTime? t) => t == null
      ? '—'
      : '${t.year}-${_two(t.month)}-${_two(t.day)} '
          '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

  static String _size(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)}KB';
    return '${bytes}B';
  }

  String _subtitle(ShareItem item) {
    final s = widget.strings;
    final parts = <String>[
      if (widget.frames)
        '${item.files.length}${s.sharePickFrameUnit}'
      else
        '${s.sharePickBuild} ${_short(item.build) ?? '—'}',
      _size(item.bytes),
      if (item.sent) s.sharePickSent,
      if (item.current) s.sharePickCurrent,
    ];
    return parts.join(' · ');
  }

  static String? _short(String? sha) =>
      sha == null ? null : (sha.length > 7 ? sha.substring(0, 7) : sha);

  @override
  Widget build(BuildContext context) {
    final count = _selected.length;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title),
      ),
      body: ListView(
        children: [
          for (final item in widget.items)
            CheckboxListTile(
              value: _selected.contains(item.path),
              onChanged: (v) => setState(() {
                if (v == true) {
                  _selected.add(item.path);
                } else {
                  _selected.remove(item.path);
                }
              }),
              activeColor: _colorAccent,
              checkColor: _colorAccentOnText,
              title: Text(_stamp(item.start),
                  style: const TextStyle(color: Colors.white)),
              subtitle: Text(_subtitle(item),
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: count == 0
                ? null
                : () => Navigator.of(context).pop(Set<String>.of(_selected)),
            icon: const Icon(Icons.share_outlined, size: 18),
            label: Text('${widget.strings.sharePickSend} ($count)'),
            style: FilledButton.styleFrom(
              backgroundColor: _colorAccent,
              foregroundColor: _colorAccentOnText,
              minimumSize: const Size(48, 48),
            ),
          ),
        ),
      ),
    );
  }
}
