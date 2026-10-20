// T106: 개발용 사건 기록(`EventLog`) — 형식·회전·파일 쓰기·켜고 끄기.
// path_provider 없이 임시 폴더를 주입해 실제 파일로 확인한다(dart:io).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/services/event_log.dart';

void main() {
  group('encodeLine — 한 줄 JSON', () {
    test('공통 키 t·ms·ev와 데이터를 담고, 실수는 소수 4자리로 반올림한다', () {
      final wall = DateTime.fromMillisecondsSinceEpoch(1790000000123);
      final line = EventLog.encodeLine(wall, 42, 'cls', {
        'conf': 0.123456,
        'probs': [0.5, 1 / 3],
        'ok': true,
        'best': 'front',
        'none': null,
      });
      final m = jsonDecode(line) as Map<String, dynamic>;
      expect(m['t'], 1790000000123);
      expect(m['ms'], 42);
      expect(m['ev'], 'cls');
      expect(m['conf'], 0.1235);
      expect(m['probs'], [0.5, 0.3333]);
      expect(m['ok'], true);
      expect(m['best'], 'front');
      expect(m.containsKey('none'), isTrue);
      expect(m['none'], isNull);
      expect(line.contains('\n'), isFalse, reason: '한 줄이어야 한다');
    });

    test('NaN·무한대는 null, enum은 이름, 중첩 맵도 정리한다', () {
      final line = EventLog.encodeLine(DateTime(2026), 0, 'x', {
        'nan': double.nan,
        'inf': double.infinity,
        'e': _Kind.road,
        'F': {'sw': 0.123449, 'list': [double.nan]},
      });
      final m = jsonDecode(line) as Map<String, dynamic>;
      expect(m['nan'], isNull);
      expect(m['inf'], isNull);
      expect(m['e'], 'road');
      expect(m['F'], {'sw': 0.1234, 'list': [null]});
    });
  });

  test('공통 키(t·ms·ev)와 겹치는 데이터 키는 덮어쓰지 않고 _를 붙여 남긴다', () {
    final line = EventLog.encodeLine(
        DateTime.fromMillisecondsSinceEpoch(1000), 7, 'model',
        {'ms': 420, 'ev': ['road'], 't': 1, 'name': 'cls'});
    final m = jsonDecode(line) as Map<String, dynamic>;
    expect(m['t'], 1000);
    expect(m['ms'], 7);
    expect(m['ev'], 'model');
    expect(m['_ms'], 420);
    expect(m['_ev'], ['road']);
    expect(m['_t'], 1);
    expect(m['name'], 'cls');
  });

  test('fileNameFor — 이름순이 시간순', () {
    expect(EventLog.fileNameFor(DateTime(2026, 10, 2, 7, 5, 9)),
        'log_20261002_070509.jsonl');
  });

  group('pathsToDelete — 합계 상한', () {
    test('상한 이하면 아무것도 지우지 않는다', () {
      expect(EventLog.pathsToDelete({'a': 10, 'b': 10}, 20), isEmpty);
    });

    test('오래된(이름이 앞선) 파일부터 상한 이하가 될 때까지', () {
      final out = EventLog.pathsToDelete(
          {'log_3': 30, 'log_1': 30, 'log_2': 30}, 40);
      expect(out, ['log_1', 'log_2']);
    });
  });

  group('파일 쓰기 (임시 폴더)', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('event_log_test');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    List<Map<String, dynamic>> readLines(File f) => f
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .toList();

    test('시작 전 기록도 파일이 열리면 함께 쓰고, log.start가 뒤따른다', () async {
      final log = EventLog(baseDir: () async => tmp);
      log.log('early', {'n': 1});
      await log.start(info: {'build': 'abc1234'});
      log.log('after', {'n': 2});
      await log.close();

      final files = await log.files();
      expect(files, hasLength(1));
      final events = readLines(files.single).map((m) => m['ev']).toList();
      expect(events, ['early', 'log.start', 'after']);
      final start = readLines(files.single)[1];
      expect(start['build'], 'abc1234');
      expect(start['file'], files.single.uri.pathSegments.last);
    });

    test('끄면 기록하지 않고, 켜면 다시 기록한다(전환도 남긴다)', () async {
      final log = EventLog(baseDir: () async => tmp);
      await log.start();
      log.setEnabled(false);
      log.log('hidden');
      log.setEnabled(true);
      log.log('shown');
      final files = await log.filesForExport();
      await log.close();

      final events = readLines(files.single).map((m) => m['ev']).toList();
      expect(events, ['log.start', 'log.off', 'log.on', 'shown']);
    });

    test('시작할 때 상한을 넘는 옛 파일을 지운다', () async {
      final dir = Directory('${tmp.path}${Platform.pathSeparator}logs')
        ..createSync(recursive: true);
      File('${dir.path}${Platform.pathSeparator}log_20200101_000000.jsonl')
          .writeAsStringSync('x' * 100);
      File('${dir.path}${Platform.pathSeparator}log_20200102_000000.jsonl')
          .writeAsStringSync('y' * 100);

      final log = EventLog(baseDir: () async => tmp, maxTotalBytes: 150);
      await log.start();
      await log.close();

      final names =
          (await log.files()).map((f) => f.uri.pathSegments.last).toList();
      expect(names, isNot(contains('log_20200101_000000.jsonl')));
      expect(names, contains('log_20200102_000000.jsonl'));
      expect(names, hasLength(2), reason: '남은 옛 파일 1개 + 새 파일 1개');
    });
  });

  test('시작 전 버퍼는 maxEarlyLines에서 멈춘다(메모리 보호)', () {
    final log = EventLog(baseDir: () async => Directory.systemTemp);
    for (var i = 0; i < EventLog.maxEarlyLines + 50; i++) {
      log.log('e');
    }
    expect(log.earlyLines, hasLength(EventLog.maxEarlyLines));
  });
}

enum _Kind { road }
