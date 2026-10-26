import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// T135: 설정의 "기록 보내기"·"프레임 보내기"에서 고르는 한 줄.
/// 기록은 파일 하나, 프레임은 묶음(세션 폴더) 하나가 한 줄이다.
class ShareItem {
  ShareItem({
    required this.path,
    required this.files,
    required this.bytes,
    this.start,
    this.build,
    this.sent = false,
    this.current = false,
  });

  /// 보냄 기억의 열쇠 — 기록은 파일 경로, 프레임은 묶음 폴더 경로.
  final String path;
  final List<File> files;
  final int bytes;

  /// 파일·폴더 이름에서 읽은 시작 시각(폰 시계). 이름 형식이 다르면 null.
  final DateTime? start;

  /// 기록 안 `log.start`의 `build`(빌드 SHA). 모르면 null.
  final String? build;

  /// 전에 공유 창 결과가 success였는가.
  final bool sent;

  /// 지금 쓰고 있는 기록 파일인가(보낸 뒤에도 늘어날 수 있다).
  final bool current;

  String get name => path.split(Platform.pathSeparator).last;
}

/// T135: 보냄 기억. 기준 폴더(앱 전용 폴더) 아래 [fileName]에 상대 경로 목록을
/// JSON으로 둔다. 기록·프레임 폴더 밖이라 회전·정리 대상이 아니다.
/// 실패해도 예외를 밖으로 내지 않는다 — 그때는 모두 '안 보냄'으로 보인다.
class SentRegistry {
  SentRegistry({Future<Directory> Function()? baseDir})
      : _baseDir = baseDir ?? getApplicationSupportDirectory;

  static const fileName = 'share_sent.json';

  final Future<Directory> Function() _baseDir;

  Future<File> _file() async {
    final base = await _baseDir();
    return File('${base.path}${Platform.pathSeparator}$fileName');
  }

  /// 기준 폴더 기준 상대 경로(기준 폴더 밖이면 그대로).
  Future<String> relative(String path) async {
    final base = (await _baseDir()).path;
    final prefix = '$base${Platform.pathSeparator}';
    return path.startsWith(prefix) ? path.substring(prefix.length) : path;
  }

  /// 보낸 적 있는 경로(기준 폴더 기준 상대 경로).
  Future<Set<String>> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return <String>{};
      final v = jsonDecode(await f.readAsString());
      if (v is! List) return <String>{};
      return {
        for (final e in v)
          if (e is String) e
      };
    } catch (e) {
      debugPrint('[T135] 보냄 기억 읽기 실패: $e');
      return <String>{};
    }
  }

  /// [paths]를 보냄으로 적는다. 이미 지워진 경로는 이때 함께 뺀다.
  Future<void> markSent(Iterable<String> paths) async {
    try {
      final base = (await _baseDir()).path;
      final all = await load();
      for (final p in paths) {
        all.add(await relative(p));
      }
      final kept = <String>[];
      for (final rel in all) {
        final abs = '$base${Platform.pathSeparator}$rel';
        if (await File(abs).exists() || await Directory(abs).exists()) {
          kept.add(rel);
        }
      }
      kept.sort();
      final f = await _file();
      await f.writeAsString(jsonEncode(kept), flush: true);
    } catch (e) {
      debugPrint('[T135] 보냄 기억 쓰기 실패: $e');
    }
  }
}

/// 기본 체크: 아직 보낸 적 없는 줄.
Set<String> defaultSelection(List<ShareItem> items) => {
      for (final i in items)
        if (!i.sent) i.path
    };

/// 고른 줄의 파일만(목록 순서대로).
List<File> filesFor(List<ShareItem> items, Set<String> selected) => [
      for (final i in items)
        if (selected.contains(i.path)) ...i.files,
    ];

/// `log_20261002_071530.jsonl`·`20261021_171500` → 시각. 형식이 다르면 null.
@visibleForTesting
DateTime? parseStamp(String name) {
  final m =
      RegExp(r'(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})').firstMatch(name);
  if (m == null) return null;
  final v = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  return DateTime(v[0], v[1], v[2], v[3], v[4], v[5]);
}

/// 기록 파일 앞부분에서 `log.start`의 `build`를 찾는다. 시작 전 기록이
/// [EventLog.maxEarlyLines]줄까지 앞에 올 수 있어 그만큼만 읽는다.
@visibleForTesting
Future<String?> readBuild(File file, {int maxLines = 600}) async {
  try {
    var n = 0;
    final lines =
        file.openRead().transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (++n > maxLines) break;
      if (!line.contains('"log.start"')) continue;
      final m = jsonDecode(line);
      if (m is Map && m['ev'] == 'log.start') {
        final b = m['build'];
        return b is String ? b : null;
      }
    }
  } catch (_) {
    // 읽지 못하면 빌드를 모르는 것으로 둔다
  }
  return null;
}

/// 기록 파일들 → 줄(새 것부터).
Future<List<ShareItem>> logItems(List<File> files, Set<String> sent,
    {required Future<String> Function(String path) relative,
    File? current}) async {
  final out = <ShareItem>[];
  for (final f in files) {
    final name = f.path.split(Platform.pathSeparator).last;
    int bytes;
    try {
      bytes = await f.length();
    } catch (_) {
      continue; // 그사이 회전으로 지워졌다
    }
    out.add(ShareItem(
      path: f.path,
      files: [f],
      bytes: bytes,
      start: parseStamp(name),
      build: await readBuild(f),
      sent: sent.contains(await relative(f.path)),
      current: current != null && current.path == f.path,
    ));
  }
  out.sort((a, b) => b.path.compareTo(a.path));
  return out;
}

/// 프레임 묶음(폴더 경로 → 파일) → 줄(새 것부터). 빈 묶음은 뺀다.
Future<List<ShareItem>> frameItems(
    Map<String, List<File>> sessions, Set<String> sent,
    {required Future<String> Function(String path) relative}) async {
  final out = <ShareItem>[];
  for (final e in sessions.entries) {
    if (e.value.isEmpty) continue;
    var bytes = 0;
    for (final f in e.value) {
      try {
        bytes += await f.length();
      } catch (_) {}
    }
    out.add(ShareItem(
      path: e.key,
      files: e.value,
      bytes: bytes,
      start: parseStamp(e.key.split(Platform.pathSeparator).last),
      sent: sent.contains(await relative(e.key)),
    ));
  }
  out.sort((a, b) => b.path.compareTo(a.path));
  return out;
}

/// 고르기 → 공유 → (success일 때만) 보냄 기억. 돌려주는 값은 설정 화면이
/// 띄울 문구(없으면 null). 고르기를 취소하면 아무것도 보내지 않는다.
///
/// [beforeShare]는 공유 직전에 한 번 부른다(지금 쓰는 기록 flush).
/// [share]는 넘긴 파일 수와 결과를 기록에 남기는 일까지 맡는다.
Future<String?> pickAndShare({
  required Future<List<ShareItem>> Function() load,
  required Future<Set<String>?> Function(List<ShareItem> items) pick,
  required Future<ShareResultStatus> Function(List<File> files) share,
  required SentRegistry registry,
  required String emptyMessage,
  required String failedMessage,
  Future<void> Function()? beforeShare,
}) async {
  final items = await load();
  if (items.isEmpty) return emptyMessage;
  final selected = await pick(items);
  if (selected == null) return null;
  final files = filesFor(items, selected);
  if (files.isEmpty) return null;
  if (beforeShare != null) await beforeShare();
  final ShareResultStatus status;
  try {
    status = await share(files);
  } catch (_) {
    return failedMessage;
  }
  if (status == ShareResultStatus.success) {
    await registry.markSent([
      for (final i in items)
        if (selected.contains(i.path)) i.path,
    ]);
  }
  return null;
}
