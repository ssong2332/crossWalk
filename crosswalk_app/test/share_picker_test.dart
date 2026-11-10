// T135: 골라 보내기 — 보냄 기억, 기본 체크 규칙, 고른 파일만 넘기기, 고르기 화면.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';
import 'package:crosswalk_app/localization/app_strings.dart';
import 'package:crosswalk_app/screens/share_picker_screen.dart';
import 'package:crosswalk_app/services/share_picker.dart';

void main() {
  final sep = Platform.pathSeparator;

  group('파일 쓰기', () {
    late Directory tmp;
    late SentRegistry registry;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('share_picker_test');
      registry = SentRegistry(baseDir: () async => tmp);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    File logFile(String name, List<Map<String, Object?>> lines) {
      final dir = Directory('${tmp.path}${sep}logs')
        ..createSync(recursive: true);
      return File('${dir.path}$sep$name')
        ..writeAsStringSync(lines.map((l) => '${jsonEncode(l)}\n').join());
    }

    Future<List<ShareItem>> loadLogs({File? current}) async {
      final dir = Directory('${tmp.path}${sep}logs');
      final files = dir.existsSync()
          ? dir.listSync().whereType<File>().toList()
          : <File>[];
      return logItems(files, await registry.load(),
          relative: registry.relative, current: current);
    }

    group('SentRegistry — 보냄 기억', () {
      test('처음엔 비어 있고, 적은 경로는 상대 경로로 남아 다시 읽힌다', () async {
        final a = logFile('log_20261020_100000.jsonl', [
          {'ev': 'log.start'}
        ]);
        expect(await registry.load(), isEmpty);
        await registry.markSent([a.path]);
        expect(await SentRegistry(baseDir: () async => tmp).load(),
            {'logs${sep}log_20261020_100000.jsonl'});
        expect(File('${tmp.path}$sep${SentRegistry.fileName}').existsSync(),
            isTrue);
      });

      test('회전으로 지워진 경로는 다음에 적을 때 함께 빠진다', () async {
        final a = logFile('log_20261020_100000.jsonl', []);
        final b = logFile('log_20261021_100000.jsonl', []);
        await registry.markSent([a.path]);
        a.deleteSync();
        await registry.markSent([b.path]);
        expect(await registry.load(), {'logs${sep}log_20261021_100000.jsonl'});
      });

      test('기억 파일이 깨져 있으면 모두 안 보냄으로 본다', () async {
        File('${tmp.path}$sep${SentRegistry.fileName}')
            .writeAsStringSync('{not json');
        expect(await registry.load(), isEmpty);
      });
    });

    group('기록 줄 만들기', () {
      test('시작 시각·빌드·크기·보냄·기록 중을 채우고 새 것부터 늘어놓는다', () async {
        final old = logFile('log_20261020_100000.jsonl', [
          {'ev': 'cls'},
          {'ev': 'log.start', 'build': 'abc1234def'},
        ]);
        final cur = logFile('log_20261021_093015.jsonl', [
          {'ev': 'log.start', 'build': 'fff0000'},
        ]);
        await registry.markSent([old.path]);
        final items = await loadLogs(current: cur);
        expect(items.map((i) => i.name),
            ['log_20261021_093015.jsonl', 'log_20261020_100000.jsonl']);
        expect(items[0].start, DateTime(2026, 10, 21, 9, 30, 15));
        expect(items[0].build, 'fff0000');
        expect(items[0].current, isTrue);
        expect(items[0].sent, isFalse);
        expect(items[1].build, 'abc1234def');
        expect(items[1].sent, isTrue);
        expect(items[1].current, isFalse);
        expect(items[1].bytes, old.lengthSync());
      });

      test('log.start가 없으면 빌드는 null', () async {
        logFile('log_20261020_100000.jsonl', [
          {'ev': 'cls'}
        ]);
        expect((await loadLogs()).single.build, isNull);
      });
    });

    test('프레임 묶음 줄: 장수·크기·시각, 빈 묶음은 뺀다', () async {
      final s1 = Directory('${tmp.path}${sep}frames${sep}20261021_171500')
        ..createSync(recursive: true);
      final s2 = Directory('${tmp.path}${sep}frames${sep}20261022_080000')
        ..createSync(recursive: true);
      final f1 = File('${s1.path}${sep}f_1.jpg')
        ..writeAsBytesSync(List.filled(10, 0));
      final f2 = File('${s1.path}${sep}f_2.jpg')
        ..writeAsBytesSync(List.filled(5, 0));
      final f3 = File('${s2.path}${sep}f_3.jpg')
        ..writeAsBytesSync(List.filled(7, 0));
      await registry.markSent([s1.path]);
      final items = await frameItems({
        s1.path: [f1, f2],
        s2.path: [f3],
        '${tmp.path}${sep}frames${sep}20261023_080000': const [],
      }, await registry.load(), relative: registry.relative);
      expect(items.map((i) => i.name), ['20261022_080000', '20261021_171500']);
      expect(items[1].files.length, 2);
      expect(items[1].bytes, 15);
      expect(items[1].sent, isTrue);
      expect(items[0].sent, isFalse);
      expect(items[0].start, DateTime(2026, 10, 22, 8));
    });

    group('T182 큰 묶음 나누기', () {
      // 묶음 폴더에 n장(1바이트씩)을 이름순으로 만든다.
      List<File> makeFrames(Directory dir, int n) => [
            for (var i = 0; i < n; i++)
              File('${dir.path}${sep}f_${1762770000000 + i}.jpg')
                ..writeAsBytesSync(const [0])
          ];

      Directory session(String name) =>
          Directory('${tmp.path}${sep}frames$sep$name')
            ..createSync(recursive: true);

      test('1,719장 → 500/500/500/219 네 줄, 이름순, 열쇠는 조각 첫 파일', () async {
        final s = session('20261110_191206');
        final files = makeFrames(s, 1719);
        final items = await frameItems({s.path: files}, await registry.load(),
            relative: registry.relative);
        expect(items.map((i) => i.files.length), [500, 500, 500, 219]);
        expect(items.map((i) => i.part), [1, 2, 3, 4]);
        expect(items.map((i) => i.parts), [4, 4, 4, 4]);
        expect(items.map((i) => i.path), [
          files[0].path,
          files[500].path,
          files[1000].path,
          files[1500].path
        ]);
        expect(items[3].files.last.path, files.last.path);
        expect(items.map((i) => i.bytes), [500, 500, 500, 219]);
        expect(
            items.every((i) => i.start == DateTime(2026, 11, 10, 19, 12, 6)),
            isTrue);
        expect(items.any((i) => i.sent), isFalse);
        // 다시 열어도 같은 열쇠
        final again = await frameItems({s.path: files}, await registry.load(),
            relative: registry.relative);
        expect(again.map((i) => i.path), items.map((i) => i.path));
      });

      test('조각을 보내면 그 조각만 보냄 — 다시 열어도 유지, 기억 정리에도 남는다',
          () async {
        final s = session('20261110_191206');
        final files = makeFrames(s, 1719);
        Future<List<ShareItem>> load() async => frameItems(
            {s.path: files}, await registry.load(),
            relative: registry.relative);
        final items = await load();
        await registry.markSent([items[1].path]);
        // 다른 경로를 적을 때 정리(지워진 경로 빼기)가 돌아도 조각 열쇠는 남는다
        await registry.markSent([files[1700].path]);
        expect((await load()).map((i) => i.sent), [false, true, false, false]);
      });

      test('T182 전에 묶음 통째로 보냄 → 모든 조각이 보냄(호환)', () async {
        final s = session('20261110_191206');
        final files = makeFrames(s, 1719);
        await registry.markSent([s.path]);
        final items = await frameItems({s.path: files}, await registry.load(),
            relative: registry.relative);
        expect(items.map((i) => i.sent), [true, true, true, true]);
      });

      test('500장 이하 묶음은 지금과 같은 한 줄(열쇠 = 묶음 폴더)', () async {
        final s = session('20261110_080000');
        final files = makeFrames(s, 500);
        final items = await frameItems({s.path: files}, await registry.load(),
            relative: registry.relative);
        expect(items.single.path, s.path);
        expect(items.single.files.length, 500);
        expect(items.single.part, isNull);
        expect(items.single.parts, isNull);
      });

      test('새 묶음부터, 묶음 안에서는 1번 조각부터', () async {
        final old = session('20261110_080000');
        final big = session('20261110_191206');
        final items = await frameItems({
          old.path: makeFrames(old, 3),
          big.path: makeFrames(big, 501),
        }, await registry.load(), relative: registry.relative);
        expect(items.map((i) => '${i.files.length}/${i.part}'),
            ['500/1', '1/2', '3/null']);
      });

      test('저장 중인 묶음이 늘어나면 마지막 조각만 바뀐다', () async {
        final s = session('20261110_191206');
        final files = makeFrames(s, 1200);
        final before = await frameItems(
            {s.path: files.sublist(0, 1100)}, await registry.load(),
            relative: registry.relative);
        final after = await frameItems({s.path: files}, await registry.load(),
            relative: registry.relative);
        expect(after.map((i) => i.path), before.map((i) => i.path));
        expect(before.map((i) => i.files.length), [500, 500, 100]);
        expect(after.map((i) => i.files.length), [500, 500, 200]);
      });

      test('정리로 앞 파일이 지워지면 밀린 조각은 안 보냄, 지워진 열쇠는 빠진다',
          () async {
        final s = session('20261110_191206');
        final files = makeFrames(s, 1719);
        final first = await frameItems({s.path: files}, await registry.load(),
            relative: registry.relative);
        await registry.markSent([first[0].path, first[1].path]);
        for (final f in files.sublist(0, 100)) {
          f.deleteSync();
        }
        final items = await frameItems(
            {s.path: files.sublist(100)}, await registry.load(),
            relative: registry.relative);
        expect(items.map((i) => i.files.length), [500, 500, 500, 119]);
        expect(items.any((i) => i.sent), isFalse);
        await registry.markSent([items[0].path]);
        final kept = await registry.load();
        expect(kept, isNot(contains(await registry.relative(first[0].path))));
        expect(kept, contains(await registry.relative(items[0].path)));
      });
    });

    group('pickAndShare', () {
      late File a, b;
      setUp(() {
        a = logFile('log_20261020_100000.jsonl', []);
        b = logFile('log_20261021_100000.jsonl', []);
      });

      Future<(String?, List<List<File>>, int)> run(
          {Set<String>? Function(List<ShareItem>)? pick,
          ShareResultStatus status = ShareResultStatus.success,
          bool throws = false}) async {
        final shared = <List<File>>[];
        var flushes = 0;
        final msg = await pickAndShare(
          load: loadLogs,
          pick: (items) async =>
              pick == null ? defaultSelection(items) : pick(items),
          beforeShare: () async => flushes++,
          share: (files) async {
            shared.add(files);
            if (throws) throw StateError('x');
            return status;
          },
          registry: registry,
          emptyMessage: 'empty',
          failedMessage: 'failed',
        );
        return (msg, shared, flushes);
      }

      test('고른 파일만 넘기고, success면 보냄으로 적는다', () async {
        final (msg, shared, flushes) = await run(pick: (_) => {b.path});
        expect(msg, isNull);
        expect(shared.single.map((f) => f.path), [b.path]);
        expect(flushes, 1);
        expect(await registry.load(), {'logs${sep}log_20261021_100000.jsonl'});
        // 다음엔 보낸 b가 기본 체크에서 빠진다
        expect(defaultSelection(await loadLogs()), {a.path});
      });

      test('dismissed면 보냄으로 적지 않는다', () async {
        final (_, shared, _) = await run(status: ShareResultStatus.dismissed);
        expect(shared.single.length, 2);
        expect(await registry.load(), isEmpty);
      });

      test('공유가 실패하면 실패 문구, 보냄으로 적지 않는다', () async {
        final (msg, _, _) = await run(throws: true);
        expect(msg, 'failed');
        expect(await registry.load(), isEmpty);
      });

      test('고르기를 취소하거나 아무것도 안 고르면 공유 창을 열지 않는다', () async {
        final (m1, s1, f1) = await run(pick: (_) => null);
        final (m2, s2, _) = await run(pick: (_) => <String>{});
        expect([m1, m2], [null, null]);
        expect([...s1, ...s2], isEmpty);
        expect(f1, 0);
      });

      test('기록이 없으면 빈 문구', () async {
        a.deleteSync();
        b.deleteSync();
        final (msg, shared, _) = await run();
        expect(msg, 'empty');
        expect(shared, isEmpty);
      });
    });
  });

  group('기본 체크·고른 파일', () {
    ShareItem item(String p, {bool sent = false}) => ShareItem(
        path: p, files: [File('$p.a'), File('$p.b')], bytes: 1, sent: sent);

    test('기본 체크는 보낸 적 없는 줄만', () {
      final items = [item('a', sent: true), item('b'), item('c')];
      expect(defaultSelection(items), {'b', 'c'});
      expect(defaultSelection([item('a', sent: true)]), isEmpty);
    });

    test('고른 줄의 파일만 목록 순서대로', () {
      final items = [item('a'), item('b'), item('c')];
      expect(filesFor(items, {'c', 'a'}).map((f) => f.path),
          ['a.a', 'a.b', 'c.a', 'c.b']);
      expect(filesFor(items, {}), isEmpty);
    });
  });

  group('SharePickerScreen', () {
    final items = [
      ShareItem(
          path: 'new',
          files: [File('n')],
          bytes: 2 * 1024 * 1024,
          start: DateTime(2026, 10, 21, 9, 30, 15),
          build: 'abcdef1234',
          current: true),
      ShareItem(
          path: 'old',
          files: [File('o')],
          bytes: 512,
          start: DateTime(2026, 10, 20, 10),
          sent: true),
    ];

    Future<void> open(WidgetTester tester, List<ShareItem> items,
        void Function(Set<String>?) onResult,
        {bool frames = false}) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              onResult(await Navigator.of(context).push<Set<String>>(
                  MaterialPageRoute(
                      builder: (_) => SharePickerScreen(
                          strings: AppStrings.of(AppLanguage.ko),
                          title: '고르기',
                          items: items,
                          frames: frames))));
            },
            child: const Text('go'),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
    }

    testWidgets('줄마다 시각·빌드·크기·보냄을 보이고, 보낸 줄은 체크 해제로 시작', (tester) async {
      await open(tester, items, (_) {});
      expect(find.text('2026-10-21 09:30:15'), findsOneWidget);
      expect(find.text('빌드 abcdef1 · 2.0MB · 기록 중'), findsOneWidget);
      expect(find.text('빌드 — · 512B · 보냄'), findsOneWidget);
      final boxes = tester
          .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
          .map((c) => c.value)
          .toList();
      expect(boxes, [true, false]);
      expect(find.text('보내기 (1)'), findsOneWidget);
    });

    testWidgets('체크를 바꾸고 보내기를 누르면 고른 줄을 돌려준다', (tester) async {
      Set<String>? result = {'unset'};
      await open(tester, items, (r) => result = r);
      await tester.tap(find.text('2026-10-21 09:30:15'));
      await tester.pump();
      expect(find.text('보내기 (0)'), findsOneWidget);
      await tester.tap(find.text('2026-10-20 10:00:00'));
      await tester.pump();
      await tester.tap(find.text('보내기 (1)'));
      await tester.pumpAndSettle();
      expect(result, {'old'});
    });

    testWidgets('뒤로 가면 null', (tester) async {
      Set<String>? result = {'unset'};
      await open(tester, items, (r) => result = r);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(result, isNull);
    });

    testWidgets('프레임 묶음은 장수를 보인다', (tester) async {
      await open(
          tester,
          [
            ShareItem(
                path: 's',
                files: [File('a'), File('b'), File('c')],
                bytes: 3000,
                start: DateTime(2026, 10, 21, 17, 15))
          ],
          (_) {},
          frames: true);
      expect(find.text('3장 · 3KB'), findsOneWidget);
    });

    group('T182 나눈 조각', () {
      List<ShareItem> parts({bool firstSent = false}) => [
            for (var p = 1; p <= 4; p++)
              ShareItem(
                  path: 'k$p',
                  files: [
                    for (var i = 0; i < (p < 4 ? 500 : 219); i++) File('$p-$i')
                  ],
                  bytes: 48 * 1024 * 1024,
                  start: DateTime(2026, 11, 10, 19, 12, 6),
                  sent: firstSent && p == 1,
                  part: p,
                  parts: 4),
          ];

      testWidgets('줄 제목에 (1/4)를 붙이고 장수·크기를 보인다', (tester) async {
        await open(tester, parts(), (_) {}, frames: true);
        expect(find.text('2026-11-10 19:12:06 (1/4)'), findsOneWidget);
        expect(find.text('2026-11-10 19:12:06 (4/4)'), findsOneWidget);
        expect(find.text('500장 · 48.0MB'), findsNWidgets(3));
        expect(find.text('219장 · 48.0MB'), findsOneWidget);
      });

      testWidgets('고른 파일이 500장을 넘으면 안내를 보이고 보내기를 막는다', (tester) async {
        Set<String>? result = {'unset'};
        await open(tester, parts(firstSent: true), (r) => result = r,
            frames: true);
        // 기본 체크는 안 보낸 2~4 → 1,219장
        expect(find.text('보내기 (3)'), findsOneWidget);
        expect(find.text('한 번에 500장 이하로 보내세요'), findsOneWidget);
        await tester.tap(find.text('보내기 (3)'));
        await tester.pumpAndSettle();
        expect(result, {'unset'});
        // 3·4를 빼면 500장 → 보낼 수 있다
        await tester.tap(find.text('2026-11-10 19:12:06 (3/4)'));
        await tester.tap(find.text('2026-11-10 19:12:06 (4/4)'));
        await tester.pump();
        expect(find.text('한 번에 500장 이하로 보내세요'), findsNothing);
        await tester.tap(find.text('보내기 (1)'));
        await tester.pumpAndSettle();
        expect(result, {'k2'});
      });

      testWidgets('기록 고르기에는 500장 제한을 걸지 않는다', (tester) async {
        Set<String>? result;
        await open(
            tester,
            [
              ShareItem(
                  path: 'log',
                  files: [for (var i = 0; i < 501; i++) File('l$i')],
                  bytes: 1)
            ],
            (r) => result = r);
        expect(find.text('한 번에 500장 이하로 보내세요'), findsNothing);
        await tester.tap(find.text('보내기 (1)'));
        await tester.pumpAndSettle();
        expect(result, {'log'});
      });
    });
  });
}
