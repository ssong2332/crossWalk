// Unit tests for Classifier's pure decision logic (smoothing, thresholds, throttle).
//
// Throttle testing note: rather than faking a CameraImage to sneak past
// `processFrame`'s OrtSession dependency, we test the throttle gate directly via
// the extracted `@visibleForTesting` `shouldProcessFrame()` method (same pattern
// as `decideFromLogits`). This avoids needing a real/fake OrtSession entirely
// and gives an unambiguous pass/fail signal (a plain bool), rather than trying
// to distinguish "blocked by throttle" from "passed throttle but preprocessing
// failed" — both of which return null from `processFrame` and are otherwise
// indistinguishable from the outside.
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/services/classifier.dart';

void main() {
  group('Classifier.softmax', () {
    test('produces probabilities summing to ~1.0 for T21 example logits', () {
      final classifier = Classifier();
      // Exact example from the T21 investigation.
      final probs = classifier.softmax([-0.0838, 0.4418, -0.4263]);

      final sum = probs.reduce((a, b) => a + b);
      expect(sum, closeTo(1.0, 1e-6));

      // Max probability should land on index 1, matching known expected
      // values ~[0.294, 0.497, 0.209].
      int maxIdx = 0;
      for (int i = 1; i < probs.length; i++) {
        if (probs[i] > probs[maxIdx]) maxIdx = i;
      }
      expect(maxIdx, 1);
      expect(probs[0], closeTo(0.294, 0.02));
      expect(probs[1], closeTo(0.497, 0.02));
      expect(probs[2], closeTo(0.209, 0.02));
    });

    test('remains numerically stable for large-magnitude logits', () {
      final classifier = Classifier();
      final probs = classifier.softmax([1000, 1001, 999]);

      for (final p in probs) {
        expect(p.isNaN, isFalse);
        expect(p.isFinite, isTrue);
      }
      final sum = probs.reduce((a, b) => a + b);
      expect(sum, closeTo(1.0, 1e-6));
    });

    test('thresholds 0.55/0.85 are reachable given a sufficiently skewed logit vector', () {
      final classifier = Classifier();

      // Strongly skewed toward "front" (index 0) — should clear the 0.85
      // front threshold.
      final frontProbs = classifier.softmax([10.0, 0.0, 0.0]);
      expect(frontProbs[0], greaterThanOrEqualTo(0.85));

      // Moderately skewed toward "left" (index 1) — should clear the 0.55
      // deviation threshold but not necessarily the stricter 0.85 one.
      final leftProbs = classifier.softmax([0.0, 1.0, 0.0]);
      expect(leftProbs[1], greaterThanOrEqualTo(0.55));
    });
  });

  group('Classifier.decideFromLogits — smoothing window', () {
    test('averages only the most recent 5 pushes (sliding window)', () {
      final classifier = Classifier();

      // Push 5 frames strongly favoring "left" (index 1).
      for (int i = 0; i < 5; i++) {
        final result = classifier.decideFromLogits([0.0, 10.0, 0.0]);
        expect(result, isNotNull);
        expect(result!.label, 'left');
      }

      // Push 5 more frames strongly favoring "front" (index 0). After the
      // 5-frame sliding window fully rotates out the "left" pushes, the
      // result should transition to "front".
      ClassificationResult? lastResult;
      for (int i = 0; i < 5; i++) {
        lastResult = classifier.decideFromLogits([10.0, 0.0, 0.0]);
      }

      // After 5 more "front"-favoring pushes, the window contains only
      // "front" logits, so the average should now clearly favor "front".
      expect(lastResult, isNotNull);
      expect(lastResult!.label, 'front');
    });

    test('blends during the transition before the old window fully rotates out', () {
      final classifier = Classifier();

      // Fill window with 5 "left"-favoring frames.
      for (int i = 0; i < 5; i++) {
        classifier.decideFromLogits([0.0, 10.0, 0.0]);
      }

      // Push a single "front"-favoring frame — with a 5-frame window this
      // should be averaged with 4 remaining "left" frames, not fully
      // overwrite them (unbounded running average would behave differently).
      final blended = classifier.decideFromLogits([10.0, 0.0, 0.0]);

      // Still dominated by "left" since only 1 of 5 window slots changed.
      expect(blended, isNotNull);
      expect(blended!.label, 'left');
    });
  });

  group('Classifier.decideFromLogits — threshold gating', () {
    test('returns null when confidence is below the applicable threshold', () {
      final classifier = Classifier();

      // Near-uniform/ambiguous logits -> near-uniform probabilities -> no
      // class clears its threshold.
      final result = classifier.decideFromLogits([0.01, 0.0, -0.01]);

      expect(result, isNull);
    });
  });

  group('Classifier.shouldProcessFrame — throttle', () {
    test('only every _throttleFrames-th call passes the gate', () {
      final classifier = Classifier();
      const throttleFrames = 5; // mirrors Classifier._throttleFrames

      int passedCount = 0;
      const totalCalls = 23;
      for (int i = 0; i < totalCalls; i++) {
        if (classifier.shouldProcessFrame()) passedCount++;
      }

      expect(passedCount, totalCalls ~/ throttleFrames);
    });
  });

  group('Classifier.hashMatches', () {
    test('returns true when the expected hash matches the actual SHA-256', () {
      final classifier = Classifier();
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      final expectedHash = sha256.convert(bytes).toString();

      expect(classifier.hashMatches(bytes, expectedHash), isTrue);
    });

    test('returns false when the expected hash does not match the actual SHA-256', () {
      final classifier = Classifier();
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      final differentHash = sha256.convert(Uint8List.fromList([9, 9, 9, 9, 9])).toString();

      expect(classifier.hashMatches(bytes, differentHash), isFalse);
    });

    test('skips verification (returns true) for the placeholder_hash value', () {
      final classifier = Classifier();
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);

      expect(classifier.hashMatches(bytes, 'placeholder_hash'), isTrue);
    });

    test('skips verification (returns true) for a non-64-char hash string', () {
      final classifier = Classifier();
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);

      expect(classifier.hashMatches(bytes, 'short_hash'), isTrue);
      expect(classifier.hashMatches(bytes, ''), isTrue);
    });

    test('trims trailing CRLF from the hash file before comparing (regression guard for .trim())', () {
      final classifier = Classifier();
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      // A syntactically-valid-looking but WRONG 64-char hash (not the real
      // hash of `bytes`), with a trailing CRLF as the real hash file on disk
      // has (see T7).
      //
      // If `.trim()` is present (correct): the CRLF is stripped, so length
      // becomes 64 -> falls through to the real comparison -> mismatch ->
      // `false`.
      // If `.trim()` were removed (regression): length stays 66 -> hits the
      // length-skip branch -> `true` (wrongly skips verification).
      //
      // Asserting `isFalse` means this test flips from pass to fail if
      // `.trim()` is ever deleted, unlike a matching-hash test which would
      // return `true` either way.
      final wrongHash = sha256.convert(Uint8List.fromList([9, 9, 9, 9, 9])).toString();

      expect(classifier.hashMatches(bytes, '$wrongHash\r\n'), isFalse);
    });
  });
}
