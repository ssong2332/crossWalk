import 'dart:async';

import 'audio_policy.dart';

/// T142(사용자 승인, 2026-10-27): 같은 방향 이탈 진동을 경고 호출 주기와 분리한다.
///
/// 전에는 진동 반복을 경고 호출(`FeedbackService.alert`, 중앙값 272ms) 때만 검사해서
/// 실제 간격이 호출 주기 단위로 잘렸다(10/27 서 있음 실측 1160/700/654ms, T139 값
/// 600/350/250으로 모의 753/553/404ms — `train/field_1027/report.md` 1장).
/// 이 타이머는 **마지막 진동 + 지금 단계 간격**에 맞춰 한 번 울리고 다시 맞춘다.
///
/// 판정표 (진동 여부 자체는 `VibrationPolicy.decidePattern`이 정한다):
///   | 경우                                                 | 타이머                                         |
///   | left/right 경고 호출                                  | [schedule] — 마지막 진동 + 단계 간격으로 다시 맞춤 |
///   | 단계가 바뀜(같은 방향)                                  | 〃 — 오르면 이미 지났으면 바로, 내려가면 바로 느려짐 |
///   | 방향이 바뀜                                           | 〃 — 바뀐 순간 진동(경고 호출 쪽)한 뒤 새로 맞춤     |
///   | front·crossed·none·approach / hold / 앱 일시정지·종료  | [stop] — 바로 멈춤                              |
///   | 마지막 left/right 경고 호출이 [staleAfter]보다 오래됨   | 울리지 않고 멈춤(판정이 멈춘 경우 안전 장치)        |
class DirectionRepeatTimer {
  DirectionRepeatTimer({
    required this.onDue,
    Timer Function(Duration, void Function())? timerFactory,
  }) : _timerFactory = timerFactory ?? Timer.new;

  /// 예정 시각이 됐다. 진동할지(그리고 [stale] 확인)는 부른 쪽이 정한다.
  final void Function() onDue;
  final Timer Function(Duration, void Function()) _timerFactory;

  /// 경고 호출이 이만큼 없으면 판정이 멈춘 것으로 보고 울리지 않는다(추정값 —
  /// 경고 호출 간격 중앙값 272ms의 약 4배). hold·일시정지는 [stop]이 먼저 멈춘다.
  static const staleAfter = Duration(seconds: 1);

  Timer? _timer;
  String? _cls;
  int _level = 0;
  DateTime? _lastUpdateAt;

  /// 지금 맞춰 둔 방향(left/right). [stop] 뒤에는 null.
  String? get cls => _cls;
  int get level => _level;
  bool get active => _timer != null;

  /// left/right 경고 호출마다 — 판정이 살아 있다는 표시.
  void noteUpdate(DateTime now) => _lastUpdateAt = now;

  /// 마지막 left/right 경고 호출이 [staleAfter]보다 오래됐는가.
  bool stale(DateTime now) =>
      _lastUpdateAt == null || now.difference(_lastUpdateAt!) > staleAfter;

  /// [lastVibratedAt] + [level]의 간격에 [onDue]가 오도록 다시 맞춘다.
  /// 이미 지났으면 바로(1ms 뒤) 부른다.
  void schedule(String cls, int level, DateTime lastVibratedAt, DateTime now) {
    _timer?.cancel();
    _cls = cls;
    _level = level;
    final due = lastVibratedAt.add(VibrationPolicy.repeatIntervalFor(level));
    var wait = due.difference(now);
    if (wait < const Duration(milliseconds: 1)) {
      wait = const Duration(milliseconds: 1);
    }
    _timer = _timerFactory(wait, _fire);
  }

  /// 멈춘다. 돌고 있었으면 true(기록용).
  bool stop() {
    final was = _timer != null;
    _timer?.cancel();
    _timer = null;
    _cls = null;
    return was;
  }

  void _fire() {
    _timer = null;
    onDue();
  }
}
