// T157 P1: 진동 단계 하강 최소 유지(VibrationLevelDwell) 판정표 테스트.
import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/services/vibration_level_dwell.dart';

void main() {
  final t0 = DateTime(2026, 10, 29, 16, 0, 0);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  late VibrationLevelDwell d;
  setUp(() => d = VibrationLevelDwell());

  /// 낸 박자를 'left2'·'front'처럼 돌려준다.
  String step(String? cls, int level, int ms) {
    final out = d.resolve(cls, level, at(ms));
    return out == null ? 'front' : '$out${d.level}';
  }

  test('기본 D는 700ms', () {
    expect(VibrationLevelDwell.defaultMinDwell,
        const Duration(milliseconds: 700));
  });

  test('올라갈 때는 바로(0→2)', () {
    expect(step('left', 0, 0), 'left0');
    expect(step('left', 2, 100), 'left2');
  });

  test('T160: 2에서 0이 나오면 2를 700ms 낸 뒤 0으로 바로 내려간다', () {
    expect(step('left', 2, 0), 'left2');
    expect(step('left', 0, 300), 'left2');
    expect(d.holding, isTrue);
    expect(step('left', 0, 699), 'left2');
    expect(step('left', 0, 700), 'left0');
    expect(d.holding, isFalse, reason: '판정과 같은 단계에 닿음');
  });

  test('T160: 큰 이탈(2) 뒤 직진이면 2 700ms → 0 700ms → 멈춤(단계 1 없음)', () {
    expect(step('left', 2, 0), 'left2');
    expect(step(null, 0, 200), 'left2');
    expect(step(null, 0, 700), 'left0');
    expect(step(null, 0, 1399), 'left0');
    expect(step(null, 0, 1400), 'front');
    expect(d.releaseLate, const Duration(milliseconds: 1200));
  });

  test('직진이 돼도 lvl0을 700ms 낸 뒤 멈추고, 늦어진 시간을 알려 준다', () {
    expect(step('right', 1, 0), 'right1');
    expect(step(null, 0, 200), 'right1');
    expect(step(null, 0, 700), 'right0');
    expect(step(null, 0, 1000), 'right0');
    expect(d.releaseLate, isNull);
    expect(step(null, 0, 1400), 'front');
    expect(d.releaseLate, const Duration(milliseconds: 1200));
    expect(d.cls, isNull);
  });

  test('처음부터 lvl0이던 이탈은 직진이면 바로 멈춘다(종전과 같음)', () {
    expect(step('left', 0, 0), 'left0');
    expect(step(null, 0, 200), 'front');
    expect(d.releaseLate, isNull);
  });

  test('반대 방향은 유지 중이어도 바로 바꾼다', () {
    expect(step('left', 2, 0), 'left2');
    expect(step(null, 0, 200), 'left2');
    expect(step('right', 0, 300), 'right0');
    expect(d.holding, isFalse);
  });

  test('내려가는 중에 다시 올라가면 바로 그 단계', () {
    expect(step('left', 2, 0), 'left2');
    expect(step('left', 0, 700), 'left0');
    expect(step('left', 2, 800), 'left2');
    expect(step('left', 0, 1000), 'left2', reason: '다시 올라간 2부터 700ms');
    expect(step('left', 0, 1500), 'left0');
  });

  test('T160: 오래 지나도 한 번에 2→0까지만 — 0도 700ms 낸 뒤 멈춘다', () {
    expect(step('left', 2, 0), 'left2');
    expect(step(null, 0, 5000), 'left0');
    expect(step(null, 0, 5100), 'left0');
    expect(step(null, 0, 5700), 'front');
  });

  test('reset이면 바로 비운다(hold·none 등)', () {
    expect(step('left', 2, 0), 'left2');
    d.reset();
    expect(d.cls, isNull);
    expect(step(null, 0, 100), 'front');
    expect(d.releaseLate, isNull);
  });

  test('D를 바꿀 수 있다(재생 비교 500/900)', () {
    d = VibrationLevelDwell(minDwell: const Duration(milliseconds: 500));
    expect(step('left', 1, 0), 'left1');
    expect(step(null, 0, 500), 'left0');
    expect(step(null, 0, 1000), 'front');
  });
}
