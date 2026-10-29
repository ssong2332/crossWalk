// T153: BLE 좌우 진동 모듈 — 규약 바이트, 연결 관리(가짜 전송), FeedbackService
// 출력 경로(모듈 없음·연결·끊김). 실제 BLE 플러그인(`vib_module_ble.dart`)은 부르지 않는다.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/localization/app_strings.dart';
import 'package:crosswalk_app/services/event_log.dart';
import 'package:crosswalk_app/services/feedback_service.dart';
import 'package:crosswalk_app/services/surface_guide.dart';
import 'package:crosswalk_app/services/vib_module.dart';

/// 가짜 전송. [connectError]가 있으면 연결이 실패한다. 쓴 바이트를 모은다.
class _FakeTransport implements VibModuleTransport {
  Object? connectError;
  Object? writeError;
  int connects = 0;
  int disconnects = 0;
  final writes = <List<int>>[];
  final _notes = StreamController<Uint8List>.broadcast(sync: true);
  final _link = StreamController<bool>.broadcast(sync: true);

  @override
  Stream<Uint8List> get notifications => _notes.stream;
  @override
  Stream<bool> get connection => _link.stream;

  @override
  Future<void> connect() async {
    connects++;
    final e = connectError;
    if (e != null) throw e;
  }

  @override
  Future<void> disconnect() async => disconnects++;

  @override
  Future<void> write(Uint8List data) async {
    writes.add(data.toList());
    final e = writeError;
    if (e != null) throw e;
  }

  void pong(int seq, {int batt = 0xFF}) =>
      _notes.add(Uint8List.fromList([VibModuleProtocol.statusPong, seq, batt, 0]));
  void drop() => _link.add(false);
}

List<Map<String, dynamic>> _lines(String ev) => EventLog.instance.earlyLines
    .map((l) => jsonDecode(l) as Map<String, dynamic>)
    .where((m) => m['ev'] == ev)
    .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ttsChannel = MethodChannel('flutter_tts');
  setUp(() {
    EventLog.instance.clearForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, (call) async => 1);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, null);
  });

  group('규약 바이트', () {
    test('가야 할 쪽이 울림: left → 오른쪽 모터, right → 왼쪽 모터', () {
      expect(VibModuleProtocol.sideForKind('left'), VibModuleProtocol.sideRight);
      expect(VibModuleProtocol.sideForKind('right'), VibModuleProtocol.sideLeft);
      for (final k in ['recover', 'road', 'line_on', 'test_both']) {
        expect(VibModuleProtocol.sideForKind(k), VibModuleProtocol.sideBoth);
      }
      expect(VibModuleProtocol.sideForKind('test_left'), VibModuleProtocol.sideLeft);
      expect(VibModuleProtocol.sideForKind('test_right'),
          VibModuleProtocol.sideRight);
      expect(VibModuleProtocol.sideForKind('front'), isNull);
    });

    test('방향 진동 [0,150] → PULSE 01 side 15 str seq', () {
      final b = VibModuleProtocol.fromPattern(
          VibModuleProtocol.sideRight, [0, 150], 200, 7);
      expect(b, [0x01, 2, 15, 200, 7]);
    });

    test('차도 짧게 3번 → PATTERN 02 side str n (on off)… seq', () {
      final b = VibModuleProtocol.fromPattern(
          VibModuleProtocol.sideBoth, [0, 125, 125, 125, 125, 125], 255, 9);
      // 125ms → 반올림 13(10ms 단위). 켜기 3번·끄기 2번이라 마지막 끄기는 0.
      expect(b, [0x02, 3, 255, 3, 13, 13, 13, 13, 13, 0, 9]);
    });

    test('쌍이 4개를 넘으면 앞 4쌍만, 켜기가 없으면 null', () {
      final b = VibModuleProtocol.fromPattern(
          3, [0, 10, 10, 20, 20, 30, 30, 40, 40, 50, 50], 255, 1)!;
      expect(b[3], 4);
      expect(b.length, 4 + 2 * 4 + 1);
      expect(VibModuleProtocol.fromPattern(3, [0], 255, 1), isNull);
      expect(VibModuleProtocol.fromPattern(3, [0, 0, 100], 255, 1), isNull);
    });

    test('길이 상한 2550ms, 하한 10ms, 번호는 한 바이트', () {
      expect(VibModuleProtocol.pulse(1, 9999, 255, 300), [1, 1, 255, 255, 44]);
      expect(VibModuleProtocol.pulse(1, 1, 255, 0)[2], 1);
      expect(VibModuleProtocol.stop(5), [0x03, 5]);
      expect(VibModuleProtocol.ping(6), [0x10, 6]);
    });

    test('STATUS 해석: 배터리 0xFF = 모름(null), 짧으면 null', () {
      final s = VibStatus.parse([1, 4, 0xFF, 0])!;
      expect(s.type, VibModuleProtocol.statusPong);
      expect(s.seq, 4);
      expect(s.battery, isNull);
      expect(VibStatus.parse([1, 4, 80, 0])!.battery, 80);
      expect(VibStatus.parse([1, 4]), isNull);
    });
  });

  group('연결 관리', () {
    late _FakeTransport t;
    late DateTime now;
    late VibModuleController c;
    late List<bool> announced;

    setUp(() {
      t = _FakeTransport();
      now = DateTime(2026, 10, 29, 12);
      c = VibModuleController(t, clock: () => now, autoTimers: false);
      announced = [];
      c.onLinkAnnounce = announced.add;
    });

    test('켜면 연결되고 한 번 알린다, 기록 ble st=search → conn', () async {
      await c.start();
      expect(c.state.value, VibLinkState.connected);
      expect(announced, [true]);
      expect(_lines('ble').map((m) => m['st']), ['search', 'conn']);
    });

    test('1초마다 PING, PONG이 오면 왕복 ms를 남긴다', () async {
      await c.start();
      now = now.add(const Duration(seconds: 1));
      c.tick();
      expect(t.writes.last[0], VibModuleProtocol.opPing);
      final seq = t.writes.last[1];
      now = now.add(const Duration(milliseconds: 40));
      t.pong(seq);
      expect(c.lastRttMs, 40);
      expect(_lines('ble.pong').single['rtt'], 40);
    });

    test('3초 동안 PONG이 없으면 끊김 — 음성 알림 1번, 그 뒤 보내지 않음', () async {
      await c.start();
      for (var i = 1; i <= 2; i++) {
        now = now.add(const Duration(seconds: 1));
        c.tick();
        expect(c.isConnected, isTrue);
      }
      now = now.add(const Duration(seconds: 1));
      c.tick();
      expect(c.state.value, VibLinkState.lost);
      c.tick(); // 끊긴 뒤에는 다시 알리지 않는다
      expect(announced, [true, false]);
      final lost = _lines('ble').where((m) => m['st'] == 'lost').toList();
      expect(lost, hasLength(1));
      expect(lost.single['why'], 'timeout');
      expect(t.disconnects, 1);
      expect(c.send('left', [0, 150]), isFalse);
    });

    test('PONG이 계속 오면 끊기지 않는다', () async {
      await c.start();
      for (var i = 0; i < 6; i++) {
        now = now.add(const Duration(seconds: 1));
        c.tick();
        t.pong(t.writes.last[1]);
      }
      expect(c.isConnected, isTrue);
      expect(announced, [true]);
    });

    test('BLE 연결 끊김 사건 → lost(why=link), 다시 연결되면 re=true로 알림', () async {
      await c.start();
      t.drop();
      expect(c.state.value, VibLinkState.lost);
      expect(await c.tryConnect(), isTrue);
      expect(announced, [true, false, true]);
      final conn = _lines('ble').where((m) => m['st'] == 'conn').toList();
      expect(conn.last['re'], isTrue);
      expect(_lines('ble').firstWhere((m) => m['st'] == 'lost')['why'], 'link');
    });

    test('연결 실패는 fail로 남기고 알리지 않는다, 권한 거절은 denied', () async {
      t.connectError = Exception('scan timeout');
      await c.start();
      expect(c.state.value, VibLinkState.searching);
      expect(announced, isEmpty);
      expect(_lines('ble').last['st'], 'fail');
      t.connectError = const VibPermissionDenied('denied');
      await c.tryConnect();
      expect(c.state.value, VibLinkState.denied);
      expect(_lines('ble').last['st'], 'denied');
    });

    test('쓰기 실패 → 끊김으로 본다', () async {
      await c.start();
      t.writeError = Exception('gatt');
      expect(c.send('left', [0, 150]), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(c.state.value, VibLinkState.lost);
      expect(_lines('ble').map((m) => m['st']), contains('write_err'));
    });

    test('설정 끔: STOP을 보내고 끊되 끊김 알림은 내지 않는다', () async {
      await c.start();
      await c.stop();
      expect(t.writes.last[0], VibModuleProtocol.opStop);
      expect(c.state.value, VibLinkState.off);
      t.drop();
      expect(announced, [true]);
      expect(_lines('ble').last['st'], 'off');
    });

    test('보낸 명령을 ble.cmd로 남긴다(세기 포함)', () async {
      await c.start();
      c.strength = 180;
      expect(c.send('right', [0, 150], src: 'timer'), isTrue);
      final cmd = _lines('ble.cmd').single;
      expect(cmd['kind'], 'right');
      expect(cmd['side'], VibModuleProtocol.sideLeft);
      expect(cmd['str'], 180);
      expect(cmd['src'], 'timer');
      expect(cmd['bytes'], [1, 1, 15, 180, cmd['seq']]);
      expect(t.writes.last, cmd['bytes']);
    });
  });

  group('FeedbackService 출력 경로', () {
    late _FakeTransport t;
    late VibModuleController c;

    setUp(() {
      t = _FakeTransport();
      c = VibModuleController(t, autoTimers: false);
    });

    test('모듈이 없으면 vib 줄은 종전 형식 그대로(out 없음)', () async {
      final s = FeedbackService();
      await s.alert('left', 0.9, angleDegrees: 15);
      final vib = _lines('vib').single;
      expect(vib.containsKey('out'), isFalse);
      expect(_lines('ble.cmd'), isEmpty);
    });

    test('연결된 동안: 모듈만 울린다(out=ble), 가야 할 쪽 = 오른쪽 모터', () async {
      final s = FeedbackService()..attachVibModule(c);
      await c.start();
      await s.alert('left', 0.9, angleDegrees: 15);
      final vib = _lines('vib').single;
      expect(vib['out'], 'ble');
      expect(vib['kind'], 'left');
      expect(_lines('ble.cmd').single['side'], VibModuleProtocol.sideRight);
    });

    test('폰 함께 켬: 모듈 + 폰(out=both)', () async {
      final s = FeedbackService()
        ..attachVibModule(c)
        ..vibModuleWithPhone = true;
      await c.start();
      await s.alert('right', 0.9, angleDegrees: -15);
      expect(_lines('vib').single['out'], 'both');
      expect(_lines('ble.cmd').single['side'], VibModuleProtocol.sideLeft);
    });

    test('끊기면 폰으로 대체(out=phone) + "끊겼습니다" 음성 1번', () async {
      final ko = AppStrings.of(AppLanguage.ko);
      final s = FeedbackService()..attachVibModule(c);
      await c.start();
      t.drop();
      await s.alert('left', 0.9, angleDegrees: 15);
      expect(_lines('vib').single['out'], 'phone');
      expect(_lines('ble.cmd'), isEmpty);
      await Future<void>.delayed(Duration.zero);
      final said = _lines('say').map((m) => m['text']).toList();
      expect(said.where((x) => x == ko.vibModuleLostMessage), hasLength(1));
      expect(said.where((x) => x == ko.vibModuleConnectedMessage), hasLength(1));
    });

    test('노면: 차도는 양쪽 모터 PATTERN', () async {
      final s = FeedbackService()..attachVibModule(c);
      await c.start();
      await s.surfaceAlert([SurfaceEvent.road]);
      final cmd = _lines('ble.cmd').single;
      expect(cmd['op'], VibModuleProtocol.opPattern);
      expect(cmd['side'], VibModuleProtocol.sideBoth);
      expect(_lines('vib').single['out'], 'ble');
    });

    test('떼면(attach null) 종전 경로', () async {
      final s = FeedbackService()..attachVibModule(c);
      await c.start();
      s.attachVibModule(null);
      await s.alert('left', 0.9, angleDegrees: 15);
      expect(_lines('vib').single.containsKey('out'), isFalse);
      expect(c.onLinkAnnounce, isNull);
    });
  });
}
