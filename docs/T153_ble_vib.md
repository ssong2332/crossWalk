# T153 — 중간안 하드웨어: BLE 좌우 진동 모듈

작성 2026-10-29. 중간안(사용자 결정 2026-10-29, `docs/HardwarePlan.md` §0-1): 폰은 가슴 하네스, 지금 앱·폰 카메라 그대로, 새 하드웨어는 BLE 좌우 진동 모듈 하나.

## 금지 (이 문서를 고치는 사람용)
- 실행하지 않은 빌드·시험을 "됨"으로 적지 않는다. 실물(부품)로 확인한 것은 아직 없다.
- 추정 값은 "추정"으로 둔다.
- 카메라 입력·판정 코드는 이 작업 범위가 아니다(바꾸지 않았다).

## 결론

| 항목 | 결과 | 이전/기준값 | 근거 |
|---|---|---|---|
| 앱 테스트 (로컬 명령) | **`+668 ~6: All tests passed!`** (종료 0) | 이 변경 전 647개 + 건너뜀 6 (668 − 새 테스트 21로 계산, 추정 — master에서 따로 돌리지 않음) | `crosswalk_app/build/t153_test.log` 마지막 줄 |
| 새 단위 테스트 | `test/vib_module_test.dart` 21개 (규약 6 · 연결 관리 9 · FeedbackService 출력 경로 6) | 0 | 같은 로그 |
| 모듈 없을 때 폰 진동 동작 | **종전과 같음** — 모듈을 붙이지 않으면 `vib` 줄에 `out`이 없고 `Vibration.vibrate` 경로 그대로 | 종전 | `feedback_service.dart` `_sendToVibModule`이 null을 돌려줌, 시험 "모듈이 없으면 vib 줄은 종전 형식 그대로" |
| 끊기면 | 폰 진동으로 대체(`out`=phone) + 음성 1번 "진동 모듈 연결이 끊겼습니다. 폰 진동으로 바꿉니다" (P1) | `docs/HardwarePlan.md` §4 | 시험 "끊기면 폰으로 대체 + 음성 1번" |
| 진동 뜻 | left → 오른쪽 모터, right → 왼쪽 모터, 복귀·차도·블록 위 → 양쪽 | 가야 할 쪽이 울림(§1) | `vib_module.dart` `sideForKind`, 시험 "가야 할 쪽이 울림" |
| BLE 패키지 | **`universal_ble` 1.2.0 정확한 판 고정** (BSD 3-Clause, 2026-02-28). 2.x·3.x는 지금 Flutter에서 안드로이드 빌드 설정 오류 | T152 추천 `universal_ble` 최신(3.1.2)보다 2주 이상 된 판 | §2-4 |
| 펌웨어 규약 시험 (호스트 g++) | **통과: 검사 39개, 실패 0개** | — | `hardware/vib_module/README.md` §시험 |
| 펌웨어 전체 빌드 | **못 함** — 이 PC에 Arduino IDE·arduino-cli·PlatformIO·ESP-IDF 없음 | — | §1-2 |
| 안드로이드 APK 빌드 (로컬) | **확인 못 함.** 1.2.0은 Gradle 설정 단계를 넘었지만, 그 뒤 `camera_android_camerax` 컴파일이 이 PC의 Kotlin 데몬 메모리 오류로 실패 — `universal_ble` 컴파일까지 가지 못함. Gradle 메모리 설정은 바꾸지 않았다(우회 금지) | CI만 검증 (`CLAUDE.md` Build 행) | §2-4, PR CI |
| 착용 위치 | **허리 벨트 앞쪽 좌·우(골반 바로 위)** — 사용자 결정 2026-10-29. `HardwarePlan.md` §1·§0-1 수정, H2 행 + §5-3은 '허리 앞쪽 맞히기 10회 + 걸을 때 5회' 확인 시험 하나 | §1 "가슴 하네스 어깨끈"(2026-10-12) | §3 |
| 사용자가 살 부품 | 진동 모듈 31,100원 + 하네스 14,500원 + 허리 벨트 14,400원 = **60,000원** (배송비·전선·스위치·벨크로 등 별도, 추정) | A안 전체 301,014원 (T152 §2) | §4 |
| 납땜 | **필요** (배터리 → XIAO 뒷면 패드는 납땜뿐. 헤더 핀·모터 연장선도 필요할 것, 추정) | — | §4-2 |

## 1. 펌웨어 (`hardware/vib_module/`)

### 1-1. 파일

| 파일 | 내용 |
|---|---|
| `vib_module.ino` | XIAO ESP32-C3, Arduino(esp32 보드 패키지 3.x). BLE 서버, 명령 받기, 모터 PWM, 끊김 처리 |
| `vib_protocol.h` | 명령 해석·진동 재생(스스로 끔)·3초 무응답 감시·세기→듀티. Arduino에 기대지 않음 |
| `test/host_test.cpp` | 위 헤더 호스트 시험 (앱 시험과 같은 바이트 예시) |
| `README.md` | 규약 v1 확정본, 배선, 납땜, 빌드, 올리는 방법 |

Arduino를 고른 이유: 사용자가 IDE에서 "업로드" 한 번으로 올릴 수 있고, Seeed 시작 안내가 Arduino 기준이며, BLE 라이브러리가 보드 패키지에 들어 있다(README §왜 Arduino인가).

### 1-2. 빌드 결과

| 무엇 | 명령 | 결과 |
|---|---|---|
| 규약 호스트 시험 | `mkdir -p hardware/vib_module/build && g++ -std=c++17 -Wall -Wextra -o hardware/vib_module/build/host_test.exe hardware/vib_module/test/host_test.cpp && hardware/vib_module/build/host_test.exe` (Git Bash, 저장소 루트) | `검사 39개, 실패 0개`, 종료 0 (g++ 16.1.0 MinGW-W64, 2026-10-29) |
| 펌웨어 전체 | `arduino-cli compile --fqbn esp32:esp32:XIAO_ESP32C3 hardware/vib_module` (README) | **실행 못 함.** `which arduino-cli pio platformio idf.py` → 없음, `%LOCALAPPDATA%\Arduino15` 없음. 보드 패키지(컴파일러 포함)를 내려받아야 해서 승인 없이 설치하지 않았다 |

### 1-3. 규약 v1 (T152 §3 초안에서 바뀐 것)

| 항목 | 초안 | v1 | 이유 |
|---|---|---|---|
| PULSE | `01 side dur seq` | `01 side dur str seq` | 작업 지시의 "세기". 착용 시험에서 세기 비교 |
| PATTERN | `02 side n … seq` | `02 side str n … seq` | 같음 |
| TEST 0x11 | 있음 | 없음 | 앱 시험 버튼이 실제 방향 진동과 같은 PULSE 150ms를 보냄 |
| 끊김 시 기기 | 끄고 길게 1번(500ms, 추정) | 같음 + 연결된 적이 있을 때만, 한 번만 | 켜자마자 울리지 않게 |
| 앱 화면 꺼짐·일시정지 | STOP 뒤 연결 해제 | **STOP만, 연결 유지** | 끊으면 다시 켤 때마다 "끊겼습니다"·"연결되었습니다"가 나온다. 앱이 죽으면 기기가 3초 무응답으로 끈다 |

UUID·바이트 표: `hardware/vib_module/README.md` §규약 v1.

## 2. 앱

### 2-1. 바꾼 곳

| 파일 | 바꾼 것 |
|---|---|
| `lib/services/vib_module.dart` (새) | 규약 바이트(`VibModuleProtocol`), 상태 해석, 연결 관리(`VibModuleController`: 1초 PING, 3초 무응답 = 끊김, 3초마다 다시 찾기, 끊김·연결 음성 알림 1번, 기록) |
| `lib/services/vib_module_ble.dart` (새) | `universal_ble`로 찾기(서비스 UUID 필터)·연결·STATUS 구독·응답 없는 쓰기 |
| `lib/services/feedback_service.dart` | `_vibrate()`·`surfaceAlert()`의 폰 진동 앞에 모듈 보내기 한 단계. 모듈이 없으면(null) 지나간다. `vibrationLogData`에 `out` 선택 키. `stopDirectionVibration`이 STOP도 보냄. 판정·박자(`decidePattern`, `DirectionRepeatTimer`)는 그대로 |
| `lib/screens/settings_screen.dart` | 구역 "진동 모듈 (개발)": 연결 스위치(기본 꺼짐), 상태 글자, 폰 진동도 함께(기본 꺼짐 = 모듈만), 세기 3단계, 왼쪽/오른쪽/양쪽 시험 |
| `lib/screens/camera_screen.dart` | 설정 값을 컨트롤러·FeedbackService에 전달, 일시정지 때 STOP, 화면 종료 때 끊기. 카메라·판정 코드는 손대지 않음 |
| `lib/localization/app_strings.dart` | 한·영 문구 19개 |
| `android/app/src/main/AndroidManifest.xml` | `BLUETOOTH_SCAN`(neverForLocation)·`BLUETOOTH_CONNECT`, Android 11 이하 위치(maxSdk 30), `bluetooth_le` required=false |
| `pubspec.yaml` | `universal_ble: 1.2.0` (범위 없는 정확한 판, §2-4) |
| `docs/EventLog.md` | 새 사건 `ble`·`ble.cmd`·`ble.pong`·`ble.err`·`ble.test`, `vib`의 `out`, `set` 키 3개 |

### 2-4. BLE 패키지를 1.2.0으로 고정한 이유 (오케스트레이터 승인 2026-10-29)

| 항목 | 내용 |
|---|---|
| 조건 | Flutter 3.32.2 (Dart 3.8.1), AGP 8.7.3, Kotlin 2.1.0 (`android/settings.gradle.kts:21-22`) |
| 2.x 오류 | `universal_ble` 2.3.0 로컬 디버그 빌드: `> Could not find method kotlin() for arguments [...] on project ':universal_ble' of type org.gradle.api.Project.` (`build.gradle` line 64, `crosswalk_app/build/t153_debug_build2.log:11`). 원인: 그 판의 `android/build.gradle`이 `kotlin { compilerOptions {...} }` 블록을 쓰면서 Kotlin 플러그인을 적용하지 않는다. 2.1.1·2.2.0·3.0.1도 같은 구조(내려받아 확인) |
| 1.2.0 | `apply plugin: 'kotlin-android'`, kotlin 1.7.10, AGP 7.3.0 classpath, Dart `>=3.1.3 <4.0.0`. 로컬 빌드에서 위 설정 오류가 나지 않았다 |
| 라이선스 | **BSD 3-Clause** ("Copyright (c) 2024, Navideck Labs OÜ", 1.2.0 묶음의 `LICENSE`). 저장소 https://github.com/Navideck/universal_ble |
| 로컬 컴파일 | 확인 못 함: `crosswalk_app/build/t153_debug_build3.log` — Kotlin 데몬 `Could not reserve enough space for object heap`(:6) 뒤 `:camera_android_camerax:compileDebugKotlin` 실패. 이번 변경과 무관한 이 PC 환경 문제로 보이며(추정), Gradle 메모리 설정으로 우회하지 않았다. 컴파일 확인은 PR의 CI "APK 빌드"로 한다. CI가 실패하면 다른 패키지로 바꾸지 않고 멈춰 보고한다 |
| 빠진 옵션 `legacy` | 기능 차이 없음(소스 확인): 1.2.0은 API 26 이상에서 늘 `setLegacy(false)` + `PHY_LE_ALL_SUPPORTED`로 스캔한다(`UniversalBlePlugin.kt:171-175`). 안드로이드는 이때 구형(legacy) 광고도 함께 보고하므로(안드로이드 `ScanSettings` 문서 기준, 실기기 미확인) ESP32 구형 광고 패킷을 찾을 수 있다 — 2.3.0 README의 `legacy: true` 권고는 확장 광고만 걸러 보는 경우를 피하려는 것으로 보인다(추정). 실기기에서 `CW-VIB`가 안 잡히면 이것부터 의심한다 |

### 2-2. 출력 판정표 (진동 1번마다)

| 설정 '진동 모듈 연결' | 모듈 상태 | '폰 진동도 함께' | 나가는 곳 | `vib` 줄 `out` |
|---|---|---|---|---|
| 꺼짐 (기본) | — | — | 폰 (종전) | 없음 (종전 형식) |
| 켬 | 연결됨 | 꺼짐 (기본) | 모듈만 | ble |
| 켬 | 연결됨 | 켬 | 모듈 + 폰 | both |
| 켬 | 찾는 중·끊김·권한 없음 | — | 폰 | phone |

### 2-3. 시험 (`test/vib_module_test.dart`)

| 묶음 | 확인하는 것 |
|---|---|
| 규약 바이트 | 가야 할 쪽 모터, PULSE/PATTERN/STOP/PING 바이트, 4쌍 상한, 길이 상·하한, STATUS 해석 |
| 연결 관리 | 연결 시 알림 1번, PING→PONG 왕복 ms, 3초 무응답 = 끊김(알림 1번, 그 뒤 안 보냄), PONG이 오면 유지, 연결 끊김 사건 → 다시 연결 `re`, 실패·권한 거절, 쓰기 실패 = 끊김, 설정 끔은 알림 없음, `ble.cmd` 기록 |
| FeedbackService | 모듈 없음 = 종전 형식, 연결 = 모듈만·오른쪽 모터, 폰 함께 = both, 끊김 = phone + 음성 1번, 차도 = 양쪽 PATTERN, 떼면 종전 |

실행 결과:

명령(`CLAUDE.md` Verified Commands, Git Bash, `crosswalk_app/`): `mkdir -p build/test_tmp && TEMP="$(pwd -W)/build/test_tmp" TMP="$(pwd -W)/build/test_tmp" /c/flutter/bin/flutter.bat test`

```
01:54 +668 ~6: All tests passed!
exit 0
```

1차 실행에서 1개 실패(`+667 ~6 -1`)는 내 시험 기대값 잘못이었다: 차도 패턴 `[0,125,125,125,125,125]`은 켜기 3·끄기 2라 마지막 끄기가 0이 맞다(`Expected ... 13, 9` / `Actual ... 0, 9`). 앱·호스트 시험·README 예시를 고쳐 다시 돌렸다.

## 3. 착용 위치 (사용자 결정 2026-10-29)

| 항목 | 내용 |
|---|---|
| 결정 | 진동 모듈 = **허리 벨트 앞쪽 좌·우(골반 바로 위)**. 폰 = 가슴 하네스 → 착용물 2개 |
| 배치 | 마이컴·배터리는 벨트 가운데나 한쪽(주머니), 모터 2개는 전선으로 좌우에 |
| 근거 | 시각장애인 대상 허리 벨트 연구에서 허리 앞쪽이 방향 지시에 가장 좋았다(PeerJ 2017, 표본 8명 — 오케스트레이터 전달, 원문 재확인 안 함) |
| 문서 | `docs/HardwarePlan.md` §1 진동 위치(어깨끈 → 허리 앞쪽), §0-1, §5-2 H2 행 |
| 확인 시험 | §5-3: 서서 좌우 맞히기 10회(순서표 고정) + 세기 3단계 체감 + 걸으며 5회. 통과 = 10/10, 5/5, 헷갈림 없음 |

## 4. 사용자가 할 일

### 4-1. 살 부품 (T152 §2 중 진동 모듈 부분 + 하네스, 2026-10-29 조회가)

| # | 부품 | 판매처 | 가격(원) | 수량 | 소계(원) |
|---|---|---|---|---|---|
| 2 | Seeed XIAO ESP32-C3 [113991054] | 디바이스마트 | 9,600 | 1 | 9,600 |
| 3 | MotorBank 코인형 Ø10mm DVM1027, DC3V 100mA | 디바이스마트 | 6,400 | 2 | 12,800 |
| 4 | Voltly DRV8833 모터 드라이버 모듈 [VLT-MD012] | 디바이스마트 | 1,700 | 1 | 1,700 |
| 5 | PeakPower 380mAh 3.7V 1S 리튬폴리머 | 디바이스마트 | 7,000 | 1 | 7,000 |
| 6 | 텔레신 GP-UCS-001 액션캠 체스트 스트랩 (폰을 달려면 폰 거치대 필요 여부 확인 — 미확인) | 다나와 최저가 | 14,500 | 1 | 14,500 |
| 10 | 허리 벨트: 프로스펙스 슬림 러닝 벨트 허리 밴드 (주머니에 마이컴·배터리, 모터는 벨크로로 앞쪽 좌·우) | 다나와 검색 "러닝벨트" (https://search.danawa.com/dsearch.php?query=러닝벨트, 2026-10-29 조회, 배송비 2,500원) | 14,400 | 1 | 14,400 |
| — | 전선(모터 연장선), 작은 스위치, 수축튜브, 벨크로·양면테이프 | — | 추정 | — | 추정 |
| | **합계 (기타·배송비 제외)** | | | | **60,000** |

- 빼는 것(A안 전용): 카메라 B0305, OTG 젠더. 골전도 헤드폰은 이미 가진 것이 있으면 0원(T152 §2-1).
- 주문은 하지 않았다. 배송비 별도.
- 하네스: GP-UCS-001은 액션캠용이라 폰을 바로 물리지 못할 수 있다(추정). 폰 거치 방법은 이 작업에서 조사하지 않았다.

### 4-2. 납땜·배선

| 작업 | 필요 | 비고 |
|---|---|---|
| 배터리 → XIAO 뒷면 BAT+/BAT− 패드 | **예** | 패드라 납땜뿐 |
| XIAO·DRV8833 헤더 핀 | 예 (추정 — 헤더가 붙어서 오는지 판매 페이지 확인 필요) | 브레드보드 시험용 |
| 모터 리드선 → 연장선 | 예 (또는 단자대) | 위치를 옮겨 가며 시험하려면 길게 |
| 배선 표 | `hardware/vib_module/README.md` §부품과 배선 | XIAO D1/D2 → 왼쪽 모터(AIN), D3/D4 → 오른쪽(BIN), BAT+ → VM |

### 4-3. 펌웨어 올리기

1. Arduino IDE 2 설치 → 추가 보드 관리자 URL `https://espressif.github.io/arduino-esp32/package_esp32_index.json` → 보드 관리자에서 "esp32 by Espressif Systems" 3.x 설치.
2. `hardware/vib_module/vib_module.ino` 열기 → 보드 **XIAO_ESP32C3** → 포트 고르기 → 업로드.
3. 안 올라가면 BOOT 버튼을 누른 채 USB를 꽂고 다시(Seeed 안내, 추정).
4. 앱 설정 → 진동 모듈 (개발) → 연결 켬 → "연결됨" → 왼쪽/오른쪽 시험.

## 5. 문제/다음 단계

| # | 내용 |
|---|---|
| 1 | 펌웨어 전체 빌드 미확인. Arduino IDE 설치 뒤 확인(§4-3). `BLE2902`는 보드 패키지 3.x 최신판에서 경고가 날 수 있다(추정) |
| 2 | 실물 확인 없음: 핀 번호 대응, DRV8833 모듈 nSLEEP 핀 유무, 듀티 상한 191(추정), 끊김 500ms 구분, BLE 왕복 지연(`ble.pong` `rtt`로 실측) |
| 3 | BLE 지연 흔들림이 박자(600/350/300ms)를 망치는지 — 실측 뒤 판단(T152 §3-4) |
| 4 | 배터리 사용 시간 미측정, 잔량 못 읽음(분압 저항 없음) |
| 5 | 설정은 세션 한정(다른 개발 설정과 같음) — 앱을 다시 켜면 꺼짐 |
| 6 | 안드로이드 컴파일은 CI에서 처음 확인된다(§2-4). 실패하면 다른 패키지로 바꾸지 않고 멈춰 보고 |
| 7 | 허리 벨트는 검색 결과 상위 상품 하나를 고른 것 — 모터 고정이 쉬운지(벨크로가 붙는 천인지) 미확인 |
