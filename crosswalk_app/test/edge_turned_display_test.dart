// T143(사용자 승인 2026-10-27): 끝에서 이미 중앙 쪽으로 틀어 "그대로"인 상태
// (front + 끝)의 화면 표시 — 제목 '왼쪽 끝' / '오른쪽 끝'(T158: '· 그대로' 뺌),
// 색은 일반 이탈 색. 표시 문자열 선택 로직을 확인한다.
import 'package:crosswalk_app/localization/app_strings.dart';
import 'package:crosswalk_app/screens/camera_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final ko = AppStrings.of(AppLanguage.ko);
  final en = AppStrings.of(AppLanguage.en);

  group('edgeTurnedHeadline (T143)', () {
    test('문구', () {
      expect(ko.labelLeftEdgeTurned, '왼쪽 끝');
      expect(ko.labelRightEdgeTurned, '오른쪽 끝');
      expect(en.labelLeftEdgeTurned, 'Left edge');
      expect(en.labelRightEdgeTurned, 'Right edge');
    });

    test('front + 끝이면 서 있는 쪽 끝', () {
      expect(edgeTurnedHeadline('front', true, -1.4, ko), '왼쪽 끝');
      expect(edgeTurnedHeadline('front', true, 1.0, ko), '오른쪽 끝');
      expect(edgeTurnedHeadline('front', true, -1.4, en),
          'Left edge');
    });

    test('일반 직진·이탈·끝 유도·위치 없음은 null(제목 종전대로)', () {
      expect(edgeTurnedHeadline('front', false, -1.4, ko), isNull);
      expect(edgeTurnedHeadline('left', true, -1.4, ko), isNull);
      expect(edgeTurnedHeadline('right', true, 1.4, ko), isNull);
      expect(edgeTurnedHeadline('none', true, -1.4, ko), isNull);
      expect(edgeTurnedHeadline('front', true, null, ko), isNull);
    });

    test('isEdgeTurnedDisplay: 이탈 색은 front + 끝일 때만', () {
      expect(isEdgeTurnedDisplay('front', true), isTrue);
      expect(isEdgeTurnedDisplay('front', false), isFalse);
      expect(isEdgeTurnedDisplay('left', true), isFalse);
      expect(isEdgeTurnedDisplay('nocall', true), isFalse);
    });
  });
}
