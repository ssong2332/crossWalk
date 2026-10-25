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

  // T106: 기록용 이유 — 판정 결과는 바꾸지 않고 이유만 남긴다.
  group('AudioPolicy.lastReason (T106)', () {
    test('재생 중인 것이 없을 때: p0 / ok / min_gap', () {
      final p = AudioPolicy();
      p.decide(FeedbackPriority.p0, t0);
      expect(p.lastReason, 'p0');
      p.decide(FeedbackPriority.p2, t0);
      expect(p.lastReason, 'ok');
      p.markStarted(FeedbackPriority.p2);
      p.markFinished(FeedbackPriority.p2, t0, t0);
      expect(p.decide(FeedbackPriority.p2, t0.add(const Duration(seconds: 1))),
          SpeechAction.drop);
      expect(p.lastReason, 'min_gap');
    });

    test('재생 중: 끊기·대기·버림의 이유', () {
      final p = AudioPolicy()..markStarted(FeedbackPriority.p0);
      expect(p.decide(FeedbackPriority.p1, t0), SpeechAction.queue);
      expect(p.lastReason, 'wait_p0');
      expect(p.decide(FeedbackPriority.p2, t0), SpeechAction.drop);
      expect(p.lastReason, 'busy_p0');
      expect(p.decide(FeedbackPriority.p0, t0), SpeechAction.speakNow);
      expect(p.lastReason, 'interrupt_p0');
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

    test('같은 등급은 끊고 교체한다 (P1 제외 — T108)', () {
      for (final pri in [
        FeedbackPriority.p0,
        FeedbackPriority.p2,
        FeedbackPriority.p3,
      ]) {
        // P0 동급은 방향이 바뀐 경우뿐이다 (같은 방향은 decideMessage의
        // 쿨다운에서 이미 걸러진다).
        expect(withActive(pri).decide(pri, t0), SpeechAction.speakNow,
            reason: '$pri');
      }
    });

    test('P1 재생 중의 P1은 끊지 않고 기다린다 (T108 Q2)', () {
      final p = withActive(FeedbackPriority.p1);
      expect(p.decide(FeedbackPriority.p1, t0), SpeechAction.queue);
      expect(p.lastReason, 'wait_p1');
    });

    test('대체(supersedes)면 재생 중인 P1을 끊는다 (T108 Q3)', () {
      final p = withActive(FeedbackPriority.p1);
      expect(p.decide(FeedbackPriority.p1, t0, supersedes: true),
          SpeechAction.speakNow);
      expect(p.lastReason, 'supersede_p1');
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

  group('AudioPolicy — P0 세부 순위 (T108 Q1)', () {
    AudioPolicy playing(P0Rank rank, [String? message]) =>
        AudioPolicy()..markStarted(FeedbackPriority.p0, rank: rank, message: message);

    test('회복 안내는 재생 중인 이탈 경고를 끊지 않는다', () {
      final p = playing(P0Rank.deviation, '오른쪽으로 이동하세요');
      expect(p.decide(FeedbackPriority.p0, t0, rank: P0Rank.recovery),
          SpeechAction.drop);
      expect(p.lastReason, 'busy_p0');
    });

    test('이탈 경고는 재생 중인 회복 안내를 끊는다', () {
      expect(
          playing(P0Rank.recovery)
              .decide(FeedbackPriority.p0, t0, rank: P0Rank.deviation),
          SpeechAction.speakNow);
    });

    test('차도(위험)는 재생 중인 이탈 경고를 끊는다', () {
      expect(
          playing(P0Rank.deviation)
              .decide(FeedbackPriority.p0, t0, rank: P0Rank.danger),
          SpeechAction.speakNow);
    });

    test('같은 이탈 문구가 재생 중이면 다시 끊지 않는다', () {
      final p = playing(P0Rank.deviation, '오른쪽으로 이동하세요');
      expect(p.decide(FeedbackPriority.p0, t0, message: '오른쪽으로 이동하세요'),
          SpeechAction.drop);
      expect(p.lastReason, 'same_p0');
    });

    test('방향이 바뀌거나 강해진 이탈 문구는 끊고 교체한다', () {
      final p = playing(P0Rank.deviation, '오른쪽으로 이동하세요');
      expect(p.decide(FeedbackPriority.p0, t0, message: '왼쪽으로 이동하세요'),
          SpeechAction.speakNow);
      expect(p.decide(FeedbackPriority.p0, t0, message: '즉시 오른쪽으로 이동하세요'),
          SpeechAction.speakNow);
    });

    test('끊겨서 끝난 발화(current=false)는 새 발화의 재생 중 상태를 지우지 않는다', () {
      final p = playing(P0Rank.deviation, '왼쪽으로 이동하세요');
      p.markFinished(FeedbackPriority.p0, t0, t0, current: false);
      expect(p.activePriority, FeedbackPriority.p0);
      expect(p.activeRank, P0Rank.deviation);
      expect(p.decide(FeedbackPriority.p0, t0, rank: P0Rank.recovery),
          SpeechAction.drop);
    });
  });

  group('AudioPolicy — 무음 보장 (§4)', () {
    test('최소 간격 안의 P1은 버리지 않고 대기한다 (T108 Q2)', () {
      final p = AudioPolicy();
      p.markStarted(FeedbackPriority.p0);
      final end = t0.add(const Duration(seconds: 1));
      p.markFinished(FeedbackPriority.p0, t0, end);
      expect(p.decide(FeedbackPriority.p1, end.add(const Duration(milliseconds: 300))),
          SpeechAction.queue);
      expect(p.lastReason, 'gap_p1');
      expect(p.nextAllowedAt, end.add(AudioPolicy.minGap));
    });

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

    test('같은 등급은 먼저 온 것을 지킨다 — 대체일 때만 덮어쓴다 (T108)', () {
      final p = AudioPolicy();
      expect(p.putPending(FeedbackPriority.p1, '횡단보도를 건넜습니다.', t0), isTrue);
      expect(p.putPending(FeedbackPriority.p1, '멈춤 블록입니다', t0), isFalse);
      expect(p.pendingMessage, '횡단보도를 건넜습니다.');
      expect(
          p.putPending(FeedbackPriority.p1, '앞에 횡단보도가 있습니다.', t0,
              supersedes: true),
          isTrue);
      expect(p.pendingMessage, '앞에 횡단보도가 있습니다.');
    });

    test('만료된 대기 항목은 치워지고 새 P1이 들어간다 (10/12 건넜습니다 분실)', () {
      final p = AudioPolicy();
      expect(p.putPending(FeedbackPriority.p1, '횡단보도에 진입했습니다.', t0),
          isTrue);
      final later = t0.add(const Duration(milliseconds: 10700));
      expect(p.takeExpiredPending(later), '횡단보도에 진입했습니다.');
      expect(p.pendingPriority, isNull);
      expect(p.putPending(FeedbackPriority.p1, '횡단보도를 건넜습니다.', later),
          isTrue);
      expect(p.pendingMessage, '횡단보도를 건넜습니다.');
    });

    test('아직 유효한 대기 항목은 치우지 않는다 — 먼저 온 것을 지킨다', () {
      final p = AudioPolicy();
      p.putPending(FeedbackPriority.p1, '횡단보도를 건넜습니다.', t0);
      final soon = t0.add(const Duration(milliseconds: 2500));
      expect(p.takeExpiredPending(soon), isNull);
      expect(p.putPending(FeedbackPriority.p1, '멈춤 블록입니다', soon), isFalse);
      expect(p.pendingMessage, '횡단보도를 건넜습니다.');
    });

    test('빈 슬롯에서는 아무것도 치우지 않는다', () {
      expect(AudioPolicy().takeExpiredPending(t0), isNull);
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

  // T126: 대기 항목의 TTL은 마지막 P0가 끝난 때부터 센다 — 10/24 실기기 진입 안내
  // 12건 중 6건이 이탈 경고 뒤에서 처음 요청부터 센 3초로 버려졌다.
  // T130: 진입 안내만 상한 3초(maxWait). 다른 P1은 8초 그대로.
  // T131: P0가 끝난 직후 진입 안내 끼워 넣기(afterP0)와 그동안 P0 기다리기.
  group('AudioPolicy — T131 진입 안내 끼워 넣기', () {
    DateTime ms(int v) => t0.add(Duration(milliseconds: v));

    test('afterP0면 최소 간격 안이어도 바로 말한다 (why=after_p0)', () {
      final p = AudioPolicy();
      p.markStarted(FeedbackPriority.p0);
      p.markFinished(FeedbackPriority.p0, ms(-2000), t0);
      expect(p.decide(FeedbackPriority.p1, ms(20), afterP0: true),
          SpeechAction.speakNow);
      expect(p.lastReason, 'after_p0');
      // 끼워 넣기가 아니면 종전대로 간격을 기다린다.
      expect(p.decide(FeedbackPriority.p1, ms(20)), SpeechAction.queue);
      expect(p.lastReason, 'gap_p1');
    });

    test('afterP0여도 재생 중인 P0가 있으면 기다린다', () {
      final p = AudioPolicy();
      p.markStarted(FeedbackPriority.p0);
      expect(p.decide(FeedbackPriority.p1, t0, afterP0: true),
          SpeechAction.queue);
      expect(p.lastReason, 'wait_p0');
    });

    test('afterP0여도 무음 예산은 본다', () {
      final p = AudioPolicy();
      p.markStarted(FeedbackPriority.p3);
      p.markFinished(FeedbackPriority.p3, ms(-25000), ms(-100));
      expect(p.decide(FeedbackPriority.p1, t0, afterP0: true),
          SpeechAction.drop);
      expect(p.lastReason, 'budget');
    });

    test('끼운 진입 재생 중: 이탈·회복 P0는 기다리고 차도는 기다리지 않는다', () {
      final p = AudioPolicy();
      p.markStarted(FeedbackPriority.p1, insertedAt: t0);
      expect(p.insertStartedAt, t0);
      expect(p.holdsP0ForInsert(P0Rank.deviation, ms(500)), isTrue);
      expect(p.holdsP0ForInsert(P0Rank.recovery, ms(500)), isTrue);
      expect(p.holdsP0ForInsert(P0Rank.danger, ms(500)), isFalse);
    });

    test('끼운 지 3초(insertMaxHold)가 지나면 기다리지 않는다', () {
      final p = AudioPolicy();
      expect(AudioPolicy.insertMaxHold, const Duration(seconds: 3));
      p.markStarted(FeedbackPriority.p1, insertedAt: t0);
      expect(p.holdsP0ForInsert(P0Rank.deviation, ms(2999)), isTrue);
      expect(p.holdsP0ForInsert(P0Rank.deviation, ms(3000)), isFalse);
    });

    test('끼운 것이 아닌 P1 재생 중이거나 끝난 뒤에는 기다리지 않는다', () {
      final p = AudioPolicy();
      p.markStarted(FeedbackPriority.p1);
      expect(p.holdsP0ForInsert(P0Rank.deviation, t0), isFalse);
      p.markStarted(FeedbackPriority.p1, insertedAt: t0);
      p.markFinished(FeedbackPriority.p1, t0, ms(2100));
      expect(p.insertStartedAt, isNull);
      expect(p.holdsP0ForInsert(P0Rank.deviation, ms(2200)), isFalse);
    });
  });

  group('AudioPolicy — T130 항목별 상한', () {
    DateTime ms(int v) => t0.add(Duration(milliseconds: v));

    test('maxWait 3초면 P0 재생 중이어도 3초 넘으면 max_wait', () {
      final p = AudioPolicy();
      p.markStarted(FeedbackPriority.p0);
      p.putPending(FeedbackPriority.p1, '횡단보도에 진입했습니다.', t0,
          maxWait: AudioPolicy.entryMaxPendingWait);
      expect(p.pendingExpiry(ms(3000)), isNull);
      expect(p.pendingExpiry(ms(3001)), 'max_wait');
    });

    test('maxWait 없으면 8초 상한 그대로 (T126)', () {
      final p = AudioPolicy();
      p.markStarted(FeedbackPriority.p0);
      p.putPending(FeedbackPriority.p1, '횡단보도를 건넜습니다.', t0);
      expect(p.pendingMaxWait, isNull);
      expect(p.pendingExpiry(ms(3001)), isNull);
      expect(p.pendingExpiry(ms(8001)), 'max_wait');
    });

    test('P0 끝난 뒤부터 TTL(T126)은 그대로 — 3초 상한 안이면 기준은 P0 종료', () {
      final p = AudioPolicy();
      p.markStarted(FeedbackPriority.p0);
      p.putPending(FeedbackPriority.p1, '횡단보도에 진입했습니다.', t0,
          maxWait: AudioPolicy.entryMaxPendingWait);
      p.markFinished(FeedbackPriority.p0, ms(-500), ms(1000));
      expect(p.pendingExpiry(ms(2500)), isNull);
    });

    test('clearPending은 항목 상한도 지운다', () {
      final p = AudioPolicy();
      p.putPending(FeedbackPriority.p1, 'x', t0,
          maxWait: AudioPolicy.entryMaxPendingWait);
      p.clearPending();
      expect(p.pendingMaxWait, isNull);
    });
  });

  group('AudioPolicy — T126 대기 TTL은 P0가 끝난 때부터', () {
    const entry = '횡단보도에 진입했습니다.';
    DateTime ms(int v) => t0.add(Duration(milliseconds: v));

    test('10/24 13:25:34 재현: P0가 2.48초에 끝나면 3.98초에 꺼낼 때 아직 유효하다', () {
      final p = AudioPolicy();
      p.markStarted(FeedbackPriority.p0);
      expect(p.putPending(FeedbackPriority.p1, entry, t0), isTrue);
      p.markFinished(FeedbackPriority.p0, ms(-500), ms(2480));
      // 전: 처음 요청부터 3.98초 > 3초라 버렸다.
      expect(p.isExpired(FeedbackPriority.p1, t0, ms(3980)), isTrue);
      expect(p.pendingExpiry(ms(3980)), isNull);
      expect(p.takeExpiredPending(ms(3980)), isNull);
      expect(p.pendingMessage, entry);
    });

    test('P0가 끝나고 3초가 지나면 만료(ttl)', () {
      final p = AudioPolicy();
      p.markStarted(FeedbackPriority.p0);
      p.putPending(FeedbackPriority.p1, entry, t0);
      p.markFinished(FeedbackPriority.p0, ms(-500), ms(2480));
      expect(p.pendingExpiry(ms(5480)), isNull);
      expect(p.pendingExpiry(ms(5481)), 'ttl');
    });

    test('P0가 재생 중인 동안은 TTL이 흐르지 않는다', () {
      final p = AudioPolicy();
      p.markStarted(FeedbackPriority.p0);
      p.putPending(FeedbackPriority.p1, entry, t0);
      expect(p.pendingExpiry(ms(5000)), isNull);
      expect(p.takeExpiredPending(ms(5000)), isNull);
    });

    test('상한: P0가 이어져도 처음 요청부터 8초가 지나면 만료(max_wait)', () {
      expect(AudioPolicy.maxPendingWait, const Duration(seconds: 8));
      final p = AudioPolicy();
      p.markStarted(FeedbackPriority.p0);
      p.putPending(FeedbackPriority.p1, entry, t0);
      expect(p.pendingExpiry(ms(8000)), isNull);
      expect(p.pendingExpiry(ms(8001)), 'max_wait');
      expect(p.takeExpiredPending(ms(8001)), entry);
      expect(p.pendingPriority, isNull);
    });

    test('상한: 마지막 P0가 방금 끝났어도 8초가 지났으면 만료 (10/24 13:27:39 — 11초)', () {
      final p = AudioPolicy();
      p.markStarted(FeedbackPriority.p0);
      p.putPending(FeedbackPriority.p1, entry, t0);
      p.markFinished(FeedbackPriority.p0, ms(8020), ms(9451));
      expect(p.pendingExpiry(ms(10951)), 'max_wait');
    });

    test('P0 없이 기다리면(최소 간격·P1 재생) 전과 같이 처음 요청부터 3초', () {
      final p = AudioPolicy();
      p.putPending(FeedbackPriority.p1, entry, t0);
      expect(p.pendingExpiry(ms(3000)), isNull);
      expect(p.pendingExpiry(ms(3001)), 'ttl');
    });

    test('요청 전에 끝난 P0는 기준이 아니다', () {
      final p = AudioPolicy();
      p.markStarted(FeedbackPriority.p0);
      p.markFinished(FeedbackPriority.p0, ms(-2000), ms(-500));
      p.putPending(FeedbackPriority.p1, entry, t0);
      expect(p.pendingExpiry(ms(3001)), 'ttl');
    });

    test('끊겨서 끝난 P0(current=false)는 기준이 아니다 — 새 P0가 끝난 때부터', () {
      final p = AudioPolicy();
      p.markStarted(FeedbackPriority.p0);
      p.putPending(FeedbackPriority.p1, entry, t0);
      p.markStarted(FeedbackPriority.p0, message: '즉시 왼쪽으로 가세요');
      p.markFinished(FeedbackPriority.p0, ms(-500), ms(1000), current: false);
      expect(p.pendingExpiry(ms(4500)), isNull, reason: '새 P0 재생 중');
      p.markFinished(FeedbackPriority.p0, ms(1000), ms(4000));
      expect(p.pendingExpiry(ms(7000)), isNull);
      expect(p.pendingExpiry(ms(7001)), 'ttl');
    });

    test('reset은 P0 종료 기준도 지운다', () {
      final p = AudioPolicy();
      p.markStarted(FeedbackPriority.p0);
      p.markFinished(FeedbackPriority.p0, ms(-500), ms(2000));
      p.reset();
      p.putPending(FeedbackPriority.p1, entry, t0);
      expect(p.pendingExpiry(ms(3001)), 'ttl');
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
