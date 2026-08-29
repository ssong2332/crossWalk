// T70: 각도 모델 전처리의 **회전 매핑**을 고정하는 테스트.
//
// 회전 방향이 틀리면 각도가 90도 또는 180도 조용히 어긋난다 — 에러 없이
// 화살표만 엉뚱한 곳을 가리키므로 반드시 테스트로 고정해야 한다.
//
// 기준: `image` 패키지 4.8.0의 실제 구현
// (lib/src/transform/copy_rotate.dart `_rotate90`: `dst(x,y) = src(y, H-1-x)`)
// 을 직접 읽어 확인한 **시계방향** 관례를 따른다.
import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/services/angle_estimator.dart';

void main() {
  // 센서 버퍼가 가로 4 x 세로 3 이라고 하자.
  const w = 4;
  const h = 3;

  group('AngleEstimator.displaySize — 90/270도에서 가로세로가 바뀐다', () {
    test('0도/180도는 그대로', () {
      expect(AngleEstimator.displaySize(0, w, h), [w, h]);
      expect(AngleEstimator.displaySize(180, w, h), [w, h]);
    });

    test('90도/270도는 뒤바뀜', () {
      expect(AngleEstimator.displaySize(90, w, h), [h, w]);
      expect(AngleEstimator.displaySize(270, w, h), [h, w]);
    });
  });

  group('AngleEstimator.sensorCoord — 시계방향 회전 매핑', () {
    test('0도는 항등 매핑', () {
      expect(AngleEstimator.sensorCoord(0, 0, 0, w, h), [0, 0]);
      expect(AngleEstimator.sensorCoord(3, 2, 0, w, h), [3, 2]);
    });

    // 90도 시계방향: 센서의 좌상단이 화면의 **우상단**으로 간다.
    // 화면 크기는 (h, w) = (3, 4).
    test('90도: 센서 좌상단(0,0) -> 화면 우상단(2,0)', () {
      // 화면 우상단 = (dx=h-1=2, dy=0) 이 센서 (0,0)을 가리켜야 한다.
      expect(AngleEstimator.sensorCoord(2, 0, 90, w, h), [0, 0]);
    });

    test('90도: 화면 좌상단(0,0)은 센서 좌하단(0,h-1)', () {
      expect(AngleEstimator.sensorCoord(0, 0, 90, w, h), [0, h - 1]);
    });

    test('90도: 화면 전 영역이 센서 범위 안에 들어온다', () {
      final ds = AngleEstimator.displaySize(90, w, h);
      for (int dy = 0; dy < ds[1]; dy++) {
        for (int dx = 0; dx < ds[0]; dx++) {
          final s = AngleEstimator.sensorCoord(dx, dy, 90, w, h);
          expect(s[0], inInclusiveRange(0, w - 1), reason: 'dx=$dx dy=$dy');
          expect(s[1], inInclusiveRange(0, h - 1), reason: 'dx=$dx dy=$dy');
        }
      }
    });

    test('90도 매핑은 일대일이다 (겹치거나 빠지는 픽셀이 없다)', () {
      final ds = AngleEstimator.displaySize(90, w, h);
      final seen = <String>{};
      for (int dy = 0; dy < ds[1]; dy++) {
        for (int dx = 0; dx < ds[0]; dx++) {
          final s = AngleEstimator.sensorCoord(dx, dy, 90, w, h);
          seen.add('${s[0]},${s[1]}');
        }
      }
      expect(seen.length, w * h, reason: '모든 센서 픽셀이 정확히 한 번씩 쓰여야 한다');
    });

    test('180도는 상하좌우 반전', () {
      expect(AngleEstimator.sensorCoord(0, 0, 180, w, h), [w - 1, h - 1]);
      expect(AngleEstimator.sensorCoord(w - 1, h - 1, 180, w, h), [0, 0]);
    });

    test('270도: 화면 좌상단(0,0)은 센서 우상단(w-1,0)', () {
      expect(AngleEstimator.sensorCoord(0, 0, 270, w, h), [w - 1, 0]);
    });

    test('90도를 네 번 적용하면 제자리로 돌아온다', () {
      // 90도씩 네 번 = 360도. 매핑을 네 번 합성하면 항등이어야 한다.
      // (정사각형에서만 크기가 유지되므로 정사각 센서로 확인한다.)
      const n = 5;
      for (int y = 0; y < n; y++) {
        for (int x = 0; x < n; x++) {
          var p = [x, y];
          for (int i = 0; i < 4; i++) {
            p = AngleEstimator.sensorCoord(p[0], p[1], 90, n, n);
          }
          expect(p, [x, y], reason: '($x,$y)에서 4회 회전이 항등이 아님');
        }
      }
    });
  });

  group('AngleEstimator — 상수 동기화', () {
    test('angleScale은 학습 스크립트의 ANGLE_SCALE(90.0)과 같아야 한다', () {
      // train/train_angle.py의 ANGLE_SCALE과 어긋나면 각도가 배율만큼
      // 조용히 틀어진다(에러 없음).
      expect(AngleEstimator.angleScale, 90.0);
    });
  });
}
