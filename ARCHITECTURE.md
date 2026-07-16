# 횡단보도 이탈 감지 시스템 - 코드 설명 문서

시각 장애인이 횡단보도를 건널 때 좌/우 이탈 여부를 실시간으로 감지하고 음성+진동으로 알려주는 Android 앱 프로젝트입니다.

---

## 프로젝트 구조

```
crossWalk/
├── train/                  # AI 모델 학습 파이썬 코드
│   ├── train_model.py      # 모델 학습 메인 스크립트
│   ├── export_onnx.py      # 학습된 모델 → ONNX 변환
│   └── convert_to_tflite.py# ONNX → TFLite 변환 (미사용, 대체됨)
├── model/                  # 학습 결과물
│   ├── crosswalk_model.pt  # PyTorch 가중치
│   ├── crosswalk_model.onnx# 앱에서 사용하는 ONNX 모델
│   └── confusion_matrix.png# 모델 평가 결과
├── image/                  # 학습용 원본 이미지
│   ├── front/              # 정방향 이미지
│   ├── left/               # 왼쪽 이탈 이미지
│   └── right/              # 오른쪽 이탈 이미지
├── crosswalk_app/          # Flutter 앱 (실제 배포용)
│   └── lib/
│       ├── main.dart
│       ├── screens/
│       │   └── camera_screen.dart
│       └── services/
│           ├── classifier.dart
│           └── feedback_service.dart
└── .github/workflows/
    └── build_apk.yml       # GitHub Actions 자동 빌드
```

---

## 1. AI 모델 학습 (`train/`)

### `train_model.py` - 학습 메인 스크립트

전체 학습 파이프라인을 단계별로 실행합니다.

#### 주요 설정값

| 상수 | 값 | 설명 |
|------|-----|------|
| `CLASSES` | `["front", "left", "right"]` | 분류 클래스 |
| `FRONT_SAMPLE` | `500` | front 클래스 최대 샘플 수 (데이터 불균형 방지) |
| `IMG_SIZE` | `224` | 입력 이미지 크기 (MobileNet 표준) |
| `BATCH_SIZE` | `32` | 배치 크기 |
| `EPOCHS_FROZEN` | `10` | 1차 학습 에폭 수 |
| `EPOCHS_FINETUNE` | `10` | 2차 파인튜닝 에폭 수 |

#### 학습 단계

**1단계 - 데이터 준비 (`prepare_data`)**
- `image/` 폴더의 원본 이미지를 `train/val/test` = `80%/10%/10%` 로 분할
- `front` 클래스는 최대 500장으로 제한 (원본 데이터가 left/right보다 훨씬 많아 불균형 발생 방지)

**2단계 - DataLoader 구성 (`get_loaders`)**
- 학습 데이터에 증강(Augmentation) 적용: 수평 뒤집기, ±15° 회전, 밝기/대비/채도 조정
- `WeightedRandomSampler`로 클래스 불균형 추가 보정 (희귀 클래스를 더 자주 샘플링)
- 검증/테스트 데이터는 증강 없이 정규화만 적용

**3단계 - 모델 구성 (`build_model`)**
- `MobileNet V3 Small` 사용 (ImageNet 사전학습 가중치)
- 마지막 분류 레이어만 `3개 출력`으로 교체

**4단계 - 학습 (`run_training`)**
- **1차 학습**: backbone(특징 추출 레이어)을 고정하고 분류기만 학습 (`lr=1e-3`)
- **2차 학습 (파인튜닝)**: 전체 레이어 해제 후 낮은 학습률로 전체 학습 (`lr=1e-4`)
- `CosineAnnealingLR` 스케줄러로 학습률 점진적 감소
- 검증 정확도가 최고일 때만 모델 저장
- `left`와 `right` 클래스에 높은 손실 가중치 적용 (이탈 미감지가 더 위험하므로)

  ```python
  weights_map = {"front": 1.0, "left": 10.0, "right": 20.0}
  ```

**5단계 - 평가 (`evaluate`)**
- 테스트 셋으로 precision/recall/F1 리포트 출력
- 혼동 행렬(confusion matrix) 이미지 저장

**6단계 - ONNX 변환 (`export_onnx`)**
- 학습 완료 후 `.pt` 모델을 `.onnx` 포맷으로 변환
- `opset_version=17`, dynamic batch 지원

---

### `export_onnx.py` - 별도 ONNX 변환 스크립트

`train_model.py`와 별개로 이미 저장된 `.pt` 파일을 ONNX로 변환할 때 사용합니다.

- `dynamo=False` 옵션으로 구형 TorchScript 기반 exporter 사용 → ONNX IR version 8 생성 (모바일 런타임 호환)
- `opset_version=12` 사용 (모바일 ONNX Runtime이 지원하는 안정적인 버전)

---

### `convert_to_tflite.py` - TFLite 변환 스크립트 (현재 미사용)

초기에 TFLite를 사용할 계획이었으나 앱이 ONNX Runtime으로 교체되면서 사용하지 않게 된 스크립트입니다.

두 가지 변환 방법을 시도합니다:
1. `onnx2tf` 라이브러리 사용 (INT8 양자화 포함)
2. `onnx-tf` + `tensorflow` 역방향 변환

두 방법 모두 실패할 경우 Google Colab에서 수동으로 변환하는 방법을 안내합니다.

---

## 2. Flutter 앱 (`crosswalk_app/`)

### `main.dart` - 앱 진입점

- 앱을 세로 방향(portrait)으로 고정
- 다크 테마 적용
- `CameraScreen`을 홈 화면으로 설정

---

### `screens/camera_screen.dart` - 카메라 화면 UI

앱의 메인 화면으로, 카메라 미리보기 위에 감지 결과를 오버레이합니다.

#### 초기화 순서 (`_initCamera`)

```
카메라 권한 요청
    ↓
ONNX 모델 로드 (Classifier.init)
    ↓
TTS/진동 초기화 (FeedbackService.init)
    ↓
후면 카메라 연결 (YUV420 포맷, 중간 해상도)
    ↓
프레임 스트림 시작
```

#### 프레임 처리 (`_onFrame`)

- `_isProcessing` 플래그로 프레임 중첩 처리 방지
- `Classifier.processFrame()` 호출 → 결과가 있으면 UI 업데이트 + 알림 발생

#### UI 구성

| 상태 | 색상 |
|------|------|
| 정상 진행 (front) | 초록색 |
| 왼쪽 이탈 (left) | 빨간색 |
| 오른쪽 이탈 (right) | 주황색 |

하단에 반투명 검정 바로 현재 상태 레이블과 신뢰도(%)를 표시합니다.

#### 앱 생명주기 관리

- 앱이 백그라운드로 가면 카메라 해제
- 앱이 다시 foreground로 오면 카메라 재초기화
- `WakelockPlus`로 화면 자동 꺼짐 방지

---

### `services/classifier.dart` - 추론 엔진

ONNX Runtime을 사용해 카메라 프레임을 실시간으로 분류합니다.

#### 주요 상수

| 상수 | 값 | 설명 |
|------|----|------|
| `_inputSize` | `224` | 모델 입력 크기 |
| `_smoothingWindow` | `5` | 평균낼 최근 프레임 수 |
| `_confidenceThreshold` | `0.70` | 결과 반환 최소 신뢰도 |
| `_throttleFrames` | `10` | N프레임마다 1번만 추론 |

#### 처리 흐름

```
카메라 프레임 (YUV420 or BGRA)
    ↓
_preprocessCamera: YUV420 → RGB 변환 → 224×224 리사이즈
    ↓
NCHW 포맷 변환 + ImageNet 정규화
    (mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225])
    ↓
OrtSession.run() 추론
    ↓
최근 5프레임 확률 평균 (스무딩)
    ↓
신뢰도 70% 미만이면 null 반환
    ↓
ClassificationResult(label, confidence) 반환
```

#### 스로틀링

매 10프레임마다 1번만 추론하여 CPU 부하를 줄입니다. 30fps 카메라 기준 약 3fps로 추론.

#### YUV420 → RGB 변환 (`_convertYUV420`)

Android 카메라의 기본 포맷인 YUV420을 RGB로 직접 변환합니다.

```
R = Y + 1.402 × (V - 128)
G = Y - 0.344136 × (U - 128) - 0.714136 × (V - 128)
B = Y + 1.772 × (U - 128)
```

---

### `services/feedback_service.dart` - 알림 서비스

이탈 감지 시 사용자에게 피드백을 제공합니다.

#### 알림 조건

- `front`(정상)일 때는 알림 없음
- 같은 클래스 + 3초 이내 재알림 억제 (쿨다운)
- 클래스가 바뀌면 즉시 새 알림 발생

#### 알림 수단

| 클래스 | 음성 메시지 | 진동 |
|--------|------------|------|
| `left` | "왼쪽으로 이탈했습니다. 오른쪽으로 이동하세요" | 500ms |
| `right` | "오른쪽으로 이탈했습니다. 왼쪽으로 이동하세요" | 500ms |

- TTS 언어: 한국어(`ko-KR`), 말하기 속도: 0.5(느리게)

---

## 3. CI/CD (`.github/workflows/build_apk.yml`)

GitHub Actions로 APK를 자동 빌드합니다.

#### 트리거 조건

- `develop` 브랜치에 push
- `master` 브랜치로 pull request

#### 빌드 환경

| 항목 | 버전 |
|------|------|
| OS | Ubuntu Latest |
| Java | 17 (Temurin) |
| Flutter | 3.32.2 stable |

#### 빌드 단계

1. 코드 체크아웃
2. Java 17 설정
3. Flutter 3.32.2 설정 (캐시 활성화)
4. ONNX 모델 파일 확인 (없으면 placeholder로 대체)
5. `flutter pub get`
6. `flutter build apk --release --no-shrink`
7. APK를 Artifacts로 업로드 (30일 보관)
8. 빌드 요약 출력

빌드된 APK는 GitHub Actions → 해당 워크플로우 실행 → Artifacts에서 다운로드할 수 있습니다.

---

## 4. 의존성 패키지 (`pubspec.yaml`)

| 패키지 | 역할 |
|--------|------|
| `camera` | 카메라 프레임 스트림 |
| `onnxruntime` | ONNX 모델 추론 엔진 |
| `flutter_tts` | 한국어 음성 안내 |
| `vibration` | 진동 피드백 |
| `image` | YUV420→RGB 이미지 처리 |
| `permission_handler` | 카메라 권한 요청 |
| `wakelock_plus` | 화면 꺼짐 방지 |

---

## 전체 데이터 흐름

```
[카메라 프레임]
      ↓
[Classifier] YUV420 디코딩 → 전처리 → ONNX 추론 → 스무딩
      ↓
[ClassificationResult] label + confidence
      ↓
[CameraScreen] UI 업데이트 (색상 + 텍스트 + 신뢰도)
      ↓
[FeedbackService] TTS 음성 + 진동 (이탈 시에만)
```
