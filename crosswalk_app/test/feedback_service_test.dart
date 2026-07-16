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
}
