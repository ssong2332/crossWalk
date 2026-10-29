import 'dart:async';

import 'package:flutter/foundation.dart';

import 'event_log.dart';

/// T153: BLE 좌우 진동 모듈 규약(v1). 설계 초안 `docs/HardwareA_T152.md` §3,
/// 확정본 `hardware/vib_module/README.md`. 펌웨어(`vib_protocol.h`)와 값이 같아야 한다.
///
/// 박자는 폰이 잰다 — 앱이 진동 1번마다 명령 1개를 보내고, 기기는 받은 길이만큼
/// 켠 뒤 **스스로 끈다**. 기기가 스스로 반복하지 않으므로 끊기면 진동도 멈춘다.
class VibModuleProtocol {
  VibModuleProtocol._();

  /// 자체 128비트 UUID(2026-10-29 생성). 특성은 서비스 UUID의 첫 묶음만 +1, +2.
  static const serviceUuid = 'aef7a022-c301-40c9-8c59-0126d6388255';

  /// CMD: 폰 → 기기, Write Without Response.
  static const cmdUuid = 'aef7a023-c301-40c9-8c59-0126d6388255';

  /// STATUS: 기기 → 폰, Notify.
  static const statusUuid = 'aef7a024-c301-40c9-8c59-0126d6388255';

  /// 광고 이름(펌웨어 `VIB_DEVICE_NAME`).
  static const deviceName = 'CW-VIB';

  static const opPulse = 0x01;
  static const opPattern = 0x02;
  static const opStop = 0x03;
  static const opPing = 0x10;

  static const statusPong = 0x01;
  static const statusError = 0x02;

  /// 모터 고르기. 값은 비트(1 = 왼쪽, 2 = 오른쪽).
  static const sideLeft = 1;
  static const sideRight = 2;
  static const sideBoth = 3;

  /// 시간 단위(ms). 1바이트라 한 번 켜기·끄기는 최대 2550ms.
  static const unitMs = 10;

  /// PATTERN 한 명령의 최대 켜기·끄기 쌍 수.
  static const maxPairs = 4;

  /// 세기 기본값(0~255, 255 = 펌웨어 상한 듀티). 펌웨어가 모터 정격에 맞춰 줄인다.
  static const defaultStrength = 255;

  /// 설정 화면 세기 3단계(약하게·보통·강하게). 값은 추정 — 착용 시험에서 체감을 적는다.
  static const strengthLevels = [110, 180, 255];

  /// 진동 뜻 = **가야 할 쪽이 울림**(`docs/HardwarePlan.md` §1, T152 §3-2).
  /// left(왼쪽으로 벗어남 → "오른쪽으로") = 오른쪽 모터, right = 왼쪽 모터.
  /// 복귀·차도·선형 블록 위 = 양쪽. 모르는 kind면 null(보내지 않음).
  static int? sideForKind(String kind) {
    switch (kind) {
      case 'left':
        return sideRight;
      case 'right':
        return sideLeft;
      case 'recover':
      case 'road':
      case 'line_on':
      case 'test_both':
        return sideBoth;
      case 'test_left':
        return sideLeft;
      case 'test_right':
        return sideRight;
    }
    return null;
  }

  /// ms → 10ms 단위(1~255). 0ms는 0(끄기 구간에만 쓴다).
  static int units(int ms, {bool allowZero = false}) {
    final u = (ms / unitMs).round();
    return u.clamp(allowZero ? 0 : 1, 255);
  }

  static Uint8List pulse(int side, int ms, int strength, int seq) =>
      Uint8List.fromList(
          [opPulse, side, units(ms), strength & 0xFF, seq & 0xFF]);

  static Uint8List stop(int seq) => Uint8List.fromList([opStop, seq & 0xFF]);

  static Uint8List ping(int seq) => Uint8List.fromList([opPing, seq & 0xFF]);

  /// 앱의 안드로이드 진동 패턴(`[대기, 켬, 끔, 켬, …]`, ms)을 명령 하나로 바꾼다.
  /// 켜기가 1번이면 PULSE, 여러 번이면 PATTERN(앞 [maxPairs]쌍까지).
  /// 맨 앞 대기는 앱 패턴이 늘 0이라 버린다. 켜기가 없으면 null.
  static Uint8List? fromPattern(
      int side, List<int> pattern, int strength, int seq) {
    final pairs = <List<int>>[];
    for (var i = 1; i < pattern.length; i += 2) {
      final on = pattern[i];
      final off = i + 1 < pattern.length ? pattern[i + 1] : 0;
      if (on <= 0) continue;
      pairs.add([on, off]);
    }
    if (pairs.isEmpty) return null;
    if (pairs.length == 1) return pulse(side, pairs.first[0], strength, seq);
    final used = pairs.take(maxPairs).toList();
    return Uint8List.fromList([
      opPattern,
      side,
      strength & 0xFF,
      used.length,
      for (final p in used) ...[units(p[0]), units(p[1], allowZero: true)],
      seq & 0xFF,
    ]);
  }
}

/// STATUS 알림 한 개: `type seq batt flags`.
class VibStatus {
  const VibStatus(this.type, this.seq, this.battery, this.flags);
  final int type;
  final int seq;

  /// 배터리 %. 분압 저항이 없으면 펌웨어가 0xFF를 보내고 여기서는 null.
  final int? battery;
  final int flags;

  static VibStatus? parse(List<int> bytes) {
    if (bytes.length < 4) return null;
    return VibStatus(
        bytes[0], bytes[1], bytes[2] == 0xFF ? null : bytes[2], bytes[3]);
  }
}

/// 연결 상태. [denied]는 BLE 권한 거절 — 다시 시도하지 않는다.
enum VibLinkState { off, searching, connected, lost, denied }

/// 권한이 거절되면 [VibModuleTransport.connect]가 던진다.
class VibPermissionDenied implements Exception {
  const VibPermissionDenied(this.detail);
  final String detail;
  @override
  String toString() => 'VibPermissionDenied($detail)';
}

/// BLE 플러그인 경계. 실제 구현은 `vib_module_ble.dart`, 테스트는 가짜를 쓴다.
abstract class VibModuleTransport {
  /// 모듈을 찾아 연결하고 STATUS 알림을 구독한다. 실패하면 예외.
  Future<void> connect();

  Future<void> disconnect();

  /// CMD 특성에 쓴다(응답 없는 쓰기).
  Future<void> write(Uint8List data);

  /// STATUS 알림 바이트.
  Stream<Uint8List> get notifications;

  /// 연결이 끊기면 false가 온다.
  Stream<bool> get connection;
}

/// T153: 진동 모듈 연결·연결 확인·명령 보내기. 판정·박자 코드는 모른다 —
/// [FeedbackService]가 진동 1번마다 [send]를 부르고, 연결이 아니면 폰으로 낸다.
class VibModuleController {
  VibModuleController(
    this.transport, {
    DateTime Function()? clock,
    this.autoTimers = true,
  }) : clock = clock ?? DateTime.now;

  final VibModuleTransport transport;

  @visibleForTesting
  DateTime Function() clock;

  /// false면 연결 확인·재연결 타이머를 만들지 않는다(테스트가 [tick]·[tryConnect]를 직접 부른다).
  final bool autoTimers;

  /// T152 §3-5: 1초마다 PING.
  static const pingInterval = Duration(seconds: 1);

  /// T152 §3-5: 3초 동안 PONG이 없으면 끊김(초안 값, 추정 — 현장 시험에서 조정).
  static const linkTimeout = Duration(seconds: 3);

  /// 연결 실패·끊김 뒤 다시 찾기까지 기다리는 시간(추정 값).
  static const retryDelay = Duration(seconds: 3);

  final ValueNotifier<VibLinkState> state = ValueNotifier(VibLinkState.off);

  /// 연결됨(true)·끊김(false)으로 **바뀔 때 한 번** 부른다 — 음성 1회 알림용.
  void Function(bool connected)? onLinkAnnounce;

  /// 세기(0~255). 설정에서 바꾼다.
  int strength = VibModuleProtocol.defaultStrength;

  bool _enabled = false;
  bool _connecting = false;
  int _seq = 0;
  DateTime? _lastPongAt;
  final Map<int, DateTime> _pingSentAt = {};
  int? lastRttMs;
  int? lastBattery;
  StreamSubscription<Uint8List>? _statusSub;
  StreamSubscription<bool>? _linkSub;
  Timer? _pingTimer;
  Timer? _retryTimer;

  bool get isConnected => state.value == VibLinkState.connected;
  bool get enabled => _enabled;

  int _nextSeq() {
    _seq = (_seq + 1) & 0xFF;
    return _seq;
  }

  /// 설정 켬. 찾기·연결을 시작한다(실패하면 [retryDelay]마다 다시).
  Future<void> start() async {
    if (_enabled) return;
    _enabled = true;
    _statusSub ??= transport.notifications.listen(_onStatus);
    _linkSub ??= transport.connection.listen((up) {
      if (!up) _markLost('link');
    });
    _setState(VibLinkState.searching);
    EventLog.instance.log('ble', {'st': 'search'});
    await tryConnect();
  }

  /// 연결 한 번 시도. 성공하면 true.
  @visibleForTesting
  Future<bool> tryConnect() async {
    if (!_enabled || _connecting || isConnected) return isConnected;
    _connecting = true;
    final startedAt = clock();
    try {
      await transport.connect();
    } on VibPermissionDenied catch (e) {
      _connecting = false;
      EventLog.instance.log('ble', {'st': 'denied', 'err': e.detail});
      _setState(VibLinkState.denied);
      return false;
    } catch (e) {
      _connecting = false;
      EventLog.instance.log('ble', {'st': 'fail', 'err': e.toString()});
      _scheduleRetry();
      return false;
    }
    _connecting = false;
    if (!_enabled) {
      unawaited(_safeDisconnect());
      return false;
    }
    final now = clock();
    _lastPongAt = now; // 연결 직후 3초는 PONG을 기다린다.
    _pingSentAt.clear();
    final wasLost = state.value == VibLinkState.lost;
    _setState(VibLinkState.connected);
    EventLog.instance.log('ble', {
      'st': 'conn',
      'dur': now.difference(startedAt).inMilliseconds,
      if (wasLost) 're': true,
    });
    onLinkAnnounce?.call(true);
    if (autoTimers) {
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(pingInterval, (_) => tick());
    }
    return true;
  }

  /// 1초마다: 연결 확인 시간 넘김이면 끊김, 아니면 PING.
  @visibleForTesting
  void tick() {
    if (!isConnected) return;
    final now = clock();
    final last = _lastPongAt;
    if (last != null && now.difference(last) >= linkTimeout) {
      _markLost('timeout');
      return;
    }
    final seq = _nextSeq();
    _pingSentAt[seq] = now;
    // 오래된 것은 버린다(번호가 한 바퀴 돌 때 섞이지 않게).
    _pingSentAt.removeWhere((_, t) => now.difference(t) > linkTimeout * 2);
    _write(VibModuleProtocol.ping(seq));
  }

  void _onStatus(Uint8List bytes) {
    final status = VibStatus.parse(bytes);
    if (status == null) return;
    final now = clock();
    if (status.type == VibModuleProtocol.statusPong) {
      _lastPongAt = now;
      final sent = _pingSentAt.remove(status.seq);
      lastRttMs = sent == null ? null : now.difference(sent).inMilliseconds;
      lastBattery = status.battery;
      EventLog.instance.log('ble.pong', {
        'seq': status.seq,
        'rtt': lastRttMs,
        if (status.battery != null) 'batt': status.battery,
      });
    } else if (status.type == VibModuleProtocol.statusError) {
      EventLog.instance
          .log('ble.err', {'seq': status.seq, 'code': status.flags});
    }
  }

  /// 진동 1번을 모듈로 보낸다. 연결이 아니거나 보낼 수 없는 kind면 false
  /// (호출한 쪽이 폰 진동으로 낸다).
  bool send(String kind, List<int> pattern, {String? src}) {
    if (!isConnected) return false;
    final side = VibModuleProtocol.sideForKind(kind);
    if (side == null) return false;
    final seq = _nextSeq();
    final bytes = VibModuleProtocol.fromPattern(side, pattern, strength, seq);
    if (bytes == null) return false;
    EventLog.instance.log('ble.cmd', {
      'op': bytes[0],
      'kind': kind,
      'side': side,
      'str': strength,
      'seq': seq,
      'bytes': bytes.toList(),
      if (src != null) 'src': src,
    });
    _write(bytes);
    return true;
  }

  /// 모터를 바로 끈다(연결된 때만). [why]는 기록용.
  void sendStop(String why) {
    if (!isConnected) return;
    final seq = _nextSeq();
    EventLog.instance.log('ble.cmd', {
      'op': VibModuleProtocol.opStop,
      'seq': seq,
      'why': why,
    });
    _write(VibModuleProtocol.stop(seq));
  }

  void _write(Uint8List bytes) {
    transport.write(bytes).catchError((Object e) {
      EventLog.instance.log('ble', {'st': 'write_err', 'err': e.toString()});
      _markLost('write');
    });
  }

  /// 연결 → 끊김. 연결 중이었을 때만 기록·음성 알림을 낸다(한 번).
  void _markLost(String why) {
    if (!isConnected) return;
    _pingTimer?.cancel();
    _pingTimer = null;
    _setState(VibLinkState.lost);
    EventLog.instance.log('ble', {
      'st': 'lost',
      'why': why,
      if (_lastPongAt != null)
        'since': clock().difference(_lastPongAt!).inMilliseconds,
    });
    onLinkAnnounce?.call(false);
    unawaited(_safeDisconnect());
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (!_enabled || !autoTimers) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(retryDelay, () => unawaited(tryConnect()));
  }

  Future<void> _safeDisconnect() async {
    try {
      await transport.disconnect();
    } catch (_) {
      // 이미 끊긴 경우 등 — 무시한다.
    }
  }

  /// 설정 끔·화면 종료. 모터를 끄고 연결을 끊는다. 음성 알림은 내지 않는다
  /// (사용자가 끈 것이라 고장이 아님).
  Future<void> stop() async {
    if (!_enabled) return;
    if (isConnected) {
      final seq = _nextSeq();
      try {
        await transport.write(VibModuleProtocol.stop(seq));
      } catch (_) {}
    }
    _enabled = false;
    _pingTimer?.cancel();
    _pingTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    // 끊기 전에 꺼짐으로 바꾼다 — 끊김 사건이 와도 [_markLost]가 알리지 않게.
    _setState(VibLinkState.off);
    EventLog.instance.log('ble', {'st': 'off'});
    await _safeDisconnect();
  }

  void _setState(VibLinkState s) {
    if (state.value != s) state.value = s;
  }

  Future<void> dispose() async {
    await stop();
    await _statusSub?.cancel();
    await _linkSub?.cancel();
    state.dispose();
  }
}
