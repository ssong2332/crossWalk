import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// T106: 개발용 사건 기록. 항목·형식은 `docs/EventLog.md`(사용자 확정 2026-10-02, Q1~Q5).
///
/// 진동·음성·판정 결과를 폰 안에 JSON Lines 파일로 남긴다. 한 줄이 사건 하나다.
/// 카메라 영상·사진과 위치는 남기지 않는다(Q1, Q4). 기본값은 켬이다(Q3).
/// 앱을 켤 때마다 파일 하나(`log_YYYYMMDD_HHMMSS.jsonl`)를 만들고, 합계가
/// [maxTotalBytes]를 넘으면 오래된 파일부터 지운다. 설정의 "기록 보내기"가
/// 이 파일들을 안드로이드 공유 창으로 넘긴다(Q2).
///
/// [log]는 동기이고 예외를 밖으로 내지 않는다 — 프레임 콜백·진동 경로를 막거나
/// 깨뜨리면 안 된다. 파일 쓰기는 [flushInterval]마다 모아서 한 번 한다.
class EventLog {
  EventLog({
    Future<Directory> Function()? baseDir,
    this.maxTotalBytes = defaultMaxTotalBytes,
    this.flushInterval = const Duration(seconds: 2),
  }) : _baseDir = baseDir ?? getApplicationSupportDirectory;

  /// 앱 전체가 쓰는 기록기. `main()`이 [start]한다. 시작 전에 들어온 기록은
  /// [maxEarlyLines]줄까지 모아 두었다가 파일이 열리면 함께 쓴다.
  static final EventLog instance = EventLog();

  static const defaultMaxTotalBytes = 50 * 1024 * 1024;
  static const maxEarlyLines = 500;

  /// 버퍼가 이만큼 쌓이면 주기를 기다리지 않고 쓴다.
  static const _flushAtChars = 64 * 1024;

  final Future<Directory> Function() _baseDir;
  final int maxTotalBytes;
  final Duration flushInterval;

  /// 프로세스 안 경과 시간(ms). 폰 시계(`t`)가 바뀌어도 순서를 지킨다.
  final Stopwatch _clock = Stopwatch()..start();

  bool _enabled = true;
  bool get enabled => _enabled;

  Directory? _dir;
  File? _file;
  File? get currentFile => _file;

  final List<String> _early = <String>[];
  final StringBuffer _buf = StringBuffer();
  bool _writing = false;
  bool _starting = false;
  Timer? _timer;

  /// 쓰기 실패 횟수(기록 자체의 건강 상태). 실패한 묶음은 버린다.
  int writeErrors = 0;

  /// 사건 하나를 남긴다. [data] 값: 문자열·정수·불·null·실수(소수 4자리로
  /// 반올림, NaN·무한대는 null)·enum(이름)·리스트·맵. 그 밖은 문자열로 바꾼다.
  void log(String event, [Map<String, Object?> data = const {}]) {
    if (!_enabled) return;
    final String line;
    try {
      line =
          encodeLine(DateTime.now(), _clock.elapsedMilliseconds, event, data);
    } catch (_) {
      return; // 기록 때문에 앱이 멈추면 안 된다
    }
    if (_file == null) {
      if (_early.length < maxEarlyLines) _early.add(line);
      return;
    }
    _buf.writeln(line);
    if (_buf.length >= _flushAtChars) unawaited(flush());
  }

  /// 기록 폴더를 열고 새 파일을 만든다. 두 번째 호출부터는 아무것도 하지 않는다.
  Future<void> start({Map<String, Object?> info = const {}}) async {
    if (_file != null || _starting) return;
    _starting = true;
    try {
      final base = await _baseDir();
      final dir = Directory('${base.path}${Platform.pathSeparator}logs');
      await dir.create(recursive: true);
      _dir = dir;
      await _rotate(dir);
      final name = fileNameFor(DateTime.now());
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      _file = file;
      for (final l in _early) {
        _buf.writeln(l);
      }
      _early.clear();
      log('log.start', {'file': name, ...info});
      _timer = Timer.periodic(flushInterval, (_) => unawaited(flush()));
      await flush();
    } catch (e) {
      writeErrors++;
      debugPrint('[T106] 기록 시작 실패: $e');
    } finally {
      _starting = false;
    }
  }

  /// 모인 기록을 파일 끝에 붙인다. 이미 쓰는 중이면 다음 주기로 미룬다.
  Future<void> flush() async {
    final file = _file;
    if (file == null || _writing || _buf.isEmpty) return;
    final chunk = _buf.toString();
    _buf.clear();
    _writing = true;
    try {
      await file.writeAsString(chunk, mode: FileMode.append, flush: true);
    } catch (e) {
      writeErrors++;
      debugPrint('[T106] 기록 쓰기 실패: $e');
    } finally {
      _writing = false;
    }
  }

  /// 앱이 화면에서 내려갈 때 쓴다 — 프로세스가 곧 끝나도 기록이 남게.
  void flushSync() {
    final file = _file;
    if (file == null || _writing || _buf.isEmpty) return;
    final chunk = _buf.toString();
    _buf.clear();
    try {
      file.writeAsStringSync(chunk, mode: FileMode.append, flush: true);
    } catch (e) {
      writeErrors++;
    }
  }

  /// 설정의 "기록 남기기" 스위치. 끄기 직전·켠 직후를 기록에 남긴다.
  void setEnabled(bool value) {
    if (value == _enabled) return;
    if (value) {
      _enabled = true;
      log('log.on');
    } else {
      log('log.off');
      _enabled = false;
      unawaited(flush());
    }
  }

  /// 기록 파일 목록(오래된 것부터).
  Future<List<File>> files() async {
    final dir = _dir;
    if (dir == null || !await dir.exists()) return const <File>[];
    final out = <File>[];
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.jsonl')) out.add(e);
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  /// 공유 직전: 지금까지 모인 기록까지 파일에 쓰고 목록을 돌려준다.
  Future<List<File>> filesForExport() async {
    for (var i = 0; i < 40 && _writing; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await flush();
    return files();
  }

  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    await flush();
  }

  Future<void> _rotate(Directory dir) async {
    final sizes = <String, int>{};
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.jsonl')) {
        sizes[e.path] = await e.length();
      }
    }
    for (final path in pathsToDelete(sizes, maxTotalBytes)) {
      try {
        await File(path).delete();
      } catch (_) {
        // 지우지 못한 파일은 다음 시작 때 다시 시도한다
      }
    }
  }

  /// 한 줄 JSON. 공통 키: `t` 폰 시계(epoch ms), `ms` 프로세스 경과 ms, `ev` 사건 이름.
  @visibleForTesting
  static String encodeLine(DateTime wall, int sinceStartMs, String event,
      Map<String, Object?> data) {
    final m = <String, Object?>{
      't': wall.millisecondsSinceEpoch,
      'ms': sinceStartMs,
      'ev': event,
    };
    data.forEach((k, v) => m[k] = _clean(v));
    return jsonEncode(m);
  }

  static Object? _clean(Object? v) {
    if (v == null || v is String || v is bool || v is int) return v;
    if (v is double) {
      if (!v.isFinite) return null;
      return (v * 10000).roundToDouble() / 10000;
    }
    if (v is Enum) return v.name;
    if (v is Iterable) return v.map(_clean).toList();
    if (v is Map) return v.map((k, x) => MapEntry('$k', _clean(x)));
    return v.toString();
  }

  /// `log_20261002_071530.jsonl` — 이름순이 시간순이다.
  @visibleForTesting
  static String fileNameFor(DateTime t) {
    String d2(int v) => v.toString().padLeft(2, '0');
    return 'log_${t.year}${d2(t.month)}${d2(t.day)}_'
        '${d2(t.hour)}${d2(t.minute)}${d2(t.second)}.jsonl';
  }

  /// 합계가 [maxTotalBytes] 이하가 될 때까지 오래된(이름이 앞선) 파일부터 고른다.
  @visibleForTesting
  static List<String> pathsToDelete(Map<String, int> sizes, int maxTotalBytes) {
    final paths = sizes.keys.toList()..sort();
    var total = sizes.values.fold<int>(0, (a, b) => a + b);
    final out = <String>[];
    for (final p in paths) {
      if (total <= maxTotalBytes) break;
      out.add(p);
      total -= sizes[p]!;
    }
    return out;
  }

  /// 시작 전 버퍼(테스트에서 기록 지점을 확인할 때 쓴다).
  @visibleForTesting
  List<String> get earlyLines => List.unmodifiable(_early);

  @visibleForTesting
  void clearForTest() {
    _early.clear();
    _buf.clear();
    _enabled = true;
  }
}
