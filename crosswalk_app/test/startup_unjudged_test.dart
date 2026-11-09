// T180: 앱 시작 직후, 분류기 첫 결과 전에는 이탈 음성·진동·hold가 시작되지 않는다.
//
// 실기기 기록(11/09 log_20261109_124521 ms 1861, d0cc9b6 ms 1735): 초기값이
// 'front'였을 때 첫 cls보다 angle이 먼저 와서 '왼쪽으로 가세요'+진동이 나고,
// 이어진 첫 cls none으로 hold가 걸렸다.
//
// camera_screen의 각도·위치 경로는 실제 카메라 프레임이 있어야 돌므로, 여기서는
// 그 경로가 쓰는 판정 순서를 실제 부품(DirectionResolver·CrossingHold·
// FeedbackService.decideMessage)과 실제 초기값(`unjudgedGuidanceLabel`)으로 따라간다.
//   angle 경로: isOnCrosswalk(상태) && !noCall 일 때만 resolve → 바뀌면 alert
//   cls 경로:   resolve(분류, 각도) → CrossingHold.apply(상태, 결과) → hold 아니면 alert
import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/screens/camera_screen.dart';
import 'package:crosswalk_app/services/crossing_hold.dart';
import 'package:crosswalk_app/services/direction_resolver.dart';
import 'package:crosswalk_app/services/feedback_service.dart';

/// camera_screen `_updateAngleEstimate`의 상태 재판정(끝·위치 없음, noCall false).
/// 바뀐 상태가 있으면 돌려주고(= alert 호출), 없으면 null.
String? angleRelabel(String state, double angle) {
  if (!DirectionResolver.isOnCrosswalk(state)) return null;
  final next = DirectionResolver.resolve(state, angle, previous: state);
  return next == state ? null : next;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final t0 = DateTime(2026, 11, 9, 12, 45, 21);

  test('초기값은 위·approach·none 어느 것도 아니다', () {
    expect(unjudgedGuidanceLabel, isNot(anyOf('front', 'left', 'right')));
    expect(DirectionResolver.isOnCrosswalk(unjudgedGuidanceLabel), isFalse);
  });

  test('첫 cls 전에 angle이 이탈 각도(-21.5°, -33°)로 와도 alert(음성·진동)가 없다', () {
    for (final a in [-21.5268, -33.0472, 30.0]) {
      expect(angleRelabel(unjudgedGuidanceLabel, a), isNull, reason: 'angle $a');
    }
    // 비교: 종전 초기값 'front'면 같은 각도에서 이탈로 바뀌었다(기록의 오안내).
    expect(angleRelabel('front', -21.5268), 'right');
  });

  test('첫 cls가 none·approach여도 hold가 시작되지 않는다', () {
    for (final cls in ['none', 'approach']) {
      final hold = CrossingHold();
      expect(hold.apply(unjudgedGuidanceLabel, cls, t0), cls, reason: cls);
    }
    // 비교: 종전 초기값 'front'(또는 오안내로 바뀐 right)면 hold였다.
    expect(CrossingHold().apply('front', 'none', t0), CrossingHold.holdLabel);
    expect(CrossingHold().apply('right', 'none', t0), CrossingHold.holdLabel);
  });

  test('첫 cls 전 무음 → 첫 cls front 뒤에는 기존대로 이탈 판정·안내', () {
    final feedback = FeedbackService();
    final hold = CrossingHold();
    var state = unjudgedGuidanceLabel;

    // ms 1861: 첫 cls 전 angle -21.5 → 아무 안내 없음.
    expect(angleRelabel(state, -21.5268), isNull);

    // 첫 cls front(각도 아직 0 근처) → front, hold 아님.
    final t1 = t0.add(const Duration(milliseconds: 100));
    final r1 = DirectionResolver.resolve('front', 0.0, previous: state);
    state = hold.apply(state, r1, t1);
    expect(state, 'front');
    expect(feedback.decideMessage('front', 0.0, t1), isNull);

    // 그 뒤 angle -21.5 → right(왼쪽으로 가세요), 종전과 같다.
    final t2 = t1.add(const Duration(milliseconds: 300));
    final next = angleRelabel(state, -21.5268);
    expect(next, 'right');
    expect(feedback.decideMessage(next!, -21.5268, t2), '왼쪽으로 가세요');
  });
}
