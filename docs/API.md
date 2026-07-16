# API — crosswalk_app (횡단보도 이탈 감지)

Owner: architect (see AGENTS.md). Others read-only.
Last updated: 2026-07-16. Basis: `crosswalk_app/lib/**`, `train/train_model.py`.

## 결론: 네트워크 API 없음 (완전 오프라인 온디바이스 앱)

이 앱은 **네트워크 API가 없는 완전 오프라인 온디바이스 앱**입니다. 서버·REST·GraphQL·WebSocket·인증 엔드포인트가 존재하지 않습니다.

증거:
- grep `http | dio | HttpClient | websocket | firebase | supabase | graphql | Uri.` in `crosswalk_app/lib/` → 실질적 매치 0건 (유일 매치는 `camera_screen.dart:98`의 `enableAudio: false`로 무관).
- `pubspec.yaml:10-20`에 네트워크/HTTP 클라이언트 의존성 없음.
- PRD Goal (`docs/PRD.md:9`), Non-Functional "Offline operation" (`docs/PRD.md:46`).

따라서 REST 엔드포인트 표는 **해당 없음**. 대신 앱 내부의 실제 계약(모델 텐서 계약 + 서비스 메서드 계약)을 아래에 문서화합니다.

---

## 1. 내부 계약 — ONNX 모델 텐서 (실질적 "API 표면")

`OrtSession.run`에 전달/수신되는 텐서 계약. 이 계약을 어기면 추론이 실패합니다.

| 항목 | 값 | 근거 |
|---|---|---|
| Input 이름 | `input` | `classifier.dart:79`, `train_model.py:223` |
| Input shape | `[1, 3, 224, 224]` (NCHW, batch=1) | `classifier.dart:76,77`, dynamic batch `train_model.py:225` |
| Input dtype | `Float32` | `classifier.dart:74,136` (`Float32List`) |
| Input 정규화 | RGB, `/255` 후 ImageNet mean=[0.485,0.456,0.406] std=[0.229,0.224,0.225] | `classifier.dart:133-134,141-143` |
| Output 이름 | `output` (코드는 `outputs.first`로 위치 접근) | `train_model.py:224`, `classifier.dart:85` |
| Output shape | `[1, 3]` — 클래스 3개 | `classifier.dart:86-87` (`rawOutput.first` → 길이 3 리스트) |
| Output 순서 | `['front','left','right']` (인덱스 고정) | `classifier.dart:22`, `train_model.py:30` |
| Output 활성함수 | **미확인** — 학습 모델에 softmax 없음(`train_model.py:105-109`), 앱은 확률 임계값처럼 사용(`classifier.dart:107-108`) | Architecture.md §15 Open Q A / PRD Q#10 |

계약 위반 시 동작: 전처리 실패나 빈 출력이면 `processFrame`이 `null` 반환 (`classifier.dart:72-73,83`).

---

## 2. 내부 계약 — 서비스 메서드 (모듈 간 인터페이스)

앱 내부 모듈 경계의 호출 계약. UI(`CameraScreen`)가 서비스를 호출하는 방식.

### `Classifier`
| 메서드 | 시그니처 | 계약 | 근거 |
|---|---|---|---|
| `init()` | `Future<void>` | OrtEnv 초기화 → 에셋 로드 → 무결성 검증 → 세션 생성. 손상 시 `ModelIntegrityException` throw | `classifier.dart:37-43` |
| `processFrame(CameraImage)` | `ClassificationResult?` | 5프레임마다 1회만 추론, 임계값 미달/스로틀/전처리 실패 시 `null` | `classifier.dart:67-111` |
| `dispose()` | `void` | 세션·OrtEnv 해제 | `classifier.dart:177-180` |

`ClassificationResult` DTO: `{ String label, double confidence }` (`classifier.dart:8-12`).
`ModelIntegrityException`: `{ String message }` (`classifier.dart:14-19`).

### `FeedbackService`
| 메서드 | 시그니처 | 계약 | 근거 |
|---|---|---|---|
| `init()` | `Future<void>` | TTS ko-KR, rate 0.5, volume 1.0 설정 | `feedback_service.dart:11-15` |
| `alert(String detectedClass)` | `Future<void>` | `front`이면 무동작; 같은 클래스 3초 쿨다운; left/right → TTS+진동 500ms | `feedback_service.dart:17-39` |
| `announceError(String)` | `Future<void>` | 진행 중 TTS 중단 후 오류 메시지 발화 | `feedback_service.dart:42-45` |
| `dispose()` | `Future<void>` | TTS 중단 | `feedback_service.dart:47-49` |

---

## 3. 플랫폼 채널 / 커스텀 네이티브 API

앱이 직접 정의한 커스텀 `MethodChannel`/플랫폼 채널 **없음**. 카메라·TTS·진동·권한은 각 pub 패키지가 내부적으로 자체 채널을 사용하며, 앱 코드에 커스텀 채널 정의는 없음. 근거: grep `MethodChannel | EventChannel` in `lib/` → 0건.

---

## 4. 온라인 컴포넌트 의도 여부

"앞으로도 계속 오프라인 유지"는 제품 결정 → `docs/PRD.md` Open Question #4. 코드상 현재는 오프라인 확정.
