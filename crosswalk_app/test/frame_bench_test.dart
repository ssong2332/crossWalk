// T104: 실기기 속도 측정 기록기(FrameBench) — 순수 로직 테스트.
import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/services/frame_bench.dart';

void main() {
  test('중앙값: 홀수·짝수 개', () {
    final b = FrameBench();
    for (final v in [5.0, 1.0, 3.0]) {
      b.add('cls', v);
    }
    expect(b.median('cls'), 3.0);
    b.add('cls', 7.0);
    expect(b.median('cls'), 4.0);
  });

  test('최근 window개만 남긴다', () {
    final b = FrameBench(window: 3);
    for (final v in [100.0, 1.0, 2.0, 3.0]) {
      b.add('seg_inf', v);
    }
    expect(b.count('seg_inf'), 3);
    expect(b.max('seg_inf'), 3.0);
  });

  test('값이 없는 키는 null, summary에서는 -', () {
    final b = FrameBench();
    expect(b.median('angle'), isNull);
    b.add('cls', 12.4);
    b.add('frame', 20.0);
    final s = b.summary();
    expect(s, contains('분류 12'));
    expect(s, contains('각도 -'));
    expect(s, contains('프레임 20(최대 20)'));
  });

  test('clear는 모두 비운다', () {
    final b = FrameBench()..add('pos', 1.0);
    b.clear();
    expect(b.count('pos'), 0);
  });
}
