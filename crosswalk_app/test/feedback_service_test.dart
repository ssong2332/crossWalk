// Unit tests for FeedbackService's pure decision logic (cooldown,
// class-change, front-silence).
//
// alert() entangles the decision logic with real side effects
// (flutter_tts / vibration platform channels) and reads DateTime.now()
// internally, making it non-deterministic and unmockable without heavy
// platform-channel mocking. Following the same pattern used for
// Classifier (T9), the decision logic is exposed as the
// `@visibleForTesting` `decideMessage()` method, which takes the current
// time as an explicit parameter. Tests drive this method directly on a
// fresh FeedbackService() instance and never call init() or touch
// _tts/Vibration.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/localization/app_strings.dart';
import 'package:crosswalk_app/services/audio_policy.dart';
import 'package:crosswalk_app/services/crossing_hold.dart';
import 'package:crosswalk_app/services/event_log.dart';
import 'package:crosswalk_app/services/feedback_service.dart';
import 'package:crosswalk_app/services/stillness_detector.dart';
import 'package:crosswalk_app/services/surface_guide.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const leftMild = '오른쪽으로 가세요';
  const leftSevere = '즉시 오른쪽으로 가세요';
  const rightMild = '왼쪽으로 가세요';
  const rightSevere = '즉시 왼쪽으로 가세요';
  // T84: decideMessage(class, angleDegrees, now)의 두 번째 인자는 각도
  // 모델의 보정 각도(도)다. |각도| >= FeedbackService.severeAngleDegrees(25)
  // 이면 심함. 아래 두 상수로 강도와 무관한 기존 쿨다운/전이 테스트를
  // 그대로 재사용한다. (T63~T83까지는 분류기 신뢰도 0.6/0.9였다.)
  const mild = 10.0;
  const severe = 40.0;

  // flutter_tts 4.2.5 (lib/flutter_tts.dart:330):
  // static const MethodChannel _channel = MethodChannel('flutter_tts');
  // T39's updateLanguage()/updateSpeechRate() await _tts.setLanguage()/
  // setSpeechRate(), which would otherwise throw MissingPluginException
  // with no handler registered on this channel (same pattern as
  // camera_screen_test.dart's mockFlutterTts()).
  const ttsChannel = MethodChannel('flutter_tts');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, (call) async => 1);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, null);
  });

  group('FeedbackService.decideMessage — front silence', () {
    test('returns null for "front" regardless of prior state', () {
      final service = FeedbackService();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      expect(service.decideMessage('front', 0.0, t0), isNull);

      // Even after a prior alert has fired for another class, "front"
      // must still stay silent.
      service.decideMessage('left', mild, t0);
      expect(
        service.decideMessage(
            'front', 0.0, t0.add(const Duration(seconds: 10))),
        isNull,
      );
    });
  });

  // T42: "none"(횡단보도 없음)도 "front"와 동일하게 무음 처리되어야 한다 —
  // 횡단보도가 안 보이는 상태에서 좌/우 이탈 경보를 울리는 것은 의미가 없다.
  group('FeedbackService.decideMessage — none silence', () {
    test('returns null for "none" regardless of prior state', () {
      final service = FeedbackService();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      expect(service.decideMessage('none', 0.0, t0), isNull);

      // Even after a prior alert has fired for another class, "none"
      // must still stay silent.
      service.decideMessage('left', mild, t0);
      expect(
        service.decideMessage('none', 0.0, t0.add(const Duration(seconds: 10))),
        isNull,
      );
    });
  });

  // T51: "approach"(인도 위인데 앞에 진입할 횡단보도가 보임)도 "front"/"none"과
  // 동일하게 무음이어야 한다 — 아직 횡단보도 위가 아니므로 좌/우 이탈 경보를
  // 울릴 근거가 없다. 5-class 전환으로 사용자가 겪는 동작이 바뀌지 않는다는
  // 보장이 이 테스트다 (docs/PRD.md §클래스 정의).
  group('FeedbackService.decideMessage — approach silence', () {
    test('returns null for "approach" regardless of prior state', () {
      final service = FeedbackService();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      expect(service.decideMessage('approach', 0.0, t0), isNull);

      // Even after a prior alert has fired for another class, "approach"
      // must still stay silent.
      service.decideMessage('left', mild, t0);
      expect(
        service.decideMessage(
            'approach', 0.0, t0.add(const Duration(seconds: 10))),
        isNull,
      );
    });
  });

  group('FeedbackService.decideMessage — first alert', () {
    test('fires immediately on a fresh instance for "left"', () {
      final service = FeedbackService();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      final message = service.decideMessage('left', mild, t0);

      expect(message, isNotNull);
      expect(message, leftMild);
    });
  });

  group('FeedbackService.decideMessage — cooldown', () {
    test(
        'suppresses a same-class-and-severity repeat within the cooldown '
        'window', () {
      final service = FeedbackService();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      final first = service.decideMessage('left', mild, t0);
      expect(first, isNotNull);

      final second = service.decideMessage(
          'left', mild, t0.add(const Duration(seconds: 1)));
      expect(second, isNull);
    });

    test('fires again once the cooldown has elapsed for the same class', () {
      final service = FeedbackService();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      final first = service.decideMessage('left', mild, t0);
      expect(first, isNotNull);

      // T120: 같은 방향 재경고는 3초 -> 6초(sameDirectionBundle). 검사는
      // `< 6초`이므로 정확히 6초 뒤에는 더 이상 묶이지 않는다.
      expect(
          service.decideMessage(
              'left', mild, t0.add(const Duration(seconds: 3))),
          isNull);
      final second = service.decideMessage(
          'left', mild, t0.add(const Duration(seconds: 6)));
      expect(second, isNotNull);
      expect(second, leftMild);
    });

    // T63: 강도가 바뀌면(약함<->심함) 방향이 그대로여도 쿨다운을 무시하고
    // 즉시 재발화한다 — 갑자기 심해진 이탈을 3초 동안 못 알리면 안 된다.
    // T88: 올라가는 변화는 dwell 없이 즉시 반영되므로 1ms 뒤에도 발화한다.
    // 내려가는 변화는 여전히 dwell(2초)을 채워야 인정된다.
    test('severity escalation bypasses cooldown immediately (T63/T88)', () {
      final service = FeedbackService();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      expect(service.decideMessage('left', mild, t0), leftMild);

      final escalated = service.decideMessage(
        'left',
        severe,
        t0.add(const Duration(milliseconds: 1)),
      );
      expect(escalated, leftSevere,
          reason: '심해진 이탈은 쿨다운·dwell 없이 즉시 알린다');

      // 내려가는 변화: 1ms 뒤에는 아직 심함, 2초를 채우면 약함으로 재발화.
      final tooSoon = service.decideMessage(
        'left',
        mild,
        t0.add(const Duration(milliseconds: 2)),
      );
      expect(tooSoon, isNull, reason: '내려가는 변화는 dwell 전에는 인정하지 않는다');
      // T120: 2초를 채워 약함으로 바뀌어도 내려간 것이라 6초 묶음 안에서는 침묵.
      final deescalated = service.decideMessage(
        'left',
        mild,
        t0.add(const Duration(milliseconds: 2002)),
      );
      expect(deescalated, isNull,
          reason: 'T120: 같은 방향에서 내려간 단계는 6초 안에 다시 말하지 않는다');
    });

    // T82(2026-09-08, 사용자 실기기 보고): "가만히 서 있는데 '크게 벗어남'과
    // '이탈'이 번갈아 나오고 그때마다 음성·진동이 다시 나온다."
    // 원인은 쿨다운 키가 (클래스, 강도)라서 강도가 뒤집히면 쿨다운이
    // 무효화되는 것이었다. 실측: 같은 방향 연속쌍 46쌍 중 11쌍(23.9%)에서
    // 강도가 뒤집혔고 변화폭이 0.98->0.68처럼 컸다.
    // T88(2026-09-13): 올라가는 변화(약함->심함)는 즉시 반영하므로 첫 상승은
    // 1회 재발화한다(안전 경고를 늦추지 않기 위해). 내려가는 쪽은 여전히
    // 2초를 기다리므로, 그 뒤의 요동은 재발화하지 않는다.
    test('튀는 강도 변화는 최대 1회(상승)만 재발화한다 (T82 -> T88)', () {
      final service = FeedbackService();
      var t = DateTime(2026, 1, 1, 12, 0, 0);

      expect(service.decideMessage('left', mild, t), leftMild);

      final fired = <String>[];
      for (final angle in [severe, mild, severe, mild, severe]) {
        t = t.add(const Duration(milliseconds: 500));
        final m = service.decideMessage('left', angle, t);
        if (m != null) fired.add(m);
      }
      expect(fired, [leftSevere],
          reason: '상승 1회만 재발화하고 이후 요동은 흡수돼야 한다');
    });

    test('방향이 바뀌면 강도를 물려받지 않는다 (T82)', () {
      final service = FeedbackService();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      // 왼쪽에서 심함으로 확정된 상태를 만든다.
      service.decideMessage('left', severe, t0);
      expect(service.isSevere, isTrue);

      // 오른쪽으로 바뀌고 신뢰도가 낮으면, 왼쪽의 '심함'을 물려받지 않고
      // 그 방향의 첫 관측대로 약함이 되어야 한다. (래치를 초기화하지 않으면
      // 여기서 dwell 때문에 2초간 '심함'이 그대로 남는다.)
      final right = service.decideMessage(
          'right', mild, t0.add(const Duration(seconds: 3)));
      expect(right, rightMild,
          reason: '왼쪽에서 심했다고 오른쪽도 심한 것은 아니다');
      expect(service.isSevere, isFalse);
    });

    test('이탈이 아닌 상태로 가면 강도가 초기화된다 (T82)', () {
      final service = FeedbackService();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      service.decideMessage('left', severe, t0);
      service.decideMessage('left', severe, t0.add(const Duration(seconds: 2)));
      expect(service.isSevere, isTrue);

      service.decideMessage('front', 0.0, t0.add(const Duration(seconds: 3)));
      expect(service.isSevere, isFalse);
    });
  });

  group('FeedbackService.decideMessage — class change', () {
    test('bypasses cooldown immediately when the detected class changes', () {
      final service = FeedbackService();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      final first = service.decideMessage('left', mild, t0);
      expect(first, isNotNull);

      // Well within what would be the "left" cooldown window, but the
      // class changed to "right" — cooldown is per-class, not global.
      final second = service.decideMessage(
        'right',
        mild,
        t0.add(const Duration(milliseconds: 1)),
      );
      expect(second, isNotNull);
      expect(second, rightMild);
    });
  });

  group('FeedbackService.decideMessage — message content', () {
    // T82: 강도 변화는 SeverityLatch의 dwell(2초)을 넘겨야 반영되므로,
    // 한 인스턴스에서 약함 -> 심함을 한 번의 호출로 확인할 수 없다. 문구 자체를
    // 확인하는 테스트이므로 각각 새 인스턴스의 **첫 관측**으로 본다
    // (첫 관측은 dwell 없이 곧바로 반영된다).
    test('returns the exact left-deviation Korean messages (mild/severe)', () {
      expect(
        FeedbackService().decideMessage('left', mild, DateTime(2026, 1, 1)),
        '오른쪽으로 가세요',
      );
      expect(
        FeedbackService().decideMessage('left', severe, DateTime(2026, 1, 1)),
        '즉시 오른쪽으로 가세요',
      );
    });

    test('returns the exact right-deviation Korean messages (mild/severe)', () {
      expect(
        FeedbackService().decideMessage('right', mild, DateTime(2026, 1, 1)),
        '왼쪽으로 가세요',
      );
      expect(
        FeedbackService().decideMessage('right', severe, DateTime(2026, 1, 1)),
        rightSevere,
      );
    });

    // T84: |각도| == severeAngleDegrees 정확히 그 값은 심함으로 친다(>=, > 아님).
    test('treats |angle| exactly at severeAngleDegrees as severe', () {
      final service = FeedbackService();
      final message = service.decideMessage(
          'left', FeedbackService.severeAngleDegrees, DateTime(2026, 1, 1));

      expect(message, leftSevere);
    });

    // T84: 강도는 각도의 **크기**로만 정한다. 부호(방향)는 분류기 클래스가
    // 담당하므로, 클래스와 각도 부호가 어긋나도 강도 판정은 크기만 본다.
    test('severity uses |angle| — sign does not matter (T84)', () {
      expect(
        FeedbackService().decideMessage('right', 40.0, DateTime(2026, 1, 1)),
        rightSevere,
      );
      expect(
        FeedbackService().decideMessage('left', -40.0, DateTime(2026, 1, 1)),
        leftSevere,
      );
    });

    // T84: 각도 모델이 아직 값을 못 내면(준비 중·미검출) 보수적으로 약함.
    test('null angle is mild, not severe (T84)', () {
      expect(
        FeedbackService().decideMessage('left', null, DateTime(2026, 1, 1)),
        leftMild,
      );
    });

    // T84 회귀 방지: 분류기 신뢰도는 강도에 영향을 주지 않는다. 실기기에서
    // "신뢰도 100%인데 18도 -> 크게 벗어남"이 나왔던 것을 막는다.
    test('18 degrees is mild regardless of classifier confidence (T84)', () {
      final service = FeedbackService();
      final message = service.decideMessage('left', 18.0, DateTime(2026, 1, 1));
      expect(message, leftMild);
      expect(service.isSevere, isFalse);
    });
  });

  // T63: 구간 전이 — 반복 경고가 아니라 1회성 사실. decidePhaseMessage는
  // "직전 클래스"를 인자로 받는 순수 함수라, 시간 흐름을 시뮬레이션하지
  // 않고도 모든 전이 조합을 테스트할 수 있다.
  group('FeedbackService.decidePhaseMessage — 구간 전이 (T63)', () {
    test('approach -> front/left/right는 진입 안내를 낸다', () {
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      for (final entering in ['front', 'left', 'right']) {
        final s = FeedbackService();
        expect(
          s.decidePhaseMessage('approach', entering, t0),
          '횡단보도 진입.',
          reason: 'approach -> $entering',
        );
      }
    });

    // T103(사용자 확정): 다 건넘은 위 -> crossed 순간에 안내한다.
    test('front/left/right -> crossed는 완료 안내를 낸다 (T103)', () {
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      for (final crossing in ['front', 'left', 'right']) {
        final s = FeedbackService();
        expect(
          s.decidePhaseMessage(crossing, 'crossed', t0),
          '횡단보도를 건넜습니다.',
          reason: '$crossing -> crossed',
        );
      }
    });

    // T103: 위 -> none은 줄무늬가 잠깐 안 보이거나 오판일 수 있어 침묵.
    test('front/left/right -> none은 안내하지 않는다 (T103)', () {
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      for (final on in ['front', 'left', 'right']) {
        expect(FeedbackService().decidePhaseMessage(on, 'none', t0), isNull,
            reason: '$on -> none');
      }
    });

    // T103: 다 건넌 과정(위 -> crossed -> none)의 나머지 전이는 침묵.
    test('crossed -> none/approach, none/approach -> crossed는 침묵 (T103)', () {
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      expect(FeedbackService().decidePhaseMessage('crossed', 'none', t0),
          isNull);
      expect(FeedbackService().decidePhaseMessage('crossed', 'approach', t0),
          isNull,
          reason: '건너편 횡단보도가 보여도 "앞에 횡단보도"는 none에서 올 때만');
      expect(FeedbackService().decidePhaseMessage('none', 'crossed', t0),
          isNull);
      expect(FeedbackService().decidePhaseMessage('approach', 'crossed', t0),
          isNull);
    });

    // T118(A2): 발밑이 인도라서 hold를 일찍 푼 뒤 5초 안의 crossed는 건넘 안내.
    test('hold 일찍 해제 뒤 5초 안 none/approach -> crossed는 완료 안내 (T118)', () {
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      for (final prev in ['none', 'approach']) {
        final s = FeedbackService()..noteHoldReleasedByGround(t0);
        expect(s.decidePhaseMessage(prev, 'crossed',
                t0.add(const Duration(seconds: 3))),
            '횡단보도를 건넜습니다.', reason: '$prev -> crossed');
      }
      expect(FeedbackService.groundReleaseCrossedWindow,
          const Duration(seconds: 5));
    });

    test('hold 일찍 해제 뒤라도 5초가 지나면 침묵, 한 번 쓰면 비운다 (T118)', () {
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      final late = FeedbackService()..noteHoldReleasedByGround(t0);
      expect(late.decidePhaseMessage('none', 'crossed',
              t0.add(const Duration(seconds: 6))), isNull);

      final once = FeedbackService()..noteHoldReleasedByGround(t0);
      expect(once.decidePhaseMessage('none', 'crossed',
              t0.add(const Duration(seconds: 1))), '횡단보도를 건넜습니다.');
      expect(once.decidePhaseMessage('none', 'crossed',
              t0.add(const Duration(seconds: 9))), isNull,
          reason: '3초 재쿨다운이 지나도 창은 이미 비었다');
    });

    test('hold 일찍 해제 뒤 다시 위로 들어오면 창을 비운다 (T118)', () {
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      final s = FeedbackService()..noteHoldReleasedByGround(t0);
      s.decidePhaseMessage('none', 'front', t0.add(const Duration(seconds: 1)));
      expect(s.decidePhaseMessage('none', 'crossed',
              t0.add(const Duration(seconds: 2))), isNull);
    });

    // T93: none(또는 콜드스타트) -> approach는 "앞에 횡단보도".
    test('none/콜드스타트 -> approach는 앞에 횡단보도 안내를 낸다 (T93)', () {
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      expect(FeedbackService().decidePhaseMessage('none', 'approach', t0),
          '앞에 횡단보도');
      expect(FeedbackService().decidePhaseMessage('', 'approach', t0),
          '앞에 횡단보도',
          reason: '앱을 켰을 때 이미 앞에 횡단보도가 있으면 알려야 한다');
    });

    // T93: 건넌 직후 approach 오검출(실기기 #10)에 "앞에 횡단보도"를 말하면
    // 안 되므로, 횡단보도 위 -> approach는 침묵한다.
    test('front/left/right -> approach는 안내하지 않는다 (T93)', () {
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      for (final on in ['front', 'left', 'right']) {
        expect(FeedbackService().decidePhaseMessage(on, 'approach', t0), isNull,
            reason: '$on -> approach');
      }
    });

    test('approach에 머무는 동안 반복하지 않는다 (T93)', () {
      final service = FeedbackService();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      expect(service.decidePhaseMessage('none', 'approach', t0), isNotNull);
      expect(
          service.decidePhaseMessage(
              'approach', 'approach', t0.add(const Duration(seconds: 10))),
          isNull);
    });

    test('그 외 전이는 안내하지 않는다', () {
      final service = FeedbackService();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      expect(service.decidePhaseMessage('approach', 'none', t0), isNull);
      expect(service.decidePhaseMessage('front', 'left', t0), isNull);
      expect(service.decidePhaseMessage('left', 'right', t0), isNull);
      expect(
        service.decidePhaseMessage('', 'front', t0),
        isNull,
        reason: '콜드 스타트(직전 클래스 없음)는 진입으로 보지 않는다',
      );
    });

    test('같은 전이가 3초 안에 반복되면(떨림) 억제한다', () {
      final service = FeedbackService();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      final first = service.decidePhaseMessage('approach', 'front', t0);
      expect(first, isNotNull);

      final flicker = service.decidePhaseMessage(
        'approach',
        'front',
        t0.add(const Duration(seconds: 2)),
      );
      expect(flicker, isNull);

      final after = service.decidePhaseMessage(
        'approach',
        'front',
        t0.add(const Duration(seconds: 3)),
      );
      expect(after, isNotNull);
    });

    // T123(사용자 결정 2026-10-21): 3초 재쿨다운은 같은 문장끼리만.
    // 10/21 기록: "앞에 횡단보도" 뒤 0.87~2.87초 만에 위로 들어오면 "진입했습니다"가
    // 요청조차 되지 않았다(10번 중 8번).
    test('앞에 횡단보도 직후 진입은 3초 안이어도 안내한다 (T123)', () {
      final s = FeedbackService();
      final t0 = DateTime(2026, 10, 21, 17, 15, 0);
      final ko = AppStrings.of(AppLanguage.ko);
      expect(s.decidePhaseMessage('none', 'approach', t0),
          ko.approachAheadMessage);
      expect(
          s.decidePhaseMessage(
              'approach', 'front', t0.add(const Duration(milliseconds: 870))),
          ko.enteredCrosswalkMessage);
    });

    test('진입 직후 건넘도 서로 막지 않는다 (T123)', () {
      final s = FeedbackService();
      final t0 = DateTime(2026, 10, 21, 17, 15, 0);
      final ko = AppStrings.of(AppLanguage.ko);
      expect(s.decidePhaseMessage('approach', 'left', t0),
          ko.enteredCrosswalkMessage);
      expect(
          s.decidePhaseMessage(
              'front', 'crossed', t0.add(const Duration(seconds: 1))),
          ko.crossedCrosswalkMessage);
    });

    test('같은 문장은 여전히 3초 안에 다시 말하지 않는다 (T123)', () {
      final s = FeedbackService();
      final t0 = DateTime(2026, 10, 21, 17, 15, 0);
      final ko = AppStrings.of(AppLanguage.ko);
      expect(s.decidePhaseMessage('none', 'approach', t0),
          ko.approachAheadMessage);
      expect(
          s.decidePhaseMessage(
              'approach', 'front', t0.add(const Duration(seconds: 1))),
          ko.enteredCrosswalkMessage);
      // 떨림: approach -> none -> approach -> front 가 3초 안에 다시 일어남.
      expect(
          s.decidePhaseMessage(
              'none', 'approach', t0.add(const Duration(seconds: 2))),
          isNull);
      expect(
          s.decidePhaseMessage(
              'approach', 'front', t0.add(const Duration(milliseconds: 2500))),
          isNull);
      expect(
          s.decidePhaseMessage(
              'approach', 'front', t0.add(const Duration(milliseconds: 4000))),
          ko.enteredCrosswalkMessage);
    });

    testWidgets('alert(): none -> approach -> front가 바로 이어져도 진입 요청 (T123)',
        (tester) async {
      EventLog.instance.clearForTest();
      final ko = AppStrings.of(AppLanguage.ko);
      final s = FeedbackService();
      await s.alert('none', 0.9);
      await s.alert('approach', 0.9);
      await s.alert('front', 0.9);
      final says = EventLog.instance.earlyLines
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .where((m) => m['ev'] == 'say')
          .map((m) => m['text'])
          .toList();
      expect(says, [ko.approachAheadMessage, ko.enteredCrosswalkMessage]);
      await _disposeIn(tester, s);
    });
  });

  // T63: 이탈에서 회복했을 때만 1회 발화. 처음부터 똑바로 가는 경우
  // (previousClass가 'left'/'right'가 아님)는 항상 null이어야 한다.
  group('FeedbackService.decideRecoveryMessage — 회복 안내 (T63)', () {
    test('left/right -> front에서만 발화한다', () {
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      final fromLeft = FeedbackService();
      expect(fromLeft.decideRecoveryMessage('left', 'front', t0), '직진하세요');

      final fromRight = FeedbackService();
      expect(fromRight.decideRecoveryMessage('right', 'front', t0), '직진하세요');
    });

    test('처음부터 front였다면 발화하지 않는다', () {
      final service = FeedbackService();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      expect(service.decideRecoveryMessage('front', 'front', t0), isNull);
      expect(service.decideRecoveryMessage('', 'front', t0), isNull);
      expect(service.decideRecoveryMessage('approach', 'front', t0), isNull);
    });

    test('front가 아닌 상태로의 전이는 발화하지 않는다', () {
      final service = FeedbackService();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      expect(service.decideRecoveryMessage('left', 'right', t0), isNull);
      expect(service.decideRecoveryMessage('left', 'none', t0), isNull);
    });

    test('짧은 시간 안의 반복(떨림)은 억제한다', () {
      final service = FeedbackService();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      final first = service.decideRecoveryMessage('left', 'front', t0);
      expect(first, isNotNull);

      final flicker = service.decideRecoveryMessage(
        'left',
        'front',
        t0.add(const Duration(seconds: 1)),
      );
      expect(flicker, isNull);
    });
  });

  // Reviewer fix (Major): isSpeaking/isVibrating race-condition regression
  // tests. alert() itself entangles real flutter_tts/vibration platform
  // channels (see file header), and `Vibration.hasVibrator()` short-circuits
  // to `false` in the flutter_tester host environment regardless of any
  // mocking (it gates on `Platform.isAndroid`/`Platform.isIOS`, both false
  // on a desktop test host), so the vibration branch of alert() never runs
  // under `flutter test`. These tests instead exercise the exact guarded
  // state-transition helpers (`beginSpeechGeneration`/`finishSpeechGeneration`,
  // `activateVibrationIndicator`) that alert() calls internally to fix the
  // race — same code path, called directly instead of through the plugin
  // gate.
  group('FeedbackService — isVibrating race guard', () {
    test(
        'a single activation resets isVibrating to false after the '
        'vibration duration', () async {
      final service = FeedbackService();

      service.activateVibrationIndicator();
      expect(service.isVibrating.value, isTrue);

      // _vibrationDurationMs is 500ms; wait comfortably past it.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(service.isVibrating.value, isFalse);
    });

    test(
      'an earlier timer does not prematurely clear a later activation '
      '(rapid class-change scenario)',
      () async {
        final service = FeedbackService();

        // Simulates alert('left') immediately followed by alert('right')
        // within the 500ms vibration window (decideMessage bypasses the
        // cooldown on a class change, so this can happen in production).
        service.activateVibrationIndicator();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        service.activateVibrationIndicator();

        // 350ms after the second activation (550ms after the first): the
        // first call's timer would have fired at 500ms if it had not been
        // cancelled, incorrectly clearing the second activation's state.
        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect(
          service.isVibrating.value,
          isTrue,
          reason: 'the first activation\'s timer must have been cancelled by '
              'the second activateVibrationIndicator() call',
        );

        // The second activation's own timer still fires ~150ms later.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(service.isVibrating.value, isFalse);
      },
    );
  });

  group('FeedbackService — isSpeaking race guard', () {
    test(
        'finishSpeechGeneration resets isSpeaking when it is the current '
        'generation', () {
      final service = FeedbackService();

      final generation = service.beginSpeechGeneration();
      expect(service.isSpeaking.value, isTrue);

      service.finishSpeechGeneration(generation);
      expect(service.isSpeaking.value, isFalse);
    });

    test(
      'a stale completion from an earlier call does not clear a newer '
      'call\'s isSpeaking (rapid class-change scenario)',
      () {
        final service = FeedbackService();

        // Simulates alert('left') starting speech, then alert('right')
        // starting a new utterance before the first one's completion
        // handler has fired.
        final firstGeneration = service.beginSpeechGeneration();
        final secondGeneration = service.beginSpeechGeneration();
        expect(service.isSpeaking.value, isTrue);

        // The first utterance's stale completion handler fires late — it
        // must not clear the second (current) utterance's isSpeaking.
        service.finishSpeechGeneration(firstGeneration);
        expect(
          service.isSpeaking.value,
          isTrue,
          reason: 'a stale handler for an older generation must not reset a '
              'newer, still-active speech',
        );

        // The second utterance's own completion handler correctly clears it.
        service.finishSpeechGeneration(secondGeneration);
        expect(service.isSpeaking.value, isFalse);
      },
    );
  });

  // T39: runtime setters used by SettingsScreen (language / TTS speed /
  // vibration duration), applied for the remainder of the session.
  group('FeedbackService — T39 runtime setters', () {
    test('defaults match the pre-T39 hardcoded values', () {
      final service = FeedbackService();

      expect(service.language, AppLanguage.ko);
      expect(service.speechRate, 0.5);
      expect(service.vibrationDurationMs, 500);
    });

    test(
        'updateVibrationDuration changes vibrationDurationMs immediately '
        'without touching any platform channel', () {
      final service = FeedbackService();

      service.updateVibrationDuration(800);

      expect(service.vibrationDurationMs, 800);
    });

    test('updateSpeechRate changes speechRate', () async {
      final service = FeedbackService();

      await service.updateSpeechRate(0.8);

      expect(service.speechRate, 0.8);
    });

    test(
      'updateLanguage changes language, and subsequent decideMessage() '
      'calls use the new language\'s deviation messages',
      () async {
        final service = FeedbackService();
        final t0 = DateTime(2026, 1, 1, 12, 0, 0);

        // Before switching: Korean (default).
        expect(service.decideMessage('left', mild, t0), leftMild);

        await service.updateLanguage(AppLanguage.en);
        expect(service.language, AppLanguage.en);

        // A class change ('left' -> 'right') bypasses cooldown, so this
        // is reachable immediately after the prior Korean alert above.
        final englishMessage = service.decideMessage(
          'right',
          mild,
          t0.add(const Duration(milliseconds: 1)),
        );
        expect(
          englishMessage,
          AppStrings.of(AppLanguage.en).rightDeviationMessageMild,
        );
      },
    );
  });

  group('FeedbackService — 끝 안내 (T102)', () {
    final t0 = DateTime(2026, 9, 27, 12, 0, 0);

    test('끝이면 끝 전용 문구(B안)를 낸다', () {
      expect(FeedbackService().decideMessage('left', 20, t0, atEdge: true),
          '오른쪽으로 가세요. 가장자리입니다');
      expect(FeedbackService().decideMessage('right', -20, t0, atEdge: true),
          '왼쪽으로 가세요. 가장자리입니다');
    });

    test('끝이 아니면 기존 문구 그대로', () {
      expect(FeedbackService().decideMessage('left', mild, t0), leftMild);
      expect(FeedbackService().decideMessage('right', -severe, t0),
          rightSevere);
    });

    test('같은 방향이라도 일반 이탈 -> 끝으로 바뀌면 쿨다운 안에서도 즉시 안내', () {
      final service = FeedbackService();
      expect(service.decideMessage('left', mild, t0), leftMild);
      expect(
        service.decideMessage('left', 20, t0.add(const Duration(seconds: 1)),
            atEdge: true),
        '오른쪽으로 가세요. 가장자리입니다',
      );
      // 끝이 유지되면 쿨다운이 다시 걸린다.
      expect(
        service.decideMessage('left', 20, t0.add(const Duration(seconds: 2)),
            atEdge: true),
        isNull,
      );
    });

    test('끝에서 이미 튼 front면 회복 안내("직진하세요")는 침묵', () {
      expect(
        FeedbackService()
            .decideRecoveryMessage('left', 'front', t0, atEdge: true),
        isNull,
      );
    });

    test('끝에서 이미 튼 front로 들어올 때 "그대로 가세요" 1회', () {
      final service = FeedbackService();
      expect(service.decideEdgeTurnedMessage('left', t0, atEdge: true),
          isNull);
      expect(
        service.decideEdgeTurnedMessage(
            'front', t0.add(const Duration(seconds: 1)),
            atEdge: true),
        '그대로 가세요',
      );
      // 머무는 동안은 반복하지 않는다(쿨다운이 지나도).
      expect(
        service.decideEdgeTurnedMessage(
            'front', t0.add(const Duration(seconds: 10)),
            atEdge: true),
        isNull,
      );
    });

    test('중앙에서의 front는 "그대로 가세요"를 내지 않는다', () {
      expect(
        FeedbackService().decideEdgeTurnedMessage('front', t0, atEdge: false),
        isNull,
      );
    });

    test('경계에서 떨리면 3초 안의 재진입은 침묵, 이후 재진입은 안내', () {
      final service = FeedbackService();
      expect(service.decideEdgeTurnedMessage('front', t0, atEdge: true),
          '그대로 가세요');
      service.decideEdgeTurnedMessage(
          'left', t0.add(const Duration(seconds: 1)),
          atEdge: true);
      expect(
        service.decideEdgeTurnedMessage(
            'front', t0.add(const Duration(seconds: 2)),
            atEdge: true),
        isNull,
      );
      service.decideEdgeTurnedMessage(
          'left', t0.add(const Duration(seconds: 5)),
          atEdge: true);
      expect(
        service.decideEdgeTurnedMessage(
            'front', t0.add(const Duration(seconds: 6)),
            atEdge: true),
        '그대로 가세요',
      );
    });
  });

  // T104: 차도 진동은 짧게 3번 — 기존 좌(2번)·우(1번 길게)·복귀(1번)와 겹치지 않는다.
  test('surfaceRoadPattern: 짧게 3번 (T104)', () {
    final p = FeedbackService.surfaceRoadPattern(125);
    expect(p, [0, 125, 125, 125, 125, 125]);
    // [대기, 켜짐, 꺼짐, 켜짐, 꺼짐, 켜짐] -> 켜짐 3번
    expect([for (var i = 1; i < p.length; i += 2) p[i]].length, 3);
  });

  // T106: 진동 기록 — 앱이 요청한 패턴을 그대로 남긴다.
  group('FeedbackService — 진동 기록 (T106)', () {
    test('패턴 지원 기기: 요청한 패턴 그대로', () {
      final d = FeedbackService.vibrationLogData('left', [0, 125, 125, 125],
          hasVibrator: true, supportsPattern: true, fallbackMs: 500);
      expect(d, {
        'kind': 'left',
        'ok': true,
        'mode': 'pattern',
        'pat': [0, 125, 125, 125],
      });
    });

    test('패턴 미지원 기기: 실제로 나간 단일 진동 길이', () {
      final d = FeedbackService.vibrationLogData('road', [0, 125, 125, 125],
          hasVibrator: true, supportsPattern: false, fallbackMs: 500);
      expect(d['mode'], 'single');
      expect(d['pat'], [0, 500]);
    });

    test('T132: 방향 진동이면 단계(lvl)와 적용 간격(gap ms)을 붙인다', () {
      final d = FeedbackService.vibrationLogData('right', [0, 500],
          hasVibrator: true,
          supportsPattern: true,
          fallbackMs: 500,
          level: 2,
          gapMs: 1000);
      expect(d['lvl'], 2);
      expect(d['gap'], 1000);
      final n = FeedbackService.vibrationLogData('left', [0, 125, 125, 125],
          hasVibrator: false,
          supportsPattern: false,
          fallbackMs: 500,
          level: 1,
          gapMs: 1500);
      expect(n, {
        'kind': 'left',
        'ok': false,
        'why': 'no_vibrator',
        'lvl': 1,
        'gap': 1500
      });
    });

    test('T132: alert()는 이번 프레임 단계로 진동 간격을 정하고 기록한다', () async {
      // 테스트 호스트는 진동기가 없다(ok=false) — 단계·간격이 기록되는지만 본다.
      EventLog.instance.clearForTest();
      final s = FeedbackService();
      await s.alert('right', 0.9, angleDegrees: -20, atEdge: true);
      expect(s.vibrationPolicy.lastLevel, 2);
      // 같은 방향, 단계가 내려감(가장자리 → 보통): 음성은 묶여도 진동 간격은 바로 3초.
      await s.alert('right', 0.9, angleDegrees: -mild);
      expect(s.vibrationPolicy.lastLevel, 0);
      expect(s.vibrationPolicy.lastInterval, const Duration(seconds: 3));
      final vib = EventLog.instance.earlyLines
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .where((m) => m['ev'] == 'vib')
          .toList();
      expect(vib.first['kind'], 'right');
      expect(vib.first['lvl'], 2);
      expect(vib.first['gap'], 1000);
      await s.dispose();
    });

    test('진동기가 없으면 ok=false와 이유', () {
      final d = FeedbackService.vibrationLogData('recover', [0, 125],
          hasVibrator: false, supportsPattern: false, fallbackMs: 500);
      expect(d, {'kind': 'recover', 'ok': false, 'why': 'no_vibrator'});
    });

    test('surfaceAlert(블록 위)는 진동 요청을 기록에 남긴다', () async {
      // 테스트 호스트는 진동기가 없다고 답한다(위 race guard 주석) — 그래서
      // ok=false 줄이 남는다. 기록 지점이 진동 경로에 붙어 있는지를 확인한다.
      EventLog.instance.clearForTest();
      await FeedbackService().surfaceAlert([SurfaceEvent.linearOn]);
      final vib = EventLog.instance.earlyLines
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .where((m) => m['ev'] == 'vib')
          .toList();
      expect(vib, hasLength(1));
      expect(vib.single['kind'], 'line_on');
    });
  });

  // T40: OnboardingScreen's general-purpose read-aloud, reusing _speak().
  group('FeedbackService.decideHeldRecovery — 회복 안내 보류 (T108 Q1)', () {
    final t0 = DateTime(2026, 10, 12, 12, 0, 0);
    Duration ms(int v) => Duration(milliseconds: v);

    test('front가 0.7초 안 됐으면 기다린다', () {
      expect(
          FeedbackService().decideHeldRecovery('front', t0, t0.add(ms(500)),
              deviationPlaying: false),
          HeldRecoveryVerdict.wait);
    });

    test('front가 0.7초 유지되고 이탈 경고가 없으면 말한다', () {
      expect(
          FeedbackService().decideHeldRecovery('front', t0, t0.add(ms(700)),
              deviationPlaying: false),
          HeldRecoveryVerdict.speak);
    });

    test('이탈 경고가 재생 중이면 끊지 않고 기다린다', () {
      expect(
          FeedbackService().decideHeldRecovery('front', t0, t0.add(ms(1000)),
              deviationPlaying: true),
          HeldRecoveryVerdict.wait);
    });

    test('기다리다 2.7초가 넘으면 버린다', () {
      expect(
          FeedbackService().decideHeldRecovery('front', t0, t0.add(ms(2800)),
              deviationPlaying: true),
          HeldRecoveryVerdict.expire);
    });

    test('front가 아니게 되면(깜빡임) 취소한다', () {
      for (final c in ['left', 'right', 'none', 'approach']) {
        expect(
            FeedbackService().decideHeldRecovery(c, t0, t0.add(ms(300)),
                deviationPlaying: false),
            HeldRecoveryVerdict.cancel,
            reason: c);
      }
    });
  });

  group('FeedbackService.supersedesDotBlock — 연석 겹침 (T108 Q3)', () {
    final s = AppStrings.of(AppLanguage.ko);

    bool sup(String m, String? active) => FeedbackService.supersedesDotBlock(
        m, active,
        approachMessage: s.approachAheadMessage,
        dotBlockMessage: s.surfaceDotBlockMessage);

    test('앞에 횡단보도는 재생 중인 멈춤 블록을 대체한다', () {
      expect(sup(s.approachAheadMessage, s.surfaceDotBlockMessage), isTrue);
    });

    test('그 밖의 조합은 대체하지 않는다', () {
      expect(sup(s.approachAheadMessage, null), isFalse);
      expect(sup(s.crossedCrosswalkMessage, s.surfaceDotBlockMessage), isFalse);
      expect(sup(s.approachAheadMessage, s.crossedCrosswalkMessage), isFalse);
    });
  });

  group('FeedbackService.cautionMessage — 주의 구역 문구 (T105)', () {
    final s = AppStrings.of(AppLanguage.ko);

    test('하나면 그 문구', () {
      expect(FeedbackService.cautionMessage([CautionEvent.manholeGrating], s), '발밑 주의');
      expect(FeedbackService.cautionMessage([CautionEvent.treeZone], s), '가로수');
    });

    test('같은 판정에서 둘 다면 C1 -> C2 차례로 한 문장 (C8)', () {
      expect(
          FeedbackService.cautionMessage(
              [CautionEvent.treeZone, CautionEvent.manholeGrating], s),
          '발밑 주의. 가로수');
    });

    test('없으면 null', () {
      expect(FeedbackService.cautionMessage(const [], s), isNull);
    });
  });

  group('FeedbackService — speak (T40)', () {
    test('drives the same isSpeaking generation guard as alert()', () async {
      final service = FeedbackService();

      final future = service.speak('테스트 안내 문구');
      // beginSpeechGeneration() runs synchronously before any await, so
      // isSpeaking must already be true right after speak() is called.
      expect(service.isSpeaking.value, isTrue);

      await future;
      expect(service.isSpeaking.value, isFalse);
    });
  });

  // T118: 대기 꺼내기 타이머 여유 — 조금 일찍 울려 헛도는 것을 막는다.
  group('대기 꺼내기 타이머 (T118)', () {
    final t0 = DateTime(2026, 10, 19, 16, 54, 0);
    test('간격 끝까지 남은 시간에 20ms를 더한다', () {
      expect(FeedbackService.drainMargin, const Duration(milliseconds: 20));
      expect(
          FeedbackService.drainDelay(
              t0.add(const Duration(milliseconds: 500)), t0),
          const Duration(milliseconds: 520));
    });
    test('µs만 남았어도 20ms 넘게 기다린다 (10/19 L3471 반복)', () {
      final d = FeedbackService.drainDelay(
          t0.add(const Duration(microseconds: 300)), t0);
      expect(d > const Duration(milliseconds: 20), isTrue);
    });
    test('이미 지났거나 직전 발화가 없으면 20ms', () {
      expect(FeedbackService.drainDelay(t0, t0),
          const Duration(milliseconds: 20));
      expect(FeedbackService.drainDelay(null, t0),
          const Duration(milliseconds: 20));
    });
  });

  // T118(사용자 확정 A): 횡단보도 없음에서 멈춤 블록은 1.3초 보류.
  group('멈춤 블록 보류 (T118)', () {
    test('보류 시간은 1.3초', () {
      expect(FeedbackService.dotBlockHold, const Duration(milliseconds: 1300));
    });
    test('횡단보도 없음·콜드스타트에서만 보류한다', () {
      expect(FeedbackService.holdsDotBlock('none'), isTrue);
      expect(FeedbackService.holdsDotBlock(''), isTrue);
      for (final c in ['crossed', 'approach', 'front', 'left', 'right']) {
        expect(FeedbackService.holdsDotBlock(c), isFalse, reason: c);
      }
    });
  });

  // T118 보완(리뷰 4): 보류·대기 타이머 동작을 고정한다. testWidgets의 가짜 시계로
  // 타이머를 돌린다(서비스 안의 DateTime.now()는 실제 시각 그대로).
  group('멈춤 블록 보류·대기 타이머 (T118 보완)', () {
    final ko = AppStrings.of(AppLanguage.ko);
    final dotBlock = ko.surfaceDotBlockMessage;
    final approach = ko.approachAheadMessage;

    List<Map<String, dynamic>> logged(String ev, String text) =>
        EventLog.instance.earlyLines
            .map((l) => jsonDecode(l) as Map<String, dynamic>)
            .where((m) => m['ev'] == ev && m['text'] == text)
            .toList();

    testWidgets('(a) 횡단보도 없음에서 블록은 1.3초 뒤 발화', (tester) async {
      EventLog.instance.clearForTest();
      final s = FeedbackService();
      await s.alert('none', 0.9);
      await s.surfaceAlert([SurfaceEvent.dotBlock]);
      expect(logged('say.defer', dotBlock), hasLength(1));
      await tester.pump(const Duration(milliseconds: 1200));
      expect(logged('say', dotBlock), isEmpty, reason: '1.3초 전에는 침묵');
      await tester.pump(const Duration(milliseconds: 200));
      expect(logged('say', dotBlock), hasLength(1));
      expect(logged('say', dotBlock).single['act'], 'speakNow');
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets("(b) 보류 중 none -> approach면 블록 취소, '앞에 횡단보도'만",
        (tester) async {
      EventLog.instance.clearForTest();
      final s = FeedbackService();
      await s.alert('none', 0.9);
      await s.surfaceAlert([SurfaceEvent.dotBlock]);
      await tester.pump(const Duration(milliseconds: 500));
      await s.alert('approach', 0.9);
      await tester.pump(const Duration(seconds: 2));
      expect(logged('say', dotBlock), isEmpty);
      expect(logged('say.cancel', dotBlock).single['why'], 'superseded');
      expect(logged('say', approach), hasLength(1));
    });

    testWidgets('(c) 보류 중 front로 바뀌면 발화하지 않는다', (tester) async {
      EventLog.instance.clearForTest();
      final s = FeedbackService();
      await s.alert('none', 0.9);
      await s.surfaceAlert([SurfaceEvent.dotBlock]);
      await tester.pump(const Duration(milliseconds: 500));
      await s.alert('front', 0.9);
      await tester.pump(const Duration(seconds: 2));
      expect(logged('say', dotBlock), isEmpty);
      expect(logged('say.cancel', dotBlock).single['why'], 'state');
    });

    testWidgets('(d) 마지막 상태가 위(front, hold 중 포함)·crossed면 즉시 발화',
        (tester) async {
      // hold 동안에는 alert가 불리지 않아 마지막 상태가 front로 남는다.
      for (final last in ['front', 'crossed']) {
        EventLog.instance.clearForTest();
        final s = FeedbackService();
        await s.alert(last, 0.9);
        await s.surfaceAlert([SurfaceEvent.dotBlock]);
        expect(logged('say.defer', dotBlock), isEmpty, reason: last);
        expect(logged('say', dotBlock), hasLength(1), reason: last);
        await tester.pump(const Duration(seconds: 2));
      }
    });

    testWidgets('(e) dispose는 보류 타이머를 취소한다', (tester) async {
      EventLog.instance.clearForTest();
      final s = FeedbackService();
      await s.alert('none', 0.9);
      await s.surfaceAlert([SurfaceEvent.dotBlock]);
      await s.dispose();
      await tester.pump(const Duration(seconds: 2));
      expect(logged('say', dotBlock), isEmpty);
    });

    testWidgets(
        "(f) front -> 일찍 해제 -> none -> crossed가 hold 시작 10초 안이면 '건넜습니다'",
        (tester) async {
      EventLog.instance.clearForTest();
      final s = FeedbackService();
      await s.alert('front', 0.9);
      // hold 시작 8초 뒤가 지금, 해제는 6초 전 — 해제 + 5초는 이미 지났다.
      final now = DateTime.now();
      s.noteHoldReleasedByGround(now.subtract(const Duration(seconds: 6)),
          holdStartedAt: now.subtract(const Duration(seconds: 8)));
      await s.alert('none', 0.9);
      await s.alert('crossed', 0.9);
      expect(logged('say', ko.crossedCrosswalkMessage), hasLength(1));
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('(g) 대기 칸이 찬 상태에서 같은 안내는 한 번만 대기로 기록된다',
        (tester) async {
      // 최소 간격은 실제 시각으로 재므로, 이 시험은 실제 시간으로 돌린다.
      await tester.runAsync(() async {
        EventLog.instance.clearForTest();
        final s = FeedbackService();
        await s.alert('front', 0.9); // 블록을 바로 처리하는 상태
        await s.surfaceAlert([SurfaceEvent.dotBlock]); // 재생
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await s.surfaceAlert([SurfaceEvent.dotBlock]); // 최소 간격 -> 대기
        await s.surfaceAlert([SurfaceEvent.dotBlock]); // 칸이 참 -> 버림
        await Future<void>.delayed(const Duration(milliseconds: 1800));
        final says = logged('say', dotBlock);
        expect(says.where((m) => m['act'] == 'queue'), hasLength(1));
        expect(says.where((m) => m['why'] == 'slot_full'), hasLength(1));
        expect(says.where((m) => m['act'] == 'speakNow'), hasLength(2),
            reason: '처음 1번 + 대기에서 꺼낸 1번');
        expect(says, hasLength(4));
      });
    });
  });

  // T133(사용자 승인 안 A): 서 있으면 같은 방향 음성 반복 대신 진동만.
  group('서 있을 때 같은 방향 반복 생략 (T133)', () {
    final t0 = DateTime(2026, 10, 25, 18, 9, 35);
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));
    const severe = 30.0;

    /// [fromMs]~[toMs] 동안 가만히 선 가속도(중력만)를 66ms마다 넣는다.
    void stand(FeedbackService s, int fromMs, int toMs) {
      for (var ms = fromMs; ms <= toMs; ms += 66) {
        s.stillness.add(0, 0, 9.81, at(ms));
      }
    }

    List<Map<String, dynamic>> cancels() => EventLog.instance.earlyLines
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .where((m) => m['ev'] == 'say.cancel')
        .toList();

    test('서 있으면 6초 재경고를 말하지 않는다(say.cancel why=still)', () {
      EventLog.instance.clearForTest();
      final s = FeedbackService();
      stand(s, -3000, 0);
      expect(s.decideMessage('left', mild, at(0)), leftMild, reason: '첫 경고는 말함');
      stand(s, 66, 6500);
      expect(s.decideMessage('left', mild, at(6500)), isNull);
      expect(cancels().last, containsPair('why', 'still'));
      expect(cancels().last['text'], leftMild);
      // 진동은 그대로 — 진동 정책은 서 있음과 무관하다.
      expect(s.vibrationPolicy.decidePattern('left', at(0), 500), isNotNull);
      expect(s.vibrationPolicy.decidePattern('left', at(3100), 500), isNotNull);
    });

    test('서 있지 않으면 6초 재경고는 종전대로 말한다', () {
      final s = FeedbackService();
      expect(s.decideMessage('left', mild, at(0)), leftMild);
      expect(s.decideMessage('left', mild, at(6500)), leftMild);
    });

    test('서 있어도 단계가 오르면 말한다', () {
      final s = FeedbackService();
      stand(s, -3000, 0);
      expect(s.decideMessage('left', mild, at(0)), leftMild);
      stand(s, 66, 7000);
      expect(s.decideMessage('left', severe, at(7000)), leftSevere);
    });

    test('서 있어도 방향이 바뀌면 말한다', () {
      final s = FeedbackService();
      stand(s, -3000, 0);
      expect(s.decideMessage('left', mild, at(0)), leftMild);
      stand(s, 66, 2000);
      expect(s.decideMessage('right', mild, at(2000)), rightMild);
    });

    test('서 있어도 회복(front 0.7초 이상) 뒤 새 이탈은 첫 경고로 말한다', () {
      final s = FeedbackService();
      stand(s, -3000, 0);
      expect(s.decideMessage('left', mild, at(0)), leftMild);
      stand(s, 66, 9000);
      s.decideMessage('front', null, at(7000));
      s.decideMessage('front', null, at(7800));
      expect(s.decideMessage('left', mild, at(9000)), leftMild);
    });

    test('센서가 멈추면 서 있음으로 보지 않는다 — 재경고를 말한다', () {
      final s = FeedbackService();
      stand(s, -3000, 0);
      expect(s.decideMessage('left', mild, at(0)), leftMild);
      expect(s.decideMessage('left', mild, at(6500)), leftMild,
          reason: '마지막 표본이 6.5초 전');
    });

    test('addAccelerometer: 서 있음이 바뀌면 still 기록(on, mot)', () {
      EventLog.instance.clearForTest();
      final s = FeedbackService();
      for (var ms = 0; ms <= 3000; ms += 66) {
        s.addAccelerometer(0, 0, 9.81, at(ms));
      }
      for (var ms = 3066; ms <= 4000; ms += 66) {
        s.addAccelerometer(0, 0, ms % 132 == 0 ? 12.0 : 7.6, at(ms));
      }
      final still = EventLog.instance.earlyLines
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .where((m) => m['ev'] == 'still')
          .toList();
      expect(still.map((m) => m['on']), [true, false]);
      expect(still.first['mot'], lessThan(StillnessDetector.stillThreshold));
      expect(still.last['mot'],
          greaterThanOrEqualTo(StillnessDetector.moveThreshold));
    });
  });

  // T118 보완(리뷰 3-a): 일찍 해제 뒤 '건넜습니다' 창 =
  // hold 시작 + 10초와 해제 + 5초 중 늦은 쪽.
  group('일찍 해제 뒤 건넘 안내 창 (T118 보완)', () {
    final t0 = DateTime(2026, 10, 20, 12, 0, 0);
    Duration sec(num v) => Duration(milliseconds: (v * 1000).round());
    String? crossedAt(num releaseS, num crossedS) {
      final s = FeedbackService()
        ..noteHoldReleasedByGround(t0.add(sec(releaseS)), holdStartedAt: t0);
      return s.decidePhaseMessage('none', 'crossed', t0.add(sec(crossedS)));
    }

    test('hold 시작 창은 CrossingHold 유지 시간과 같은 10초', () {
      expect(FeedbackService.holdStartCrossedWindow, CrossingHold.holdDuration);
    });

    test('3초에 일찍 풀려도 hold 시작 10초 안의 crossed는 안내 (회귀 복원)', () {
      expect(crossedAt(3, 9), '횡단보도를 건넜습니다.', reason: '해제 + 5초(8초)는 지났다');
      expect(crossedAt(3, 10), '횡단보도를 건넜습니다.');
      expect(crossedAt(3, 10.5), isNull);
    });

    test('늦게 풀리면 해제 + 5초가 더 길다 (A2 그대로)', () {
      expect(crossedAt(8, 12.5), '횡단보도를 건넜습니다.');
      expect(crossedAt(8, 13.5), isNull);
    });

    test('늦은 쪽을 고른다', () {
      expect(FeedbackService.groundReleaseCrossedUntil(t0.add(sec(3)), t0),
          t0.add(sec(10)));
      expect(FeedbackService.groundReleaseCrossedUntil(t0.add(sec(8)), t0),
          t0.add(sec(13)));
      expect(FeedbackService.groundReleaseCrossedUntil(t0.add(sec(3)), null),
          t0.add(sec(8)));
    });
  });

  // T120(사용자 확정 2026-10-20): 같은 방향 이탈 재경고 6초 묶음.
  // 단계 = 가장자리 2 > 즉시 1 > 보통 0. 마지막으로 '말한' 단계와 비교한다.
  // 시각을 인자로 받는 순수 판정이라 타이머가 없다 — 가짜 시계 대신 시각을 직접 준다.
  group('같은 방향 이탈 묶음 (T120)', () {
    const leftEdge = '오른쪽으로 가세요. 가장자리입니다';
    const rightEdge = '왼쪽으로 가세요. 가장자리입니다';
    final t0 = DateTime(2026, 10, 20, 12, 0, 0);
    Duration ms(int v) => Duration(milliseconds: v);

    List<Map<String, dynamic>> bundled() => EventLog.instance.earlyLines
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .where((m) => m['ev'] == 'say.cancel' && m['why'] == 'same_dir')
        .toList();

    test('단계: 가장자리 2 > 즉시 1 > 보통 0 (가장자리면 강도 무관)', () {
      expect(FeedbackService.deviationLevel(severe: false, atEdge: false), 0);
      expect(FeedbackService.deviationLevel(severe: true, atEdge: false), 1);
      expect(FeedbackService.deviationLevel(severe: false, atEdge: true), 2);
      expect(FeedbackService.deviationLevel(severe: true, atEdge: true), 2);
      expect(FeedbackService.sameDirectionBundle, const Duration(seconds: 6));
    });

    test('행1: 6초 안 같은 단계는 생략 (3초 재경고 없음)', () {
      final s = FeedbackService();
      expect(s.decideMessage('left', mild, t0), leftMild);
      for (final at in [1000, 3000, 4500, 5999]) {
        expect(s.decideMessage('left', mild, t0.add(ms(at))), isNull,
            reason: '${at}ms');
      }
    });

    test('행1: 6초 안 내려감(가장자리 -> 보통, 가장자리 -> 즉시, 즉시 -> 보통)은 생략',
        () {
      final s = FeedbackService();
      expect(s.decideMessage('left', 20, t0, atEdge: true), leftEdge);
      expect(s.decideMessage('left', mild, t0.add(ms(500))), isNull);
      expect(s.decideMessage('left', severe, t0.add(ms(1000))), isNull);

      final s2 = FeedbackService();
      expect(s2.decideMessage('right', -severe, t0), rightSevere);
      // 래치가 2초 뒤 약함으로 내려가도 묶음 안이다.
      expect(s2.decideMessage('right', -mild, t0.add(ms(500))), isNull);
      expect(s2.decideMessage('right', -mild, t0.add(ms(2600))), isNull);
      expect(s2.isSevere, isFalse);
    });

    test('행1: 가장자리 -> 보통 -> 가장자리 떨림은 한 번만 (10/19 L4867~L4903)', () {
      final s = FeedbackService();
      expect(s.decideMessage('left', 20, t0, atEdge: true), leftEdge);
      expect(s.decideMessage('left', mild, t0.add(ms(500))), isNull);
      expect(s.decideMessage('left', 20, t0.add(ms(2600)), atEdge: true),
          isNull,
          reason: '마지막으로 말한 단계(가장자리)와 같다 — 직전 프레임(보통)과 비교하지 않는다');
    });

    test('행1: 생략은 say.cancel(why=same_dir)로 남기고, 같은 문장은 3초에 1번만', () {
      EventLog.instance.clearForTest();
      final s = FeedbackService();
      s.decideMessage('left', 20, t0, atEdge: true); // 말함
      s.decideMessage('left', 20, t0.add(ms(200)), atEdge: true); // 종전에도 침묵
      s.decideMessage('left', mild, t0.add(ms(500))); // 문장 바뀜 -> 기록
      s.decideMessage('left', mild, t0.add(ms(700))); // 같은 문장 3초 안 -> 기록 안 함
      s.decideMessage('left', mild, t0.add(ms(3500))); // 3초 지남 -> 기록
      final lines = bundled();
      expect(lines.map((m) => m['text']), [leftMild, leftMild]);
    });

    test('행2: 같은 방향 단계 상승은 6초와 무관하게 바로 (보통 -> 즉시 -> 가장자리)',
        () {
      final s = FeedbackService();
      expect(s.decideMessage('left', mild, t0), leftMild);
      expect(s.decideMessage('left', severe, t0.add(ms(300))), leftSevere);
      expect(s.decideMessage('left', 20, t0.add(ms(600)), atEdge: true),
          leftEdge);

      final s2 = FeedbackService();
      expect(s2.decideMessage('right', -mild, t0), rightMild);
      expect(s2.decideMessage('right', -20, t0.add(ms(100)), atEdge: true),
          rightEdge,
          reason: '보통 -> 가장자리');
    });

    test('행3: 방향이 바뀌면 바로 (왼 -> 오 -> 왼, 6초 안)', () {
      final s = FeedbackService();
      expect(s.decideMessage('left', mild, t0), leftMild);
      expect(s.decideMessage('right', -mild, t0.add(ms(500))), rightMild);
      expect(s.decideMessage('left', mild, t0.add(ms(1000))), leftMild);
    });

    test('행4: front가 0.7초 이상 이어진 회복 뒤 다시 이탈하면 바로', () {
      final s = FeedbackService();
      expect(s.decideMessage('left', mild, t0), leftMild);
      expect(s.decideMessage('front', 0, t0.add(ms(1000))), isNull);
      expect(s.decideMessage('front', 0, t0.add(ms(1700))), isNull); // 0.7초
      expect(s.decideMessage('left', mild, t0.add(ms(2000))), leftMild);
      expect(FeedbackService.recoveryHold, const Duration(milliseconds: 700));
    });

    test('행4: 0.7초보다 짧은 front 깜빡임은 같은 이탈 — 묶음 유지', () {
      final s = FeedbackService();
      expect(s.decideMessage('left', mild, t0), leftMild);
      expect(s.decideMessage('front', 0, t0.add(ms(1000))), isNull);
      expect(s.decideMessage('front', 0, t0.add(ms(1600))), isNull); // 0.6초
      expect(s.decideMessage('left', mild, t0.add(ms(1800))), isNull);
      // 다음 깜빡임은 처음부터 다시 잰다(앞 깜빡임과 합치지 않는다).
      expect(s.decideMessage('front', 0, t0.add(ms(2000))), isNull);
      expect(s.decideMessage('front', 0, t0.add(ms(2500))), isNull);
      expect(s.decideMessage('left', mild, t0.add(ms(2700))), isNull);
    });

    test('행4: none·approach·crossed는 회복이 아니다 — 묶음 유지', () {
      for (final cls in ['none', 'approach', 'crossed']) {
        final s = FeedbackService();
        expect(s.decideMessage('left', mild, t0), leftMild);
        expect(s.decideMessage(cls, 0, t0.add(ms(1000))), isNull);
        expect(s.decideMessage(cls, 0, t0.add(ms(3000))), isNull);
        expect(s.decideMessage('left', mild, t0.add(ms(3200))), isNull,
            reason: cls);
      }
    });

    test('행4: front 사이에 none이 끼면 front 시간을 이어 세지 않는다', () {
      final s = FeedbackService();
      expect(s.decideMessage('left', mild, t0), leftMild);
      expect(s.decideMessage('front', 0, t0.add(ms(1000))), isNull);
      expect(s.decideMessage('none', 0, t0.add(ms(1400))), isNull);
      expect(s.decideMessage('front', 0, t0.add(ms(1800))), isNull);
      expect(s.decideMessage('left', mild, t0.add(ms(2000))), isNull);
    });

    test('행5: 같은 방향 이탈이 이어지면 6초마다 재경고', () {
      final s = FeedbackService();
      final fired = <int>[];
      for (var at = 0; at <= 13000; at += 170) {
        if (s.decideMessage('left', mild, t0.add(ms(at))) != null) {
          fired.add(at);
        }
      }
      expect(fired, [0, 6120, 12240], reason: '판정 간격 0.17초 — 6초가 지난 첫 판정');
    });

    test('진동은 그대로: 묶여 음성이 없는 프레임에도 3초 박자 방향 진동', () {
      final s = FeedbackService();
      expect(s.decideMessage('left', mild, t0), isNotNull);
      expect(s.vibrationPolicy.decidePattern('left', t0, 500), isNotNull);
      final t3 = t0.add(const Duration(seconds: 3));
      expect(s.decideMessage('left', mild, t3), isNull);
      expect(s.vibrationPolicy.decidePattern('left', t3, 500), isNotNull);
    });

    test('alert(): 묶인 프레임은 msg 없이 기록되고 생략 사유가 남는다', () async {
      EventLog.instance.clearForTest();
      final s = FeedbackService();
      await s.alert('left', 0.9, angleDegrees: 20, atEdge: true);
      await s.alert('left', 0.9, angleDegrees: mild);
      final alerts = EventLog.instance.earlyLines
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .where((m) => m['ev'] == 'alert')
          .toList();
      expect(alerts.map((m) => m['msg']), [leftEdge, null]);
      expect(alerts.first['vib'], isTrue);
      expect(bundled().single['text'], leftMild);
    });
  });

  // T121(사용자 승인 2026-10-21): 이탈 경고가 들리지 않던 문제(F1+F2).
  // 가짜 TTS는 flutter_tts-4.2.5 안드로이드 동작을 흉내 낸다 — 재생 중에 온 speak는
  // 재생 없이 곧바로 0을 돌려주고(FlutterTtsPlugin.kt:304-309), stop은 재생 중인
  // speak의 결과를 0으로 끝낸다(:379-382). stop 왕복에 [stopLatency]가 걸린다.
  group('삼켜진 이탈 경고 (T121)', () {
    final ko = AppStrings.of(AppLanguage.ko);

    List<Map<String, dynamic>> logged(String ev) => EventLog.instance.earlyLines
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .where((m) => m['ev'] == ev)
        .toList();

    _FakeTts install() {
      final fake = _FakeTts();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ttsChannel, fake.handle);
      return fake;
    }

    /// 진입 직전 상태(approach)를 안내 없이 만든다: front -> approach는 침묵.
    Future<void> toApproach(FeedbackService s) async {
      await s.alert('front', 0.9);
      await s.alert('approach', 0.9);
    }

    testWidgets('① 진입과 이탈이 같은 프레임에 나면 이탈 경고가 재생된다', (tester) async {
      EventLog.instance.clearForTest();
      final fake = install();
      final s = FeedbackService();
      await toApproach(s);
      await s.alert('left', 0.9, angleDegrees: mild); // 진입(P1) + 이탈(P0)
      await tester.pump(const Duration(milliseconds: 150)); // stop 왕복 뒤
      expect(fake.speaking, leftMild, reason: '들리는 것은 이탈 경고');
      expect(fake.played, [leftMild]);
      expect(fake.ignored, isEmpty, reason: '플러그인이 삼킨 speak가 없어야 한다');
      final entry = logged('say')
          .where((m) => m['text'] == ko.enteredCrosswalkMessage)
          .single;
      expect(entry['act'], 'queue', reason: '진입은 기존 대기 규칙');
      expect(entry['why'], 'wait_p0');
      await tester.pump(const Duration(seconds: 5));
      await _disposeIn(tester, s);
    });

    // T130 A: 대기 중인 진입 안내는 상한 3초, 횡단보도 위를 벗어나면 취소.
    testWidgets('T130: 이탈 경고 뒤에서 대기하는 진입 안내의 상한은 3초', (tester) async {
      EventLog.instance.clearForTest();
      install();
      final s = FeedbackService();
      await toApproach(s);
      await s.alert('left', 0.9, angleDegrees: mild);
      expect(s.audioPolicy.pendingMessage, ko.enteredCrosswalkMessage);
      expect(s.audioPolicy.pendingMaxWait, AudioPolicy.entryMaxPendingWait);
      expect(AudioPolicy.entryMaxPendingWait, const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 5));
      await _disposeIn(tester, s);
    });

    for (final to in ['crossed', 'none', 'approach']) {
      testWidgets('T130: 대기 중인 진입 안내는 $to로 바뀌면 취소(say.cancel why=state)',
          (tester) async {
        EventLog.instance.clearForTest();
        install();
        final s = FeedbackService();
        await toApproach(s);
        await s.alert('left', 0.9, angleDegrees: mild);
        expect(s.audioPolicy.pendingMessage, ko.enteredCrosswalkMessage);
        await s.alert(to, 0.9);
        expect(s.audioPolicy.pendingMessage, isNot(ko.enteredCrosswalkMessage));
        final cancel = logged('say.cancel')
            .where((m) => m['text'] == ko.enteredCrosswalkMessage)
            .single;
        expect(cancel['why'], 'state');
        await tester.pump(const Duration(seconds: 5));
        final spoke = logged('say.end')
            .where((m) => m['text'] == ko.enteredCrosswalkMessage);
        expect(spoke, isEmpty, reason: '취소한 진입 안내는 재생되지 않는다');
        await _disposeIn(tester, s);
      });
    }

    testWidgets('T130: 위(front/left/right)에 머무는 동안은 진입 안내를 취소하지 않는다',
        (tester) async {
      EventLog.instance.clearForTest();
      install();
      final s = FeedbackService();
      await toApproach(s);
      await s.alert('left', 0.9, angleDegrees: mild);
      await s.alert('front', 0.9);
      expect(s.audioPolicy.pendingMessage, ko.enteredCrosswalkMessage);
      expect(logged('say.cancel'), isEmpty);
      await tester.pump(const Duration(seconds: 5));
      await _disposeIn(tester, s);
    });

    test('T130: 진입 안내가 아닌 대기 항목은 상태가 바뀌어도 취소하지 않는다', () {
      final s = FeedbackService();
      s.audioPolicy.putPending(
          FeedbackPriority.p1, ko.crossedCrosswalkMessage, DateTime(2026));
      expect(s.cancelPendingEntryOnState('none'), isFalse);
      expect(s.audioPolicy.pendingMessage, ko.crossedCrosswalkMessage);
    });

    testWidgets('② 이탈 경고끼리 64ms 간격이면 나중 것이 재생된다', (tester) async {
      EventLog.instance.clearForTest();
      final fake = install();
      final s = FeedbackService();
      await s.alert('left', 0.9, angleDegrees: mild);
      await tester.pump(const Duration(milliseconds: 64)); // 앞 stop이 끝나기 전
      await s.alert('left', 0.9, angleDegrees: 20, atEdge: true); // 단계 상승
      await tester.pump(const Duration(milliseconds: 200));
      // T124: 앞 경고가 아직 재생 중(정책 기준)이라 빠른 상승 문장이 나간다.
      const rapidEdge = '오른쪽! 가장자리';
      expect(fake.speaking, rapidEdge);
      expect(fake.played, [rapidEdge], reason: '앞 요청은 speak를 보내지 않는다');
      expect(fake.ignored, isEmpty);
      final ends = logged('say.end');
      expect(ends.single['text'], leftMild);
      expect(ends.single['res'], 'superseded', reason: '건너뛴 것은 say.end에 남긴다');
      await tester.pump(const Duration(seconds: 2));
      expect(logged('say.end').last['text'], rapidEdge);
      expect(logged('say.end').last['res'], 'done');
      await _disposeIn(tester, s);
    });

    testWidgets('③ 정책이 아는 재생 중 상태가 실제 재생과 같다', (tester) async {
      EventLog.instance.clearForTest();
      final fake = install();
      final s = FeedbackService();
      await toApproach(s);
      await s.alert('left', 0.9, angleDegrees: mild); // 진입 + 이탈
      await tester.pump(const Duration(milliseconds: 150));
      expect(fake.speaking, leftMild);
      expect(s.audioPolicy.activePriority, FeedbackPriority.p0);
      expect(s.audioPolicy.activeMessage, leftMild);
      // 이탈 경고가 끝나면 둘 다 조용하다(전에는 진입이 재생 중인데 정책은 조용하다고 봤다).
      // T131: 이제는 대기하던 진입 안내를 바로 끼워 넣는다 — 정책과 실제 재생 모두 진입 안내.
      await tester.pump(const Duration(milliseconds: 1000));
      expect(fake.speaking, isNull, reason: '진입 안내의 stop 왕복 중');
      expect(s.audioPolicy.activePriority, FeedbackPriority.p1);
      expect(s.audioPolicy.activeMessage, ko.enteredCrosswalkMessage);
      await tester.pump(const Duration(milliseconds: 150));
      expect(fake.speaking, ko.enteredCrosswalkMessage);
      await tester.pump(const Duration(seconds: 5));
      await _disposeIn(tester, s);
    });

    // T131(사용자 선택 c): 대기 중인 진입 안내를 첫 P0가 끝난 직후 끼워 넣는다.
    testWidgets('T131: 첫 이탈 경고가 끝나면 최소 간격 없이 진입 안내를 끼워 넣는다',
        (tester) async {
      EventLog.instance.clearForTest();
      final fake = install();
      final s = FeedbackService();
      await toApproach(s);
      await s.alert('left', 0.9, angleDegrees: mild); // 진입(대기) + 이탈(P0)
      await tester.pump(const Duration(milliseconds: 1250)); // P0 끝 1100 + stop 100
      expect(fake.speaking, ko.enteredCrosswalkMessage,
          reason: '1.5초 간격을 기다리지 않는다');
      final says = logged('say')
          .where((m) => m['text'] == ko.enteredCrosswalkMessage)
          .toList();
      expect(says.map((m) => m['why']), ['wait_p0', 'after_p0']);
      expect(says.last['act'], 'speakNow');
      await tester.pump(const Duration(seconds: 5));
      expect(fake.played, [leftMild, ko.enteredCrosswalkMessage]);
      await _disposeIn(tester, s);
    });

    testWidgets('T131: 끼운 진입 안내 재생 중의 이탈 경고는 끊지 않고 끝난 뒤 나간다',
        (tester) async {
      EventLog.instance.clearForTest();
      final fake = install();
      final s = FeedbackService();
      await toApproach(s);
      await s.alert('left', 0.9, angleDegrees: mild);
      await tester.pump(const Duration(milliseconds: 1300)); // 진입 안내 재생 중
      await s.alert('right', 0.9, angleDegrees: mild);
      await tester.pump(const Duration(milliseconds: 100));
      expect(fake.speaking, ko.enteredCrosswalkMessage, reason: '끊지 않는다');
      expect(logged('say.defer').single, containsPair('why', 'insert'));
      expect(logged('say.defer').single['text'], rightMild);
      // 진입 안내 끝(1200 + 1000) -> stop 100 -> 이탈 경고.
      await tester.pump(const Duration(milliseconds: 1000));
      expect(fake.speaking, rightMild);
      expect(fake.played, [leftMild, ko.enteredCrosswalkMessage, rightMild]);
      expect(fake.ignored, isEmpty);
      expect(logged('say.end')
          .where((m) => m['text'] == ko.enteredCrosswalkMessage)
          .single['res'], 'done');
      await tester.pump(const Duration(seconds: 5));
      await _disposeIn(tester, s);
    });

    testWidgets('T131: 기다리는 사이 상태가 바뀌면 그 경고는 말하지 않는다(why=state)',
        (tester) async {
      EventLog.instance.clearForTest();
      final fake = install();
      final s = FeedbackService();
      await toApproach(s);
      await s.alert('left', 0.9, angleDegrees: mild);
      await tester.pump(const Duration(milliseconds: 1300));
      await s.alert('right', 0.9, angleDegrees: mild); // 기다림
      await s.alert('front', 0.9); // 회복 — 보류(700ms) 중
      await tester.pump(const Duration(milliseconds: 1100)); // 진입 안내 끝
      expect(fake.played, isNot(contains(rightMild)));
      final cancel =
          logged('say.cancel').where((m) => m['text'] == rightMild).single;
      expect(cancel['why'], 'state');
      await tester.pump(const Duration(seconds: 5));
      await _disposeIn(tester, s);
    });

    testWidgets('T131: 기다리는 경고는 최신 1개만 — 앞의 것은 superseded',
        (tester) async {
      EventLog.instance.clearForTest();
      final fake = install();
      final s = FeedbackService();
      await toApproach(s);
      await s.alert('left', 0.9, angleDegrees: mild);
      await tester.pump(const Duration(milliseconds: 1300));
      await s.alert('right', 0.9, angleDegrees: mild);
      await s.alert('left', 0.9, angleDegrees: mild);
      expect(
          logged('say.cancel')
              .where((m) => m['text'] == rightMild)
              .single['why'],
          'superseded');
      await tester.pump(const Duration(milliseconds: 1100));
      expect(fake.speaking, leftMild);
      expect(fake.played.where((t) => t == rightMild), isEmpty);
      await tester.pump(const Duration(seconds: 5));
      await _disposeIn(tester, s);
    });

    testWidgets('T131: 처음 요청부터 3초가 지났으면 끼워 넣지 않는다(max_wait)',
        (tester) async {
      EventLog.instance.clearForTest();
      final fake = install();
      final s = FeedbackService();
      s.audioPolicy.putPending(FeedbackPriority.p1, ko.enteredCrosswalkMessage,
          DateTime.now().subtract(const Duration(milliseconds: 3500)),
          maxWait: AudioPolicy.entryMaxPendingWait);
      await s.alert('left', 0.9, angleDegrees: mild);
      await tester.pump(const Duration(milliseconds: 1300));
      expect(fake.played, [leftMild]);
      expect(
          logged('say.ttl')
              .where((m) => m['text'] == ko.enteredCrosswalkMessage)
              .single['why'],
          'max_wait');
      await tester.pump(const Duration(seconds: 5));
      await _disposeIn(tester, s);
    });

    // T132 ①(A): P0가 P0에 끊기는 순간 대기 중인 진입 안내를 끼운다.
    testWidgets('T132: P0가 P0를 끊는 순간 진입 안내를 먼저 말하고 끊으려던 P0는 기다린다',
        (tester) async {
      EventLog.instance.clearForTest();
      final fake = install();
      final s = FeedbackService();
      await toApproach(s);
      await s.alert('left', 0.9, angleDegrees: mild); // 진입(대기) + 이탈(P0)
      await tester.pump(const Duration(milliseconds: 500)); // 이탈 경고 재생 중
      await s.alert('left', 0.9, angleDegrees: 30); // 단계 상승 — 빠른 상승 문장
      await tester.pump(const Duration(milliseconds: 150));
      expect(fake.speaking, ko.enteredCrosswalkMessage);
      final says = logged('say')
          .where((m) => m['text'] == ko.enteredCrosswalkMessage)
          .toList();
      expect(says.map((m) => m['why']), ['wait_p0', 'p0_cut']);
      expect(logged('say.end').firstWhere((m) => m['text'] == leftMild)['res'],
          'cut');
      final held = logged('say.defer').single;
      expect(held['why'], 'insert');
      expect(held['text'], ko.leftSevereRapidMessage);
      // 진입 안내 끝(600 + 100 + 1000) -> stop 100 -> 기다린 P0.
      await tester.pump(const Duration(milliseconds: 1100));
      expect(fake.speaking, ko.leftSevereRapidMessage);
      expect(fake.played,
          [leftMild, ko.enteredCrosswalkMessage, ko.leftSevereRapidMessage]);
      expect(
          logged('say.end')
              .where((m) => m['text'] == ko.enteredCrosswalkMessage)
              .single['res'],
          'done');
      await tester.pump(const Duration(seconds: 5));
      await _disposeIn(tester, s);
    });

    testWidgets('T132: 차도 경고가 P0를 끊을 때는 끼우지 않는다', (tester) async {
      EventLog.instance.clearForTest();
      final fake = install();
      final s = FeedbackService();
      await toApproach(s);
      await s.alert('left', 0.9, angleDegrees: mild);
      await tester.pump(const Duration(milliseconds: 500));
      await s.surfaceAlert([SurfaceEvent.road]);
      await tester.pump(const Duration(milliseconds: 150));
      expect(fake.speaking, ko.surfaceRoadMessage);
      expect(logged('say').where((m) => m['why'] == 'p0_cut'), isEmpty);
      expect(s.audioPolicy.pendingMessage, ko.enteredCrosswalkMessage);
      await tester.pump(const Duration(seconds: 5));
      await _disposeIn(tester, s);
    });

    testWidgets('T132: 처음 요청부터 3초가 지났으면 끊는 순간에도 끼우지 않는다',
        (tester) async {
      EventLog.instance.clearForTest();
      final fake = install();
      final s = FeedbackService();
      await s.alert('left', 0.9, angleDegrees: mild);
      await tester.pump(const Duration(milliseconds: 500));
      s.audioPolicy.putPending(FeedbackPriority.p1, ko.enteredCrosswalkMessage,
          DateTime.now().subtract(const Duration(milliseconds: 3500)),
          maxWait: AudioPolicy.entryMaxPendingWait);
      await s.alert('right', 0.9, angleDegrees: -mild); // 방향 바뀜 — 끊음
      await tester.pump(const Duration(milliseconds: 150));
      expect(fake.speaking, rightMild);
      expect(logged('say').where((m) => m['why'] == 'p0_cut'), isEmpty);
      expect(logged('say.defer'), isEmpty);
      await tester.pump(const Duration(seconds: 5));
      await _disposeIn(tester, s);
    });

    // T132 ②: 바로 재생된(why=ok) 진입 안내도 끼운 진입 안내와 같은 보호.
    testWidgets('T132: 바로 재생된 진입 안내 재생 중의 이탈 경고는 끊지 않고 끝난 뒤 나간다',
        (tester) async {
      EventLog.instance.clearForTest();
      final fake = install();
      final s = FeedbackService();
      await toApproach(s);
      await s.alert('front', 0.9); // 진입만 — 바로 재생
      expect(
          logged('say')
              .where((m) => m['text'] == ko.enteredCrosswalkMessage)
              .single['why'],
          'ok');
      await tester.pump(const Duration(milliseconds: 300)); // 진입 재생 중
      await s.alert('left', 0.9, angleDegrees: mild);
      await tester.pump(const Duration(milliseconds: 100));
      expect(fake.speaking, ko.enteredCrosswalkMessage, reason: '끊지 않는다');
      expect(logged('say.defer').single, containsPair('why', 'insert'));
      // 진입 끝(100 + 1000) -> stop 100 -> 이탈 경고.
      await tester.pump(const Duration(milliseconds: 850));
      expect(fake.speaking, leftMild);
      expect(fake.played, [ko.enteredCrosswalkMessage, leftMild]);
      expect(
          logged('say.end')
              .where((m) => m['text'] == ko.enteredCrosswalkMessage)
              .single['res'],
          'done');
      await tester.pump(const Duration(seconds: 5));
      await _disposeIn(tester, s);
    });

    testWidgets('T132: 바로 재생된 진입 안내도 차도 경고는 바로 끊는다(res=cut)',
        (tester) async {
      EventLog.instance.clearForTest();
      final fake = install();
      final s = FeedbackService();
      await toApproach(s);
      await s.alert('front', 0.9);
      await tester.pump(const Duration(milliseconds: 300));
      await s.surfaceAlert([SurfaceEvent.road]);
      await tester.pump(const Duration(milliseconds: 150));
      expect(fake.speaking, ko.surfaceRoadMessage);
      expect(logged('say.defer'), isEmpty);
      expect(
          logged('say.end')
              .where((m) => m['text'] == ko.enteredCrosswalkMessage)
              .single['res'],
          'cut');
      await tester.pump(const Duration(seconds: 5));
      await _disposeIn(tester, s);
    });

    testWidgets('T132: 다른 안내에 끊긴 발화는 say.end res=cut, 끝까지 간 것은 done',
        (tester) async {
      EventLog.instance.clearForTest();
      install();
      final s = FeedbackService();
      await s.alert('left', 0.9, angleDegrees: mild);
      await tester.pump(const Duration(milliseconds: 500));
      await s.alert('right', 0.9, angleDegrees: -mild); // 방향 바뀜 — P0가 P0를 끊음
      await tester.pump(const Duration(seconds: 3));
      final ends = logged('say.end');
      expect(ends.firstWhere((m) => m['text'] == leftMild)['res'], 'cut');
      expect(ends.firstWhere((m) => m['text'] == rightMild)['res'], 'done');
      await tester.pump(const Duration(seconds: 5));
      await _disposeIn(tester, s);
    });

    testWidgets('T131: 진입 안내가 아닌 대기 P1은 끼워 넣지 않는다(1.5초 간격 그대로)',
        (tester) async {
      EventLog.instance.clearForTest();
      final fake = install();
      final s = FeedbackService();
      s.audioPolicy.putPending(
          FeedbackPriority.p1, ko.crossedCrosswalkMessage, DateTime.now());
      await s.alert('left', 0.9, angleDegrees: mild);
      await tester.pump(const Duration(milliseconds: 1300));
      expect(fake.speaking, isNull, reason: 'P0 끝 1100 뒤 간격 대기');
      // (간격 1.5초는 실제 시계로 재므로 가짜 시간으로는 꺼내는 순간까지 볼 수 없다.)
      expect(s.audioPolicy.pendingMessage, ko.crossedCrosswalkMessage);
      expect(logged('say').where((m) => m['why'] == 'after_p0'), isEmpty);
      await tester.pump(const Duration(seconds: 5));
      await _disposeIn(tester, s);
    });
  });

  // T124(사용자 확정 2026-10-21): 빠른 상승 — 앞 이탈 경고가 아직 재생 중일 때
  // 같은 방향 단계가 오르면 짧은 문장을 사용자 속도 × 1.2로 말한다(T3·M1).
  group('빠른 상승 (T124)', () {
    final t0 = DateTime(2026, 10, 21, 18, 0, 0);
    Duration ms(int v) => Duration(milliseconds: v);
    const leftEdge = '오른쪽으로 가세요. 가장자리입니다';

    /// 정책이 '이탈 경고 재생 중'으로 보게 한다(실제 재생은 alert 테스트에서).
    void playing(FeedbackService s, String message,
            {P0Rank rank = P0Rank.deviation}) =>
        s.audioPolicy
            .markStarted(FeedbackPriority.p0, rank: rank, message: message);

    test('T3: 앞 이탈 경고 재생 중 + 단계 상승 -> 짧은 문장', () {
      final s = FeedbackService();
      expect(s.decideMessage('left', mild, t0), leftMild);
      playing(s, leftMild);
      expect(s.decideMessage('left', 20, t0.add(ms(271)), atEdge: true),
          '오른쪽! 가장자리');
      expect(s.lastDecisionRapid, isTrue);

      final s2 = FeedbackService();
      expect(s2.decideMessage('left', mild, t0), leftMild);
      playing(s2, leftMild);
      expect(s2.decideMessage('left', severe, t0.add(ms(225))), '오른쪽, 지금');
    });

    test('왼쪽으로 가야 할 때(right 이탈)는 "왼쪽"', () {
      final s = FeedbackService();
      expect(s.decideMessage('right', -mild, t0), rightMild);
      playing(s, rightMild);
      expect(s.decideMessage('right', -20, t0.add(ms(300)), atEdge: true),
          '왼쪽! 가장자리');
      final s2 = FeedbackService();
      expect(s2.decideMessage('right', -mild, t0), rightMild);
      playing(s2, rightMild);
      expect(s2.decideMessage('right', -severe, t0.add(ms(300))), '왼쪽, 지금');
    });

    test('즉시 -> 가장자리 상승도 재생 중이면 짧은 가장자리 문장', () {
      final s = FeedbackService();
      expect(s.decideMessage('left', severe, t0), leftSevere);
      playing(s, leftSevere);
      expect(s.decideMessage('left', 20, t0.add(ms(500)), atEdge: true),
          '오른쪽! 가장자리');
    });

    test('앞 경고가 끝난 뒤의 상승은 지금 문장 그대로', () {
      final s = FeedbackService();
      expect(s.decideMessage('left', mild, t0), leftMild);
      // 재생 중 아님(정책 재생 상태 없음)
      expect(s.decideMessage('left', 20, t0.add(ms(1700)), atEdge: true),
          leftEdge);
      expect(s.lastDecisionRapid, isFalse);
    });

    test('재생 중인 것이 회복 안내(P0-3)면 빠른 상승이 아니다', () {
      final s = FeedbackService();
      expect(s.decideMessage('left', mild, t0), leftMild);
      playing(s, '직진하세요', rank: P0Rank.recovery);
      expect(s.decideMessage('left', severe, t0.add(ms(300))), leftSevere);
      expect(s.lastDecisionRapid, isFalse);
    });

    test('방향이 바뀌거나 처음 경고면 재생 중이어도 지금 문장 그대로', () {
      final s = FeedbackService();
      expect(s.decideMessage('left', mild, t0), leftMild);
      playing(s, leftMild);
      expect(s.decideMessage('right', -severe, t0.add(ms(300))), rightSevere);
      expect(s.lastDecisionRapid, isFalse);

      final s2 = FeedbackService();
      playing(s2, leftMild);
      expect(s2.decideMessage('left', 20, t0, atEdge: true), leftEdge,
          reason: '비교할 앞 경고가 없다');
    });

    test('속도: 사용자 설정 × 1.2, 상한 1.0', () {
      expect(FeedbackService.rapidRate(0.5), closeTo(0.6, 1e-9));
      expect(FeedbackService.rapidRate(0.1), closeTo(0.12, 1e-9));
      expect(FeedbackService.rapidRate(0.9), 1.0);
      expect(FeedbackService.rapidRate(1.0), 1.0);
    });

    testWidgets('alert(): 빠른 상승은 1.2배로 말하고 다음 발화에서 원래 속도로 돌아간다',
        (tester) async {
      EventLog.instance.clearForTest();
      final fake = _FakeTts();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ttsChannel, fake.handle);
      final s = FeedbackService();
      await s.alert('left', 0.9, angleDegrees: mild);
      await tester.pump(const Duration(milliseconds: 300)); // 재생 중
      expect(fake.speaking, leftMild);
      await s.alert('left', 0.9, angleDegrees: 20, atEdge: true); // 빠른 상승
      await tester.pump(const Duration(milliseconds: 200));
      expect(fake.speaking, '오른쪽! 가장자리');
      await tester.pump(const Duration(seconds: 2)); // 끝까지
      await s.alert('right', 0.9, angleDegrees: -mild); // 다음 발화
      await tester.pump(const Duration(milliseconds: 200));
      expect(fake.speaking, rightMild);
      expect(fake.rates, [closeTo(0.6, 1e-9), 0.5],
          reason: '빠른 상승 전에 0.6, 다음 발화 전에 0.5로 복귀');
      expect(fake.played, [leftMild, '오른쪽! 가장자리', rightMild]);

      final lines = EventLog.instance.earlyLines
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();
      final say = lines.where((m) => m['ev'] == 'say').toList();
      expect(say.map((m) => m['rate']), [null, closeTo(0.6, 1e-9), null]);
      final ends = lines.where((m) => m['ev'] == 'say.end').toList();
      final rapidEnd = ends.firstWhere((m) => m['text'] == '오른쪽! 가장자리');
      expect(rapidEnd['rate'], closeTo(0.6, 1e-9));
      expect(rapidEnd['rateMs'], isA<int>());
      await tester.pump(const Duration(seconds: 2));
      final restoreEnd = EventLog.instance.earlyLines
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .lastWhere((m) => m['ev'] == 'say.end' && m['text'] == rightMild);
      expect(restoreEnd['rate'], 0.5);
      expect(restoreEnd['rateMs'], isA<int>());
      final first = ends.firstWhere((m) => m['text'] == leftMild);
      expect(first.containsKey('rate'), isFalse, reason: '속도를 안 바꾼 발화는 기록 그대로');
      await _disposeIn(tester, s);
    });
  });
}

/// T121: 대기 꺼내기 타이머를 정리한다. 최소 간격은 실제 시각으로 재므로 가짜 시계에서는
/// 대기가 다시 예약된다(위 (g) 주석) — 테스트 끝에 남은 타이머를 dispose로 끈다.
Future<void> _disposeIn(WidgetTester tester, FeedbackService s) async {
  unawaited(s.dispose());
  await tester.pump(const Duration(seconds: 1));
}

/// T121: flutter_tts-4.2.5 안드로이드(QUEUE_FLUSH + awaitSpeakCompletion)를 흉내 낸 가짜.
class _FakeTts {
  _FakeTts();

  static const stopLatency = Duration(milliseconds: 100);
  static const utterance = Duration(milliseconds: 1000);

  String? speaking;
  final played = <String>[];
  // T124: setSpeechRate로 받은 속도(순서대로).
  final rates = <double>[];
  final ignored = <String>[];
  Completer<int>? _pending;
  Timer? _done;

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'stop':
        // 플랫폼은 stop을 받는 즉시 적용하고, 응답만 늦게 돌아온다.
        _finish(0);
        await Future<void>.delayed(stopLatency);
        return 1;
      case 'speak':
        final args = call.arguments;
        final text = args is Map ? args['text'] as String : args as String;
        if (speaking != null) {
          ignored.add(text);
          return 0;
        }
        speaking = text;
        played.add(text);
        final c = Completer<int>();
        _pending = c;
        _done = Timer(utterance, () => _finish(1));
        return c.future;
      case 'setSpeechRate':
        rates.add((call.arguments as num).toDouble());
        return 1;
      default:
        return 1;
    }
  }

  void _finish(int value) {
    _done?.cancel();
    _done = null;
    final c = _pending;
    _pending = null;
    speaking = null;
    if (c != null && !c.isCompleted) c.complete(value);
  }
}
