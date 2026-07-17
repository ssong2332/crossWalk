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
import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/services/feedback_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const leftMessage = '왼쪽으로 이탈했습니다. 오른쪽으로 이동하세요';
  const rightMessage = '오른쪽으로 이탈했습니다. 왼쪽으로 이동하세요';

  group('FeedbackService.decideMessage — front silence', () {
    test('returns null for "front" regardless of prior state', () {
      final service = FeedbackService();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      expect(service.decideMessage('front', t0), isNull);

      // Even after a prior alert has fired for another class, "front"
      // must still stay silent.
      service.decideMessage('left', t0);
      expect(service.decideMessage('front', t0.add(const Duration(seconds: 10))), isNull);
    });
  });

  group('FeedbackService.decideMessage — first alert', () {
    test('fires immediately on a fresh instance for "left"', () {
      final service = FeedbackService();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      final message = service.decideMessage('left', t0);

      expect(message, isNotNull);
      expect(message, leftMessage);
    });
  });

  group('FeedbackService.decideMessage — cooldown', () {
    test('suppresses a same-class repeat within the cooldown window', () {
      final service = FeedbackService();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      final first = service.decideMessage('left', t0);
      expect(first, isNotNull);

      final second = service.decideMessage('left', t0.add(const Duration(seconds: 1)));
      expect(second, isNull);
    });

    test('fires again once the cooldown has elapsed for the same class', () {
      final service = FeedbackService();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      final first = service.decideMessage('left', t0);
      expect(first, isNotNull);

      // Cooldown check is `< _cooldownSeconds` (3), so exactly 3 seconds
      // later must no longer be suppressed.
      final second = service.decideMessage('left', t0.add(const Duration(seconds: 3)));
      expect(second, isNotNull);
      expect(second, leftMessage);
    });
  });

  group('FeedbackService.decideMessage — class change', () {
    test('bypasses cooldown immediately when the detected class changes', () {
      final service = FeedbackService();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      final first = service.decideMessage('left', t0);
      expect(first, isNotNull);

      // Well within what would be the "left" cooldown window, but the
      // class changed to "right" — cooldown is per-class, not global.
      final second = service.decideMessage('right', t0.add(const Duration(milliseconds: 1)));
      expect(second, isNotNull);
      expect(second, rightMessage);
    });
  });

  group('FeedbackService.decideMessage — message content', () {
    test('returns the exact left-deviation Korean message', () {
      final service = FeedbackService();
      final message = service.decideMessage('left', DateTime(2026, 1, 1));

      expect(message, '왼쪽으로 이탈했습니다. 오른쪽으로 이동하세요');
    });

    test('returns the exact right-deviation Korean message', () {
      final service = FeedbackService();
      final message = service.decideMessage('right', DateTime(2026, 1, 1));

      expect(message, '오른쪽으로 이탈했습니다. 왼쪽으로 이동하세요');
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
    test('a single activation resets isVibrating to false after the '
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
          reason:
              'the first activation\'s timer must have been cancelled by '
              'the second activateVibrationIndicator() call',
        );

        // The second activation's own timer still fires ~150ms later.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(service.isVibrating.value, isFalse);
      },
    );
  });

  group('FeedbackService — isSpeaking race guard', () {
    test('finishSpeechGeneration resets isSpeaking when it is the current '
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
          reason:
              'a stale handler for an older generation must not reset a '
              'newer, still-active speech',
        );

        // The second utterance's own completion handler correctly clears it.
        service.finishSpeechGeneration(secondGeneration);
        expect(service.isSpeaking.value, isFalse);
      },
    );
  });
}
