// T140: 오래 건넌 뒤 hold가 발밑 인도로 풀리면 "건넜습니다" — CrossingHold 위 지속과
// FeedbackService 건넘 안내 연결. 시간은 인자로 주입한다.
// 10/27 낮 기록(`log_20261027_121630.jsonl`): 분류기가 끝에서 crossed를 내지 않아
// 실제 끝 10곳이 모두 hold → 발밑 인도 해제 → none으로 조용히 끝났다.
import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/services/crossing_hold.dart';
import 'package:crosswalk_app/services/curb_front_gate.dart';
import 'package:crosswalk_app/services/feedback_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const hold = CrossingHold.holdLabel;
  const crossedMsg = '횡단보도를 건넜습니다.';
  final t0 = DateTime(2026, 10, 27, 12, 17, 10);
  DateTime at(double s) => t0.add(Duration(milliseconds: (s * 1000).round()));

  /// approach → [on]으로 들어와 [holdAt]초에 none, [releaseAt]초에 발밑 인도 해제.
  CrossingHold crossAndRelease(double holdAt, double releaseAt,
      {String on = 'left'}) {
    final h = CrossingHold();
    expect(h.apply('approach', on, at(0)), on);
    expect(h.apply(on, 'front', at(holdAt / 2)), 'front');
    expect(h.apply('front', 'approach', at(holdAt)), hold);
    h.noteGround(1.0);
    h.noteGround(1.0);
    expect(h.apply(hold, 'none', at(releaseAt)), 'none');
    expect(h.releasedByGround, isTrue);
    return h;
  }

  group('CrossingHold 위 지속', () {
    test('기준은 6초(추정값)', () {
      expect(CrossingHold.groundReleaseCrossedMinOn, const Duration(seconds: 6));
    });

    test('10/27 #1: 위 15.7초 뒤 발밑 인도 해제 → 건넘', () {
      // L503 진입 12:17:10.49, L771 hold 25.37, L779 해제 26.14.
      final h = crossAndRelease(14.9, 15.7);
      expect(h.releasedOnDuration, const Duration(milliseconds: 15700));
      expect(h.releasedAfterLongCrossing, isTrue);
    });

    test('10/27 #5: 위 4.3초면 지금처럼 침묵', () {
      final h = crossAndRelease(3.3, 4.3);
      expect(h.releasedOnDuration, const Duration(milliseconds: 4300));
      expect(h.releasedAfterLongCrossing, isFalse);
    });

    test('경계: 정확히 6초는 건넘, 5.9초는 침묵', () {
      expect(crossAndRelease(5, 6).releasedAfterLongCrossing, isTrue);
      expect(crossAndRelease(5, 5.9).releasedAfterLongCrossing, isFalse);
    });

    test('위 ↔ hold 오감은 이어진 것으로 센다(X형 가운데 빈 구간)', () {
      final h = CrossingHold();
      h.apply('approach', 'front', at(0));
      expect(h.apply('front', 'none', at(2)), hold);
      expect(h.apply(hold, 'front', at(4)), 'front');
      expect(h.apply('front', 'none', at(5)), hold);
      h.noteGround(1.0);
      h.noteGround(1.0);
      expect(h.apply(hold, 'none', at(7)), 'none');
      expect(h.releasedOnDuration, const Duration(seconds: 7));
    });

    test('해제 뒤 다시 들어오면 처음부터 센다', () {
      final h = crossAndRelease(9, 10);
      expect(h.apply('none', 'none', at(11)), 'none');
      expect(h.releasedOnDuration, isNull, reason: '해제한 판정에서만 값이 있다');
      h.apply('none', 'right', at(20));
      expect(h.apply('right', 'none', at(22)), hold);
      h.noteGround(1.0);
      h.noteGround(1.0);
      expect(h.apply(hold, 'none', at(23)), 'none');
      expect(h.releasedOnDuration, const Duration(seconds: 3));
      expect(h.releasedAfterLongCrossing, isFalse);
    });

    test('10초 만료·crossed 해제는 건드리지 않는다', () {
      final h = CrossingHold();
      h.apply('approach', 'front', at(0));
      expect(h.apply('front', 'none', at(1)), hold);
      expect(h.apply(hold, 'none', at(11)), 'none');
      expect(h.releasedByGround, isFalse);
      expect(h.releasedOnDuration, isNull);
      h.apply('approach', 'front', at(20));
      expect(h.apply('front', 'none', at(28)), hold);
      expect(h.apply(hold, 'crossed', at(29)), 'crossed');
      expect(h.releasedOnDuration, isNull);
    });

    test('위로 들어온 시각을 모르면(첫 판정부터 위) 침묵', () {
      final h = CrossingHold();
      expect(h.apply('front', 'none', at(0)), hold);
      h.noteGround(1.0);
      h.noteGround(1.0);
      expect(h.apply(hold, 'none', at(8)), 'none');
      expect(h.releasedByGround, isTrue);
      expect(h.releasedOnDuration, isNull);
      expect(h.releasedAfterLongCrossing, isFalse);
    });

    test('건너는 중 연석 확인(T138)은 끼어들지 않는다(10/27 #1 재현)', () {
      final curb = CurbFrontGate();
      curb.note(const FootSurface(ground: 1.0, crosswalk: 0), at(14.5));
      curb.note(const FootSurface(ground: 1.0, crosswalk: 0), at(14.9));
      for (final current in ['left', hold]) {
        expect(
            curb
                .apply('front', current: current, enabled: true, now: at(15))
                .dropped,
            isFalse,
            reason: current);
      }
    });
  });

  group('FeedbackService 건넘 안내', () {
    final rel = at(15.7);
    DateTime after(double s) => rel.add(Duration(milliseconds: (s * 1000).round()));

    test('crossed=true면 해제 프레임의 위 → none/approach에서 건넘 안내', () {
      for (final prev in ['front', 'left', 'right']) {
        for (final now in ['none', 'approach']) {
          final s = FeedbackService()
            ..noteHoldReleasedByGround(rel, holdStartedAt: at(14.9), crossed: true);
          expect(s.decidePhaseMessage(prev, now, rel), crossedMsg,
              reason: '$prev -> $now');
        }
      }
    });

    test('crossed=false(6초 미만)면 지금처럼 침묵, T118 crossed 창은 그대로', () {
      final s = FeedbackService()
        ..noteHoldReleasedByGround(rel, holdStartedAt: at(3.3));
      expect(s.decidePhaseMessage('left', 'none', rel), isNull);
      expect(s.decidePhaseMessage('none', 'crossed', after(2)), crossedMsg);
    });

    test('이미 말했으면 뒤따르는 crossed에서 다시 말하지 않는다(중복 금지)', () {
      final s = FeedbackService()
        ..noteHoldReleasedByGround(rel, holdStartedAt: at(14.9), crossed: true);
      expect(s.decidePhaseMessage('left', 'none', rel), crossedMsg);
      expect(s.decidePhaseMessage('none', 'crossed', after(1)), isNull);
      expect(s.decidePhaseMessage('none', 'crossed', after(4)), isNull,
          reason: '3초 재쿨다운이 지나도 T118 창은 이미 비었다');
    });

    test('안내는 한 번만 — 다음 프레임 none은 침묵', () {
      final s = FeedbackService()
        ..noteHoldReleasedByGround(rel, crossed: true);
      expect(s.decidePhaseMessage('left', 'none', rel), crossedMsg);
      expect(s.decidePhaseMessage('none', 'none', after(5)), isNull);
    });
  });
}
