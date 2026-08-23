// T54: 모델 <-> 라벨 동기화 안전장치.
//
// 배경 — 이 프로젝트에서 세 번 같은 사고가 났다:
//   T42(3->4 class), T51(4->5 class), 그리고 T51 브랜치에서 `_labels`만
//   5개로 바꾸고 4-class ONNX 에셋을 그대로 둔 상태.
// 셋 다 **에러 없이** 잘못된 라벨을 내놓는다. 로짓 인덱스와 라벨 배열이
// 어긋나도 앱은 태연히 동작하기 때문이다(안전 기능이므로 조용한 오작동이
// 가장 나쁜 실패 모드다).
//
// 검증 사슬 (세 지점을 묶는다):
//   1) train/export_onnx.py 가 익스포트 직후 모델의 실제 출력 차원이
//      LABELS 개수와 같은지 assert 하고, 라벨 순서 + 그 모델 파일의
//      sha256을 assets/model/labels.json 에 기록한다.
//   2) 이 테스트: labels.json 의 labels == Classifier.labelsForTest
//   3) 이 테스트: labels.json 의 model_sha256 == 실제 번들 onnx 의 sha256
// (3)이 있어야 "라벨만 바꾸고 모델은 옛것" / "모델만 바꾸고 라벨은 옛것"
// 두 방향 모두 잡힌다.
//
// 파일 읽기에 rootBundle 대신 dart:io 를 쓰는 이유: `flutter test` 의 작업
// 디렉터리는 패키지 루트로 고정되어 있어 경로가 결정적이고, 에셋 번들
// 초기화에 의존하지 않아 실패 원인이 모호해지지 않는다.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:crosswalk_app/services/classifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const labelsPath = 'assets/model/labels.json';
  const modelPath = 'assets/model/crosswalk_model.onnx';

  test('labels.json이 앱 에셋에 존재한다', () {
    expect(
      File(labelsPath).existsSync(),
      isTrue,
      reason: '$labelsPath 없음 — train/export_onnx.py 를 실행해 생성할 것',
    );
  });

  test('labels.json의 라벨 순서가 Classifier._labels와 정확히 일치한다', () {
    final json =
        jsonDecode(File(labelsPath).readAsStringSync()) as Map<String, dynamic>;
    final fromFile = (json['labels'] as List).cast<String>();

    // 순서까지 같아야 한다. 집합만 같고 순서가 다르면 로짓이 엉뚱한 라벨에
    // 매핑되며, 그게 정확히 T42에서 겪은 사고다.
    expect(
      fromFile,
      orderedEquals(Classifier.labelsForTest),
      reason: '모델 출력 인덱스 순서와 앱 라벨 배열이 어긋남 — 조용한 오분류 발생',
    );
    expect(json['num_classes'], equals(Classifier.labelsForTest.length));
  });

  test('labels.json이 가리키는 모델이 실제 번들된 모델과 같은 파일이다', () {
    final modelFile = File(modelPath);
    expect(
      modelFile.existsSync(),
      isTrue,
      reason: '$modelPath 없음',
    );

    // CI(build_apk.yml)는 실모델이 없으면 'placeholder' 텍스트로 대체한다.
    // 그 경우 해시 대조는 의미가 없으므로 건너뛴다 — 실모델이 있을 때만
    // 검사한다는 사실을 감추지 않기 위해 명시적으로 분기한다.
    final bytes = modelFile.readAsBytesSync();
    if (bytes.length < 1024) {
      markTestSkipped('번들 모델이 placeholder(${bytes.length}B) — 해시 대조 생략');
      return;
    }

    final json =
        jsonDecode(File(labelsPath).readAsStringSync()) as Map<String, dynamic>;
    expect(
      sha256.convert(bytes).toString(),
      equals(json['model_sha256']),
      reason: 'labels.json과 번들 onnx가 서로 다른 익스포트에서 왔음 — '
          '한쪽만 갱신된 상태. train/export_onnx.py 재실행 후 모델을 함께 복사할 것',
    );
  });
}
