import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

/// T78: 화살표를 **지면 평면에 누운 것처럼** 화면에 투영한다.
///
/// 왜 필요한가 (2026-09-05, 사용자 지시):
///   기존 화살표는 화면 중앙에서 각도만큼 **평면 회전**만 했다. 그래서 각도가
///   맞아도 장면과 어긋나 보인다 — 실제 횡단보도는 원근 때문에 멀어질수록
///   한 점(소실점)으로 모이는데, 평면 회전한 직선은 그러지 않기 때문이다.
///   지면에 눕혀 투영하면 같은 yaw를 가진 모든 지면 직선이 **같은 소실점**으로
///   수렴하므로, 화살표가 횡단보도와 나란히 보인다.
///
/// 좌표계 (핀홀 카메라, 카메라를 원점에 둔다):
///   월드는 Y 위쪽, +Z 전방. 카메라는 지면에서 [cameraHeightMeters] 높이에
///   있고 [pitchDegrees]만큼 아래를 본다. 지면은 Y = -h 평면이다.
///
///     Yc = -h·cos φ + Z·sin φ
///     Zc =  h·sin φ + Z·cos φ
///     u  = cx + f·X / Zc
///     v  = cy - f·Yc / Zc          (화면 v는 아래가 +)
///
///   Z → ∞ 이면 v → cy - f·tan φ (= [horizonY], 수평선),
///   u → cx + f·tan(yaw) (= 소실점). 이 성질이 "장면과 일치"의 근거다.
///
/// 각도 규약: **화면 위쪽이 0도, 시계방향이 +** — 각도 라벨
/// (`train/label_angles.py`)·`AngleEstimator`와 같다.
///
/// 주의 (검증되지 않은 가정): [fovWidthDegrees]·[cameraHeightMeters]·
/// [pitchDegrees]는 **가정값**이다. `camera` 패키지는 화각을 알려주지 않으므로
/// 4:3 센서의 짧은 변 화각(약 51도)을 쓰고, 자세는 온보딩 안내
/// (`app_strings.dart` — '가슴 정면에 가깝게, 살짝 아래를 향하도록')를 전제한다.
/// 실기기에서 화살표가 지면보다 높거나 낮게 누워 보이면 이 세 값을 조정해야
/// 한다 — 확인 방법은 실기기에서 횡단보도 줄무늬와 화살표가 나란한지 보는 것.
class GroundProjection {
  const GroundProjection({
    this.fovWidthDegrees = 51.0,
    this.cameraHeightMeters = 1.30,
    this.pitchDegrees = 12.0,
  });

  final double fovWidthDegrees;
  final double cameraHeightMeters;
  final double pitchDegrees;

  /// 화살표 형상(미터, 지면 위 실제 크기).
  /// 발 앞 [tailZ]에서 시작해 [shaftLength] 만큼 뻗고 [headLength]의 머리를 단다.
  static const double tailZ = 1.8;
  static const double shaftLength = 2.6;
  static const double shaftWidth = 0.42;
  static const double headLength = 1.0;
  static const double headWidth = 1.05;

  /// yaw 탐색 범위. 사람이 횡단보도를 건널 때 이보다 크게 틀어지면 화살표가
  /// 화면 밖으로 나가므로 여기서 자른다.
  static const double maxYawDegrees = 75.0;

  static const double _deg = math.pi / 180.0;

  double focalPx(Size size) =>
      (size.width / 2) / math.tan(fovWidthDegrees * _deg / 2);

  /// 수평선의 화면 y. 지면점은 반드시 이 아래에 투영된다.
  double horizonY(Size size) =>
      size.height / 2 - focalPx(size) * math.tan(pitchDegrees * _deg);

  /// 지면점 (x, z)[m]를 화면 좌표로. 지면 뒤(카메라 뒤)면 null.
  Offset? project(double x, double z, Size size) {
    final phi = pitchDegrees * _deg;
    final yc = -cameraHeightMeters * math.cos(phi) + z * math.sin(phi);
    final zc = cameraHeightMeters * math.sin(phi) + z * math.cos(phi);
    if (zc <= 1e-6) return null;
    final f = focalPx(size);
    return Offset(size.width / 2 + f * x / zc, size.height / 2 - f * yc / zc);
  }

  /// yaw로 그린 화살표가 **화면에서** 몇 도로 보이는지. 투영 불가면 null.
  double? screenAngleOfYaw(double yawDegrees, Size size) {
    final yaw = yawDegrees * _deg;
    final total = shaftLength + headLength;
    final tail = project(0, tailZ, size);
    final tip = project(
        math.sin(yaw) * total, tailZ + math.cos(yaw) * total, size);
    if (tail == null || tip == null) return null;
    return math.atan2(tip.dx - tail.dx, -(tip.dy - tail.dy)) / _deg;
  }

  /// 화면에서 [screenDegrees]로 보이게 하는 지면 yaw를 찾는다.
  ///
  /// 각도 라벨과 모델 출력은 **사람이 사진 위에 그은 화면 각도**이므로
  /// (`train/label_angles.py`), 그대로 평면 회전에 쓰면 원근이 빠진다.
  /// 여기서 yaw로 환산해 지면에 눕혀야 같은 방향이 원근에 맞게 그려진다.
  /// 화면각은 yaw에 대해 단조증가라 이분법으로 안전하게 풀린다.
  double yawForScreenAngle(double screenDegrees, Size size) {
    var lo = -maxYawDegrees;
    var hi = maxYawDegrees;
    for (var i = 0; i < 40; i++) {
      final mid = (lo + hi) / 2;
      final a = screenAngleOfYaw(mid, size);
      if (a == null) return 0;
      if (a < screenDegrees) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return (lo + hi) / 2;
  }

  /// 화살표 몸통을 진행 방향으로 [slices]등분한 사각형 목록.
  ///
  /// 등분하는 이유는 애니메이션 때문이다 — 조각마다 밝기를 달리 주면 빛이
  /// 앞으로 흐르는 것처럼 보인다. 한 조각이라도 투영 불가면 null을 돌려
  /// 호출자가 기존 평면 화살표로 되돌아가게 한다.
  List<List<Offset>>? shaftSlices(
    double yawDegrees,
    Size size,
    int slices, {
    double widthScale = 1.0,
  }) {
    if (slices < 1) return null;
    final out = <List<Offset>>[];
    for (var i = 0; i < slices; i++) {
      final t0 = shaftLength * i / slices;
      final t1 = shaftLength * (i + 1) / slices;
      final quad = <Offset>[];
      for (final p in <List<double>>[
        [t0, -shaftWidth / 2 * widthScale],
        [t1, -shaftWidth / 2 * widthScale],
        [t1, shaftWidth / 2 * widthScale],
        [t0, shaftWidth / 2 * widthScale],
      ]) {
        final o = _pointAt(yawDegrees, p[0], p[1], size);
        if (o == null) return null;
        quad.add(o);
      }
      out.add(quad);
    }
    return out;
  }

  /// 화살표 머리(삼각형). 투영 불가면 null.
  List<Offset>? headPolygon(
    double yawDegrees,
    Size size, {
    double widthScale = 1.0,
  }) {
    final pts = <Offset>[];
    for (final p in <List<double>>[
      [shaftLength, -headWidth / 2 * widthScale],
      [shaftLength + headLength, 0],
      [shaftLength, headWidth / 2 * widthScale],
    ]) {
      final o = _pointAt(yawDegrees, p[0], p[1], size);
      if (o == null) return null;
      pts.add(o);
    }
    return pts;
  }

  /// 화살표 축을 따라 [along]m, 옆으로 [side]m 떨어진 지면점의 화면 좌표.
  Offset? _pointAt(double yawDegrees, double along, double side, Size size) {
    final yaw = yawDegrees * _deg;
    final ux = math.sin(yaw), uz = math.cos(yaw); // 진행 방향
    final px = math.cos(yaw), pz = -math.sin(yaw); // 좌우 방향
    return project(ux * along + px * side, tailZ + uz * along + pz * side, size);
  }
}
