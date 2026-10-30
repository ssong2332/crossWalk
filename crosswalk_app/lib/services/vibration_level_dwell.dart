/// T157 P1(사용자 승인 2026-10-29): **진동 단계 하강 최소 유지.**
///
/// 10/29 실기기에서 같은 방향 2→1→0 하강은 생겼지만 lvl0 박자가 중앙 300ms만
/// 이어져(20번 중 12번이 0.23~0.36초) 사용자가 '크게 이탈 → 곧바로 직진'으로 느꼈다.
/// 원인은 각도 갱신 주기(중앙 487ms)가 lvl0 구간(c 9~17°)을 한 번에 지나가는 것
/// (`train/field_1029/report_angle.md` §1). 그래서 **진동 박자만** 한 단계씩, 단계마다
/// 최소 [minDwell] 동안 내린다. 음성 판정(`FeedbackService.decideMessage`)은 그대로다.
///
/// T160(오케스트레이터 확정 2026-10-30): 단계가 약 0 / 강 2 둘뿐이라(단계 1 없음)
/// 내릴 때 2 → 0으로 **바로** 내린다. [minDwell] 유지는 그대로(2를 700ms 낸 뒤 0).
///
/// 판정표 (입력 = 이번 판정의 진동 방향·단계. 직진 = front, 끝의 '이미 틀었음'은 그 방향 lvl0):
///   | 지금 내는 박자 | 이번 판정                     | 결과                                              |
///   |---|---|---|
///   | 없음           | left/right                    | 그 방향·단계 바로                                 |
///   | 방향 d 단계 k  | 반대 방향                     | 바로 바꿈(새 방향·단계)                           |
///   | 방향 d 단계 k  | 같은 방향, 단계 >= k          | 바로 그 단계(올라가면 바로)                       |
///   | 방향 d 단계 k  | 같은 방향, 단계 < k           | k를 [minDwell] 낸 뒤 0 (T160: 2 → 0 바로)         |
///   | 방향 d 단계 k>0 | 직진                         | 위와 같이 0으로 내림                              |
///   | 방향 d 단계 0  | 직진, 내려와서 0이 됨          | 0을 [minDwell] 낸 뒤 멈춤 → 그때 직진 확인(진동·딩) |
///   | 방향 d 단계 0  | 직진, 처음부터 0(하강 아님)     | 바로 멈춤(종전과 같음)                            |
///   | 무엇이든       | none·approach·crossed·hold 등 | 바로 멈춤([reset], 틀린 방향 진동 방지)            |
class VibrationLevelDwell {
  VibrationLevelDwell({this.minDwell = defaultMinDwell});

  /// D=700ms(오케스트레이터 지시 시작값). 재생 비교 500/700/900은 `train/t157_report.md`.
  static const defaultMinDwell = Duration(milliseconds: 700);

  final Duration minDwell;

  String? _cls;
  int _level = 0;
  DateTime? _since;
  bool _descended = false;
  DateTime? _straightSince;

  /// 지금 내는 박자의 방향(left/right). 없으면 null.
  String? get cls => _cls;
  int get level => _level;

  /// 이번 [resolve]가 유지 끝에 멈췄으면, 직진이 처음 온 뒤 늦어진 시간. 아니면 null.
  Duration? get releaseLate => _releaseLate;
  Duration? _releaseLate;

  /// 직진·하강 때문에 판정보다 높은 박자를 내고 있는가.
  bool _holding = false;
  bool get holding => _holding;

  /// 이번 판정 [targetCls](left/right, 직진이면 null)·[targetLevel]로 낼 박자를 정한다.
  /// 반환: 낼 방향(left/right) 또는 null(박자 없음 = 직진). 단계는 [level].
  String? resolve(String? targetCls, int targetLevel, DateTime now) {
    _releaseLate = null;
    final cur = _cls;
    if (targetCls == null) {
      _straightSince ??= now;
    } else {
      _straightSince = null;
    }
    if (cur == null) {
      _holding = false;
      if (targetCls != null) _enter(targetCls, targetLevel, now, false);
      return _cls;
    }
    if (targetCls != null && (targetCls != cur || targetLevel >= _level)) {
      // 반대 방향·같은 단계·올라감 — 바로(같은 단계면 시작 시각 유지).
      if (targetCls != cur || targetLevel != _level) {
        _enter(targetCls, targetLevel, now, false);
      }
      _holding = false;
      return _cls;
    }
    // 내려가야 함: 같은 방향 더 낮은 단계, 또는 직진.
    if (targetCls == null && _level == 0 && !_descended) {
      _clear();
      return null;
    }
    if (now.difference(_since!) >= minDwell) {
      if (_level > 0) {
        // T160: 단계 1이 없으므로 한 단계(k-1)가 아니라 0으로 바로 내린다.
        _enter(cur, 0, now, true);
      } else {
        final since = _straightSince;
        _releaseLate = since == null ? null : now.difference(since);
        _clear();
        return null;
      }
    }
    _holding = targetCls == null || targetLevel < _level;
    return _cls;
  }

  void _enter(String cls, int level, DateTime now, bool descended) {
    _cls = cls;
    _level = level;
    _since = now;
    _descended = descended;
  }

  void _clear() {
    _cls = null;
    _level = 0;
    _since = null;
    _descended = false;
    _holding = false;
  }

  /// 바로 멈춘다 — none·approach·crossed·hold·앱 일시정지 등.
  void reset() {
    _clear();
    _straightSince = null;
  }
}
