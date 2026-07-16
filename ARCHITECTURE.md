# 횡단보도 이탈 감지 시스템 - 코드 설명 문서

시각 장애인이 횡단보도를 건널 때 좌/우 이탈 여부를 실시간으로 감지하고 음성+진동으로 알려주는 Android 앱 프로젝트입니다.

> **레거시 문서 안내**: 이 문서(`ARCHITECTURE.md`, 루트)는 architect 에이전트가 관리하지 않는 보조 설명 문서입니다.
> 최신 상태·근거 인용이 포함된 **공식 아키텍처 문서는 `docs/Architecture.md`**이며, 이 문서를 대체합니다
> (`README.md` "Documentation Index" 참조, `docs/Tasks.md` T14). 이 문서는 2026-07 시점 코드로 드리프트(누락/오류)
> 항목을 이번 업데이트에서 바로잡았으나, 상세 근거·§11 export 경로 검증·CI 단계별 인용 등은
> `docs/Architecture.md`(특히 §4 초기화 순서, §11.1/§11.2 export 검증, §9 CI)를 우선 참고하십시오.

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

- `dynamo=False` 옵션으로 구형 TorchScript 기반 exporter 사용 → 모바일 런타임 호환 목적 (`export_onnx.py:16` 코드 주석은 "IR version 8"이라고 적혀 있으나, **실제 검증된 값은 IR version 7**입니다 — Python `onnx.load()`로 현재 배포된 `crosswalk_model.onnx`를 직접 로드해 확인한 값이며, 스크립트 주석 자체의 오기입니다. 상세 검증 근거: `docs/Architecture.md` §11.1~§11.2)
- `opset_version=12` 사용 (모바일 ONNX Runtime이 지원하는 안정적인 버전)
- 참고: `train_model.py`의 내장 `export_onnx()`는 별도로 `opset_version=17`을 사용하며 실제 배포 모델을 생성한 스크립트가 아닙니다 — 배포된 모델(`ir_version=7`, `opset=12`)과 설정이 일치하는 쪽은 이 `export_onnx.py`입니다 (`docs/Architecture.md` §11.1)

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

#### 초기화 순서 (`_initCamera`, `camera_screen.dart:54-140`)

재진입 방지 가드(`_isInitializing`, `camera_screen.dart:55-56`)로 감싸져 있으며, 전체가 `try/finally` 구조입니다.
실제 순서는 문서에 예전부터 있던 순서와 다르며, TTS를 **가장 먼저** 초기화합니다 — 이후 어떤 단계에서 오류가
나더라도 음성으로 안내할 수 있어야 하기 때문입니다 (`camera_screen.dart:66` 코드 주석).

```
TTS/진동 초기화 (FeedbackService.init)               ← camera_screen.dart:67
    ↓
카메라 권한 요청 (Permission.camera.request())        ← camera_screen.dart:69
    ├─ 거부 + isPermanentlyDenied → 설정 화면 안내 문구, _permissionPermanentlyDenied=true ← :71-81
    └─ 일반 거부 → 오류 안내 후 재시도 유도                                                ← :82-90
    ↓ (권한 허용 시에만 계속)
ONNX 모델 로드 (Classifier.init) — ModelIntegrityException 시 "모델 손상" 오류 화면 ← :94-95,129-138
    ↓
후면 카메라 연결 (YUV420 포맷, 중간 해상도, lockCaptureOrientation)  ← :97-123
    ↓
프레임 스트림 시작 (startImageStream)                  ← camera_screen.dart:127
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

#### 주요 상수 (`classifier.dart:24-33`)

| 상수 | 값 | 설명 |
|------|----|------|
| `_inputSize` | `224` | 모델 입력 크기 |
| `_smoothingWindow` | `5` | 평균낼 최근 프레임 수 |
| `_deviationThreshold` | `0.55` | `left`/`right` 판정 최소 확률 — 이탈은 민감하게 감지 |
| `_frontThreshold` | `0.85` | `front` 판정 최소 확률 — 정상 확인은 엄격하게 (비대칭 임계값, `classifier.dart:28-30` 주석) |
| `_throttleFrames` | `5` | N프레임마다 1번만 추론 (과거 `10`에서 하향 — `classifier.dart:32` 주석: "이탈 감지 지연 단축") |

두 임계값으로 나뉜 이유는 이탈(위험)을 놓치는 것이 정상을 오탐하는 것보다 더 위험하다는 판단입니다
(`classifier.dart:28` 주석, `docs/Architecture.md` §14 리스크 표에도 동일 근거 기재).

#### 처리 흐름 (`classifier.dart:88-148`)

모델은 **raw logits**을 출력합니다 — ONNX 그래프에 Softmax 노드가 없습니다(마지막 연산: `Flatten→Gemm→HardSigmoid→Mul→Gemm`,
`docs/Architecture.md` §15 항목 A). 따라서 추론 직후 반드시 softmax를 거쳐 확률로 변환한 뒤 스무딩합니다.

```
카메라 프레임 (YUV420 or BGRA)
    ↓
_preprocessCamera: YUV420 → RGB 변환 → 224×224 리사이즈           (classifier.dart:150-187)
    ↓
NCHW 포맷 변환 + ImageNet 정규화
    (mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225])
    ↓
OrtSession.run() 추론 → raw logits                                (classifier.dart:98-107)
    ↓
softmax(logits) — 수치적으로 안정적인 구현 (max 차감 후 exp)        (classifier.dart:125,194-199)
    ↓
최근 5프레임 확률 평균 (스무딩)                                     (classifier.dart:127-135)
    ↓
label별 임계값 검사: front는 0.85, left/right는 0.55 미만이면 null   (classifier.dart:144-145)
    ↓
ClassificationResult(label, confidence) 반환
```

#### 스로틀링 (`classifier.dart:32-33,116-119`)

매 5프레임마다 1번만 추론하여 CPU 부하를 줄입니다. 30fps 카메라 기준 약 6fps로 추론 (과거 10프레임/약 3fps에서 단축).

#### 모델 무결성 검증 (`_verifyModelIntegrity`, `classifier.dart:66-86`)

번들 모델(`assets/model/crosswalk_model.onnx`)의 SHA-256 해시를 `crosswalk_model.onnx.sha256`와 비교합니다.
해시 파일이 없거나 64자가 아니거나 `placeholder_hash`이면 검증을 건너뜁니다 — **현재 저장소에는 placeholder 해시만
있어 사실상 비활성 상태**이며 (`docs/PRD.md` 추적 중인 갭), 불일치 시 `ModelIntegrityException`을 던져
`camera_screen.dart:129-138`에서 "모델 손상" 오류 화면으로 처리합니다.

#### 세션/환경 수명주기 (`classifier.dart:39-64,226-233`)

- `OrtEnv.instance.init()`은 호출할 때마다 네이티브 리소스를 새로 생성하고 이전 포인터를 해제하지 않으므로
  (onnxruntime 1.4.1), `_envInitialized` 플래그로 **인스턴스당 최초 1회만** 초기화합니다.
- `init()` 재호출(앱 재개, 재시도) 시 이전 `OrtSession`을 먼저 `release()`한 뒤 새로 생성해 세션 누수를 방지합니다.
- `init()` 재호출 시 `_recentProbs`/`_frameCount`도 초기화합니다 — 이전 실행의 스무딩 상태가 남아 재개 직후
  판정이 지연되는 것을 방지합니다.
- `dispose()`에서 세션 해제 후 `OrtEnv.release()`를 호출하고 `_envInitialized`를 다시 `false`로 되돌립니다.

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
- `alert()`는 새 메시지를 말하기 전 `_tts.stop()`을 먼저 호출합니다(`feedback_service.dart:42`) — iOS의
  `AVSpeechSynthesizer`가 기본적으로 발화를 큐잉하므로, 이 처리가 없으면 이미 상황이 바뀐 뒤에도 오래된
  left/right 안내가 뒤늦게 재생될 수 있었던 문제(수정됨)입니다.
- 초기화 실패 등 오류 안내용 `announceError()`도 동일하게 `stop()` 후 `speak()`합니다(`feedback_service.dart:51-54`),
  `camera_screen.dart`의 각 오류 분기에서 호출됩니다.

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

#### 빌드 단계 (`.github/workflows/build_apk.yml:20-127`)

1. 코드 체크아웃 (`build_apk.yml:20-21`)
2. Java 17 설정 (Temurin) (`:23-27`)
3. Flutter 3.32.2 설정 (캐시 활성화) (`:29-34`)
4. ONNX 모델 파일 확인 및 SHA-256 해시 생성 (없으면 `placeholder`/`placeholder_hash`로 대체) (`:36-50`)
5. `flutter pub get` (`:52-54`)
6. **`flutter test`** ("Flutter 테스트" 단계 — 테스트 실패 시 빌드 중단) (`:56-58`)
7. `flutter build apk --release` — **`--no-shrink` 플래그는 사용하지 않습니다** (실제 워크플로우에 없음) (`:60-62`)
8. **APK 서명**: `KEYSTORE_BASE64` 시크릿이 있으면 base64 디코딩 → `zipalign` → `apksigner sign`으로 수동 서명,
   시크릿이 없으면 미서명 APK로 건너뜀 (`:64-95`)
9. APK를 Artifacts로 업로드 — 서명본/미서명본 둘 다 시도, 30일 보관 (`:97-105`)
10. 빌드 요약 출력 — 서명 상태/파일 크기/커밋/브랜치를 `$GITHUB_STEP_SUMMARY`에 기록 (`:107-127`)

빌드된 APK는 GitHub Actions → 해당 워크플로우 실행 → Artifacts에서 다운로드할 수 있습니다.

#### 릴리스 서명 가드 (`crosswalk_app/android/app/build.gradle.kts:33-54`)

`release` 빌드 타입은 CI 환경(`GITHUB_ACTIONS=true`) 또는 `-PallowDebugSigningForRelease=true` 플래그가 없으면
`GradleException`을 던져 빌드를 중단시킵니다 — 디버그 키로 서명된 릴리스 APK가 실수로 배포되는 것을 막기 위함입니다.
CI에서는 일단 디버그 키로 서명한 뒤, 위 "APK 서명" 단계가 실제 릴리스 키로 재서명합니다.

---

## 4. 의존성 패키지 (`pubspec.yaml`)

| 패키지 | 역할 |
|--------|------|
| `camera` | 카메라 프레임 스트림 |
| `onnxruntime` | ONNX 모델 추론 엔진 |
| `flutter_tts` | 한국어 음성 안내 |
| `vibration` | 진동 피드백 |
| `image` | YUV420→RGB 이미지 처리 |
| `permission_handler` | 카메라 권한 요청 (일반 거부/영구 거부(`isPermanentlyDenied`) 분기 처리, `camera_screen.dart:71`) |
| `wakelock_plus` | 화면 꺼짐 방지 |
| `crypto` | 모델 파일 SHA-256 무결성 검증 (`classifier.dart:66-86`) — 현재 placeholder 해시로 사실상 비활성 |

---

## 전체 데이터 흐름

```
[카메라 프레임]
      ↓
[Classifier] YUV420 디코딩 → 전처리 → ONNX 추론(logits) → softmax → 스무딩 → 임계값 판정
      ↓
[ClassificationResult] label + confidence
      ↓
[CameraScreen] UI 업데이트 (색상 + 텍스트 + 신뢰도)
      ↓
[FeedbackService] TTS 음성 + 진동 (이탈 시에만)
```
