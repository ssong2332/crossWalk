# Database — crosswalk_app (횡단보도 이탈 감지)

Owner: architect (see AGENTS.md). Others read-only.
Last updated: 2026-07-16. Basis: `crosswalk_app/lib/**`, `crosswalk_app/pubspec.yaml`.

## 결론: 데이터베이스 없음, 영속 저장소 없음

이 앱에는 **데이터베이스도, 로컬 영속 저장소(설정/키-값 포함)도 없습니다.** 모든 상태는 앱 실행 중 메모리에만 존재하며 종료 시 사라집니다.

증거:
| 확인 항목 | 결과 | 근거 |
|---|---|---|
| SQLite / drift / sqflite | 없음 | grep `sqlite\|drift\|sqflite` in `lib/` → 0건 |
| Hive / Isar / ObjectBox / Sembast | 없음 | grep `hive\|isar\|objectbox\|sembast` in `lib/` → 0건 |
| shared_preferences (설정 키-값) | 없음 | grep `shared_preferences\|SharedPreferences` in `lib/` → 0건 |
| 파일 쓰기 / path_provider | 없음 | grep `path_provider\|writeAsString\|File(` in `lib/` → 0건 |
| pubspec 의존성 | 저장소 패키지 없음 | `pubspec.yaml:10-20` (camera/onnxruntime/tts/vibration/image/permission/wakelock/crypto만) |

## 메모리 전용(휘발성) 상태 — 참고

DB는 아니지만, 런타임에만 유지되는 상태는 다음과 같습니다(종료 시 소멸):

| 상태 | 위치 | 근거 |
|---|---|---|
| 최근 5프레임 확률 (스무딩 윈도우) | `Classifier._recentProbs` | `classifier.dart:35,90-91` |
| 프레임 카운터 (스로틀) | `Classifier._frameCount` | `classifier.dart:34,68` |
| 마지막 알림 시각/클래스 (쿨다운) | `FeedbackService._lastAlertTime/_lastAlertClass` | `feedback_service.dart:6-7,27-28` |
| UI 상태 (라벨/신뢰도/오류) | `_CameraScreenState` 필드 | `camera_screen.dart:21-24` |

## 번들 에셋 (읽기 전용, DB 아님)

| 에셋 | 용도 | 근거 |
|---|---|---|
| `assets/model/crosswalk_model.onnx` | ONNX 추론 모델 (읽기 전용, APK 내장) | `pubspec.yaml:30`, `classifier.dart:39` |
| `assets/model/crosswalk_model.onnx.sha256` | 무결성 해시 (현재 `placeholder_hash`, 검증 비활성) | `classifier.dart:47-53`, `assets/model/crosswalk_model.onnx.sha256:1` |

## 향후

설정 화면/온보딩(PRD F16, Tasks T19)이나 사용자 캘리브레이션이 추가되면 그때 `shared_preferences` 수준의 키-값 저장이 필요할 수 있음. 현재 스코프에는 없으며, 추가 시 이 문서에 스키마/키를 정의할 것. 관련 결정: `docs/PRD.md` Open Question #8, #14.
