/// T104: 실기기 추론 시간 측정용 기록기(측정 전용 — 안내 동작과 무관).
///
/// 키별로 최근 [window]개의 소요 시간(ms)을 모아 중앙값·최댓값을 낸다.
/// 순수 Dart라 플랫폼 채널 없이 테스트할 수 있다.
class FrameBench {
  FrameBench({this.window = 30});

  final int window;
  final Map<String, List<double>> _samples = {};

  void add(String key, double ms) {
    final list = _samples.putIfAbsent(key, () => <double>[]);
    list.add(ms);
    if (list.length > window) list.removeAt(0);
  }

  int count(String key) => _samples[key]?.length ?? 0;

  double? median(String key) {
    final list = _samples[key];
    if (list == null || list.isEmpty) return null;
    final s = [...list]..sort();
    final mid = s.length ~/ 2;
    return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2;
  }

  double? max(String key) {
    final list = _samples[key];
    if (list == null || list.isEmpty) return null;
    return list.reduce((a, b) => a > b ? a : b);
  }

  void clear() => _samples.clear();

  /// 디버그 박스 한 줄. 값이 없는 키는 '-'.
  String summary() {
    String f(String k) {
      final v = median(k);
      return v == null ? '-' : v.toStringAsFixed(0);
    }

    final frameMax = max('frame');
    return '측정(ms, 중앙값): 분류 ${f('cls')} · 각도 ${f('angle')} · '
        '위치 ${f('pos')} · 분할 전처리 ${f('seg_pre')}+추론 ${f('seg_inf')}'
        '+출력 ${f('seg_out')} · 프레임 ${f('frame')}'
        '(최대 ${frameMax == null ? '-' : frameMax.toStringAsFixed(0)})';
  }
}
