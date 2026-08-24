// T61 오디오 우선순위 정책 단위 테스트 (docs/AudioPolicy.md).
//
// AudioPolicy/VibrationPolicy는 TTS·진동 플러그인에 의존하지 않는 순수 로직이라
// 판정표를 전수 검증할 수 있다. 이 프로젝트에서 안전 관련 판단이 플러그인 뒤에
// 숨어 있으면 검증이 불가능해지는 문제를 반복해 왔으므로, 정책을 분리한 목적
// 자체가 여기서 확인된다.
import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/services/audio_policy.dart';

void main() {
  final t0 = DateTime(2026, 8, 24, 12, 0, 0);

  group('AudioPolicy.decide — 재생 중인 것이 없을 때', () {
    test('P0는 즉시 발화한다', () {
      final p = AudioPolicy();
      expect(p.decide(FeedbackPriority.p0, t0), SpeechAction.speakNow);
    });

    test('P1~P3도 첫 발화는 통과한다 (직전 발화가 없으므로 간격 제약 없음)', () {
      for (final pri in [
        FeedbackPriority.p1,
        FeedbackPriority.p2,
        FeedbackPriority.p3,
      ]) {
        expect(AudioPolicy().decide(pri, t0), SpeechAction.speakNow,
            reason: '$pri');
      }
    });
  });

  group('AudioPolicy.decide — 끊기 판정표 (docs/AudioPolicy.md §2)', () {
    AudioPolicy withActive(FeedbackPriority active) {
      final p = AudioPolicy();
      p.markStarted(active);
      return p;
    }

    test('더 높은 등급은 재생 중인 것을 끊는다', () {
      expect(withActive(FeedbackPriority.p1).decide(FeedbackPriority.p0, t0),
          SpeechAction.speakNow);
      expect(withActive(FeedbackPriority.p2).decide(FeedbackPriority.p0, t0),
          SpeechAction.speakNow);
      expect(withActive(FeedbackPriority.p3).decide(FeedbackPriority.p1, t0),
          SpeechAction.speakNow);
    });

    test('같은 등급은 끊고 교체한다', () {
      for (final pri in FeedbackPriority.values) {
        // P0 동급은 방향이 바뀐 경우뿐이다 (같은 방향은 decideMessage의
        // 쿨다운에서 이미 걸러진다).
        expect(withActive(pri).decide(pri, t0), SpeechAction.speakNow,
            reason: '$pri');
      }
    });

    test('낮은 등급은 큐에 쌓지 않고 버린다 — 늦은 안내는 오정보다', () {
      expect(withActive(FeedbackPriority.p0).decide(FeedbackPriority.p2, t0),
          SpeechAction.drop);
      expect(withActive(FeedbackPriority.p0).decide(FeedbackPriority.p3, t0),
          SpeechAction.drop);
      expect(withActive(FeedbackPriority.p1).decide(FeedbackPriority.p2, t0),
          SpeechAction.drop);
      expect(withActive(FeedbackPriority.p2).decide(FeedbackPriority.p3, t0),
          SpeechAction.drop);
    });

    test('P0 재생 중에 들어온 P1만 대기한다 (표의 유일한 대기 칸)', () {
      expect(withActive(FeedbackPriority.p0).decide(FeedbackPriority.p1, t0),
          SpeechAction.queue);
    });
  });

  group('AudioPolicy — 무음 보장 (§4)', () {
    test('직전 발화 종료 후 1.5초가 안 지나면 P2를 버린다', () {
      final p = AudioPolicy();
      p.markStarted(FeedbackPriority.p2);
      p.markFinished(FeedbackPriority.p2, t0, t0.add(const Duration(seconds: 1)));
      final soon = t0.add(const Duration(milliseconds: 1400 + 1000));
      expect(p.decide(FeedbackPriority.p2, soon), SpeechAction.drop);
    });

    test('1.5초가 지나면 통과한다', () {
      final p = AudioPolicy();
      p.markStarted(FeedbackPriority.p2);
      p.markFinished(FeedbackPriority.p2, t0, t0.add(const Duration(seconds: 1)));
      final later = t0.add(const Duration(milliseconds: 1000 + 1600));
      expect(p.decide(FeedbackPriority.p2, later), SpeechAction.speakNow);
    });

    test('P0는 최소 간격에서 면제된다', () {
      final p = AudioPolicy();
      p.markStarted(FeedbackPriority.p2);
      p.markFinished(FeedbackPriority.p2, t0, t0.add(const Duration(seconds: 1)));
      final soon = t0.add(const Duration(milliseconds: 1100));
      expect(p.decide(FeedbackPriority.p0, soon), SpeechAction.speakNow);
    });

    test('60초 창에서 20초를 넘게 말했으면 P2를 버린다', () {
      final p = AudioPolicy();
      // 2초짜리 발화를 10회 = 20초. 간격 제약을 피하려 5초씩 띄운다.
      var cursor = t0;
      for (var i = 0; i < 10; i++) {
        p.markStarted(FeedbackPriority.p2);
        p.markFinished(FeedbackPriority.p2, cursor,
            cursor.add(const Duration(seconds: 2)));
        cursor = cursor.add(const Duration(seconds: 5));
      }
      expect(p.spokenInWindow(cursor).inSeconds, greaterThanOrEqualTo(20));
      expect(p.decide(FeedbackPriority.p2, cursor), SpeechAction.drop);
    });

    test('예산이 소진돼도 P0는 나간다', () {
      final p = AudioPolicy();
      var cursor = t0;
      for (var i = 0; i < 10; i++) {
        p.markStarted(FeedbackPriority.p2);
        p.markFinished(FeedbackPriority.p2, cursor,
            cursor.add(const Duration(seconds: 2)));
        cursor = cursor.add(const Duration(seconds: 5));
      }
      expect(p.decide(FeedbackPriority.p0, cursor), SpeechAction.speakNow);
    });

    test('P0 발화는 예산에 누적되지 않는다 — 안전 경고가 다음 안전 경고를 막으면 안 된다', () {
      final p = AudioPolicy();
      p.markStarted(FeedbackPriority.p0);
      p.markFinished(
          FeedbackPriority.p0, t0, t0.add(const Duration(seconds: 30)));
      expect(p.spokenInWindow(t0.add(const Duration(seconds: 30))),
          Duration.zero);
    });

    test('60초보다 오래된 발화는 창에서 빠진다', () {
      final p = AudioPolicy();
      p.markStarted(FeedbackPriority.p2);
      p.markFinished(FeedbackPriority.p2, t0, t0.add(const Duration(seconds: 5)));
      final muchLater = t0.add(const Duration(seconds: 200));
      expect(p.spokenInWindow(muchLater), Duration.zero);
    });
  });

  group('AudioPolicy — TTL (§3)', () {
    test('P0는 1초, P1은 3초, P2는 5초가 지나면 만료된다', () {
      final p = AudioPolicy();
      expect(
          p.isExpired(FeedbackPriority.p0, t0,
              t0.add(const Duration(milliseconds: 1200))),
          isTrue);
      expect(
          p.isExpired(FeedbackPriority.p1, t0,
              t0.add(const Duration(milliseconds: 2500))),
          isFalse);
      expect(p.isExpired(FeedbackPriority.p1, t0,
              t0.add(const Duration(milliseconds: 3500))),
          isTrue);
      expect(p.isExpired(FeedbackPriority.p2, t0,
              t0.add(const Duration(seconds: 4))),
          isFalse);
    });

    test('P3는 즉시 아니면 버린다', () {
      final p = AudioPolicy();
      expect(
          p.isExpired(FeedbackPriority.p3, t0,
              t0.add(const Duration(milliseconds: 1))),
          isTrue);
    });
  });

  group('AudioPolicy — 대기 슬롯', () {
    test('더 높은 등급만 슬롯을 덮어쓴다', () {
      final p = AudioPolicy();
      p.putPending(FeedbackPriority.p1, 'first', t0);
      p.putPending(FeedbackPriority.p2, 'second', t0);
      expect(p.pendingPriority, FeedbackPriority.p1);
      expect(p.pendingMessage, 'first');

      p.putPending(FeedbackPriority.p0, 'urgent', t0);
      expect(p.pendingPriority, FeedbackPriority.p0);
      expect(p.pendingMessage, 'urgent');
    });

    test('clearPending은 슬롯을 비운다', () {
      final p = AudioPolicy();
      p.putPending(FeedbackPriority.p1, 'x', t0);
      p.clearPending();
      expect(p.pendingPriority, isNull);
      expect(p.pendingMessage, isNull);
      expect(p.pendingAt, isNull);
    });
  });

  group('VibrationPolicy — 좌우 패턴 분리 (§5)', () {
    test('왼쪽은 짧게 두 번, 오른쪽은 길게 한 번', () {
      final left = VibrationPolicy().decidePattern('left', t0, 400);
      final right = VibrationPolicy().decidePattern('right', t0, 400);

      expect(left, isNotNull);
      expect(right, isNotNull);
      // [대기, 진동, 대기, 진동] = 두 번 울린다
      expect(left!.length, 4);
      // [대기, 진동] = 한 번 울린다
      expect(right!.length, 2);
      expect(right[1], 400);
    });

    test('두 패턴은 서로 다르다 — 이것이 분리의 목적이다', () {
      final left = VibrationPolicy().decidePattern('left', t0, 400);
      final right = VibrationPolicy().decidePattern('right', t0, 400);
      expect(left, isNot(equals(right)));
    });

    test('짧은 진동은 하한 80ms를 지킨다 — 설정을 최소로 낮춰도 두 번이 뭉치지 않게', () {
      final left = VibrationPolicy().decidePattern('left', t0, 100);
      expect(left![1], greaterThanOrEqualTo(80));
    });

    test('방향이 바뀌면 쿨다운을 무시하고 즉시 낸다', () {
      final v = VibrationPolicy();
      expect(v.decidePattern('left', t0, 400), isNotNull);
      final immediately = t0.add(const Duration(milliseconds: 200));
      expect(v.decidePattern('right', immediately, 400), isNotNull);
    });

    test('같은 방향이 3초 안에 반복되면 진동하지 않는다', () {
      final v = VibrationPolicy();
      v.decidePattern('left', t0, 400);
      final soon = t0.add(const Duration(milliseconds: 2500));
      expect(v.decidePattern('left', soon, 400), isNull);
    });

    test('같은 방향이 3초 이상 지속되면 다시 낸다 — 음성 재발화와 같은 박자', () {
      final v = VibrationPolicy();
      v.decidePattern('left', t0, 400);
      final later = t0.add(const Duration(milliseconds: 3100));
      expect(v.decidePattern('left', later, 400), isNotNull);
    });
  });

  group('VibrationPolicy — 정상 복귀 / 무진동 상태', () {
    test('이탈에서 front로 돌아오면 짧은 확인 진동 1회', () {
      final v = VibrationPolicy();
      v.decidePattern('right', t0, 400);
      final back = t0.add(const Duration(seconds: 1));
      final p = v.decidePattern('front', back, 400);
      expect(p, isNotNull);
      expect(p!.length, 2);
      expect(p[1], lessThan(400), reason: '확인 진동은 방향 진동보다 짧아야 한다');
    });

    test('이탈 없이 front가 계속되면 진동하지 않는다', () {
      final v = VibrationPolicy();
      expect(v.decidePattern('front', t0, 400), isNull);
      expect(
          v.decidePattern('front', t0.add(const Duration(seconds: 5)), 400),
          isNull);
    });

    test('none / approach는 진동하지 않는다', () {
      final v = VibrationPolicy();
      expect(v.decidePattern('none', t0, 400), isNull);
      expect(v.decidePattern('approach', t0, 400), isNull);
    });

    test('none을 거친 뒤 front는 확인 진동을 내지 않는다 (이탈 복귀가 아니므로)', () {
      final v = VibrationPolicy();
      v.decidePattern('left', t0, 400);
      v.decidePattern('none', t0.add(const Duration(seconds: 1)), 400);
      expect(
          v.decidePattern('front', t0.add(const Duration(seconds: 2)), 400),
          isNull);
    });
  });
}
