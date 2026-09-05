import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:crosswalk_app/services/ground_projection.dart';

/// T78: 지면 투영은 화살표가 "장면과 일치하는지"를 좌우하는 기하이므로,
/// 픽셀을 눈으로 보지 않고도 성질을 고정해 둔다. 상수 하나가 조용히 바뀌면
/// 화살표가 지면에서 떠 보이거나 좌우가 뒤집히는데 에러는 나지 않는다.
void main() {
  const p = GroundProjection();
  const size = Size(300, 600);

  group('GroundProjection — 카메라 기하', () {
    test('수평선은 화면 중앙보다 위에 있다 (아래를 내려다보므로)', () {
      expect(p.horizonY(size), lessThan(size.height / 2));
    });

    test('지면점은 항상 수평선 아래에 투영된다', () {
      for (final z in <double>[1.0, 2.0, 5.0, 20.0, 100.0, 1000.0]) {
        final o = p.project(0, z, size);
        expect(o, isNotNull, reason: 'z=$z는 투영 가능해야 한다');
        expect(o!.dy, greaterThan(p.horizonY(size)),
            reason: 'z=$z가 수평선 위로 올라갔다');
      }
    });

    test('멀어질수록 수평선에 수렴한다', () {
      final near = p.project(0, 3, size)!;
      final far = p.project(0, 5000, size)!;
      final horizon = p.horizonY(size);
      expect(far.dy, lessThan(near.dy));
      // 수렴 오차는 거리에 반비례한다 — 300 m에서 약 1.4 px, 5000 m에서 0.1 px.
      expect((far.dy - horizon).abs(), lessThan(0.5));
    });

    test('같은 yaw의 지면 직선은 한 소실점으로 모인다 — 원근의 핵심', () {
      // 서로 다른 두 지면 직선(옆으로 1 m 떨어뜨림)을 아주 멀리 보내면
      // 화면에서 같은 점으로 수렴해야 한다. 이것이 성립해야 화살표가
      // 횡단보도와 나란해 보인다.
      final a = p.project(0, 5000, size)!;
      final b = p.project(1, 5000, size)!;
      expect((a.dx - b.dx).abs(), lessThan(1.0));
      expect((a.dy - b.dy).abs(), lessThan(1.0));
    });
  });

  group('GroundProjection — 화살표 형상', () {
    test('yaw 0이면 화살표는 좌우 대칭이다', () {
      final head = p.headPolygon(0, size)!;
      expect(head[1].dx, closeTo(size.width / 2, 0.01),
          reason: '머리 끝은 화면 중앙선 위에 있어야 한다');
      // 머리 밑변의 두 점은 중앙선에서 같은 거리
      expect((head[0].dx - size.width / 2).abs(),
          closeTo((head[2].dx - size.width / 2).abs(), 0.01));
    });

    test('원근 — 먼 조각이 가까운 조각보다 좁다', () {
      final slices = p.shaftSlices(0, size, 6)!;
      double widthOf(List<dynamic> q) => (q[1].dx - q[0].dx).abs();
      final nearW = widthOf(slices.first);
      final farW = widthOf(slices.last);
      expect(farW, lessThan(nearW),
          reason: '지면에 누웠다면 멀수록 좁아져야 한다');
    });

    test('yaw 부호 — +는 오른쪽, -는 왼쪽', () {
      final right = p.headPolygon(30, size)!;
      final left = p.headPolygon(-30, size)!;
      expect(right[1].dx, greaterThan(size.width / 2));
      expect(left[1].dx, lessThan(size.width / 2));
    });

    test('조각 수만큼 사각형이 나오고 각 사각형은 꼭짓점 4개', () {
      final slices = p.shaftSlices(10, size, 14)!;
      expect(slices, hasLength(14));
      for (final q in slices) {
        expect(q, hasLength(4));
      }
    });
  });

  group('GroundProjection — 화면각 <-> yaw 변환', () {
    test('화면각은 yaw에 대해 단조증가한다 (이분법의 전제)', () {
      double? prev;
      for (var yaw = -60.0; yaw <= 60.0; yaw += 5) {
        final a = p.screenAngleOfYaw(yaw, size);
        expect(a, isNotNull);
        if (prev != null) {
          expect(a!, greaterThan(prev),
              reason: 'yaw=$yaw에서 단조성이 깨졌다');
        }
        prev = a;
      }
    });

    test('왕복 변환이 일치한다', () {
      for (final target in <double>[-45, -23, -10, 0, 10, 23, 45]) {
        final yaw = p.yawForScreenAngle(target, size);
        final back = p.screenAngleOfYaw(yaw, size)!;
        expect(back, closeTo(target, 0.1),
            reason: '화면각 $target도 왕복 실패');
      }
    });

    test('화면각 0은 yaw 0이다', () {
      expect(p.yawForScreenAngle(0, size), closeTo(0, 0.01));
    });

    test('화면각이 yaw보다 크다 — 평면 회전으로 그리면 덜 꺾여 보이는 이유', () {
      // 원근 때문에 같은 방향이라도 화면에서는 더 크게 꺾여 보인다.
      // 이 성질이 성립하므로 "라벨 각도를 그대로 평면 회전"하면 실제보다
      // 덜 꺾인 화살표가 나온다 — T78의 출발점이다.
      for (final yaw in <double>[10, 20, 30, 45]) {
        final screen = p.screenAngleOfYaw(yaw, size)!;
        expect(screen, greaterThan(yaw), reason: 'yaw=$yaw');
      }
    });

    test('탐색 범위를 넘는 화면각은 최대 yaw에서 잘린다', () {
      final yaw = p.yawForScreenAngle(179, size);
      expect(yaw, closeTo(GroundProjection.maxYawDegrees, 0.01));
    });
  });

  group('GroundProjection — 카메라 가정값을 바꾸면 기하도 따라간다', () {
    test('pitch가 클수록 수평선이 위로 올라간다', () {
      const shallow = GroundProjection(pitchDegrees: 5);
      const steep = GroundProjection(pitchDegrees: 25);
      expect(steep.horizonY(size), lessThan(shallow.horizonY(size)));
    });

    test('화각이 좁을수록 초점거리가 길다', () {
      const wide = GroundProjection(fovWidthDegrees: 80);
      const narrow = GroundProjection(fovWidthDegrees: 40);
      expect(narrow.focalPx(size), greaterThan(wide.focalPx(size)));
    });

    test('초점거리는 f = (w/2)/tan(fov/2) 정의를 지킨다', () {
      const g = GroundProjection(fovWidthDegrees: 51);
      expect(g.focalPx(size),
          closeTo((size.width / 2) / math.tan(51 * math.pi / 180 / 2), 0.001));
    });
  });
}
