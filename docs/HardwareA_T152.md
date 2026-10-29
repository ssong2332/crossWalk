# T152 — 실제 기기 A안 설계·조사 보고서

작성 2026-10-29. 조사만 했고 앱 코드(`crosswalk_app/`)는 바꾸지 않았다. 가격·재고는 모두 **2026-10-29 조회값**이다. 배송비는 포함하지 않았다. "추정"이라고 쓴 것은 확인하지 않은 값이다.

## 금지 (이 문서를 쓰는 사람용)
- 출처 없는 가격·사양은 쓰지 않는다. 확인하지 못한 것은 "추정" 또는 "미확인"으로 쓴다.
- 이 문서는 부품 주문을 결정하지 않는다. 주문은 사용자가 정한다.
- 카메라가 인식되지 않을 때 다른 경로로 조용히 바꾸지 않는다(`docs/HardwarePlan.md` 금지 2번).

## 결론

| 항목 | 결과 | 이전/기준값 | 근거 |
|---|---|---|---|
| 지금 앱(`camera` 0.11.2+1 → `camera_android_camerax` 0.6.19+1)이 USB 카메라를 여는가 | **못 연다.** 앞·뒤가 아닌 카메라는 목록에서 빠진다 | §9-4 "안 보일 가능성이 높다(추정)" → 소스로 확인 | pub 캐시 `camera_android_camerax-0.6.19+1/lib/src/android_camera_camerax.dart:290-301` ("Skip this CameraInfo as its lens direction is unknown") |
| 새 판 `camera_android_camerax`로 올리면 | 폰이 외부 카메라를 Camera2에 올려 주면 `CameraLensDirection.external`로 보인다. 판을 올리려면 Flutter도 올려야 한다(추정) | 0.6.19+1 (Dart ≥3.7) | GitHub `flutter/packages` main 소스(외부 카메라를 목록에 넣음). pub.dev 판 기록: 0.6.29 "렌즈 방향을 CameraX에서 직접 받음", 0.6.23+2부터 Dart ≥3.9. 지금 Flutter 3.32.2(Dart 3.8 계열, 추정) |
| 갤럭시 S25 울트라가 외부 UVC 카메라를 Camera2(`LENS_FACING_EXTERNAL`)로 올리는가 | **미확인.** 직접 근거를 찾지 못했다 | — | AOSP는 제조사가 외부 카메라 HAL을 넣어야 한다고 쓴다(source.android.com External USB cameras). S25 기종 보고는 찾지 못했다. S21/S23 울트라에서 UVC 앱이 동작했다는 사용자 글만 있다(아래 §1-3) |
| 앱 라이브러리로 USB를 직접 여는 경로(libusb/libuvc) | 쓸 수 있는 후보가 있다: `flutter_ffi_uvc` 1.1.2 (BSD-3, Dart ≥3.8.1 → 지금 Flutter 그대로 됨) | §9-4 표 | pub.dev `flutter_ffi_uvc` |
| 추천 카메라 경로 | **먼저 폰 인식을 확인하고, 결과에 따라 경로 1(표준) 또는 경로 2(라이브러리)** | — | §1-4 판정표 |
| 첫 인식 확인 방법 (사용자에게 USB 웹캠 없음, OV7670은 USB 아님 — 보류) | **(b) 국내 저가 UVC 웹캠(약 26,800원)을 먼저 사서 확인 추천.** B0305는 국내 재고가 없어 도착 시점이 불확실하다 | (a) B0305 바로 구매 약 142,564원(추정) | §5 비교표 |
| 카메라 B0305 국내 판매 | **국내 소매 판매처를 찾지 못했다.** 디바이스마트에는 표준 화각(66°) USB판만 있다 | §9 해외가 £57.60 | 디바이스마트 검색 "IMX708 USB"(3건, B0305 없음), DigiKey KR ₩142,564(검색 결과 스니펫, 재고 0) / 같은 날 DigiKey 페이지는 "더 이상 판매하지 않음" |
| BLE 마이컴 추천 | **Seeed XIAO ESP32-C3** (9,600원, 디바이스마트 재고 있음, 충전 칩 내장) | 계획: ESP32-C3 또는 nRF52 | 디바이스마트, Seeed 위키 |
| 부품 합계 (배송비 별도) | **약 301,000원** (헤드폰 포함). 골전도 헤드폰을 이미 가지고 있으면 약 200,000원 | — | §2 표. 카메라 가격은 추정(₩142,564 기준) |
| BLE 진동 규약 | 초안 작성: 1회 진동 명령(폰이 박자를 잼) + 1초 간격 연결 확인 + 3초 무응답이면 끊김 | — | §3 |
| 진동을 붙일 위치 | `FeedbackService._vibrate()`와 `surfaceAlert()`의 `Vibration.vibrate` 두 곳 | — | `feedback_service.dart:1336-1374`, `:1514-1520` |

---

## 1. USB 카메라 입력 경로

### 1-1. 지금 앱이 카메라를 고르는 방법
- 앱은 `availableCameras()` 목록에서 뒤 카메라를 고르고, 없으면 첫 카메라를 쓴다(`crosswalk_app/lib/screens/camera_screen.dart:376-399`).
- 프레임은 `startImageStream(_onFrame)`으로 받는다. 형식은 YUV420이다(`camera_screen.dart:398`, `:450`). `_onFrame`(`:560`)이 노면(`:981`)·각도(`:1114`)·위치(`:1385`) 판정에 같은 `CameraImage`를 넘긴다.
- 앱 기록 `camera` 줄의 `cams` 항목이 카메라 목록을 남긴다(`camera_screen.dart:461`). 그러나 지금 판(0.6.19+1)은 외부 카메라를 목록에서 **먼저 빼 버린다**. 그래서 USB 카메라를 꽂아도 이 기록에는 나타나지 않는다.

### 1-2. 소스로 확인한 사실

| 판 | 외부 카메라 처리 | 근거 |
|---|---|---|
| `camera_android_camerax` 0.6.19+1 (지금 쓰는 판, `pubspec.lock`) | 뒤 → 앞 순서로 걸러 보고, 둘 다 아니면 `continue`로 **건너뜀** | `android_camera_camerax.dart:290-301` (로컬 pub 캐시) |
| 같은 판, 카메라를 열 때 | `CameraLensDirection.external` → `LensFacing.external`로 바꾸는 코드는 있다. 목록에 안 나오니 쓸 길이 없다 | `android_camera_camerax.dart:1426-1427`, `CameraSelectorProxyApi.java:39-40` |
| main 최신 소스 (0.7.6 계열) | `lensFacing` 값을 직접 읽고, external이면 `CameraLensDirection.external`로 **목록에 넣음**. unknown만 건너뜀 | GitHub `flutter/packages` main `android_camera_camerax.dart` |
| 판 올리기 조건 | 0.6.23+2부터 Dart ≥3.9, 0.7.2+1부터 Dart ≥3.12 | pub.dev 판 목록 |

- 결론: 경로 1을 쓰려면 ⓐ 폰이 Camera2에 외부 카메라를 올려 주고, ⓑ 플러그인을 0.6.29 이후 판으로 올려야 한다. ⓑ에는 Flutter 판 올리기가 따른다(추정 — Dart 3.9가 들어 있는 Flutter 판을 확인해야 한다). 0.6.29가 외부 카메라를 처음 넣은 판인지는 판 기록 문장으로만 추정했다. 판을 올릴 때 그 판의 소스를 확인한다.

### 1-3. 갤럭시 S25 울트라 근거

| 질문 | 결과 | 근거 |
|---|---|---|
| S25 울트라가 Camera2 `EXTERNAL`(외부 카메라 HAL)을 지원하는가 | **미확인** | 기종을 짚은 자료를 찾지 못했다. AOSP 조건: `android.hardware.usb.host` + 커널 UVC + 외부 카메라 provider(source.android.com External USB cameras) |
| 삼성의 "폰을 PC 웹캠으로 쓰기"(USB 웹캠 모드) | 다른 기능이다. 폰이 **카메라 역할**을 하는 것이고, 외부 카메라를 받는 것과 무관하다 | SamMobile(2026-06 갱신): 유선 웹캠 기능은 S26 전용, S25는 One UI 8.5에서도 없음 |
| UVC 앱(libusb로 직접 여는 앱)이 삼성 플래그십에서 되는가 | 다른 기종 사용자 글만 있다. S21 울트라에서 USB 내시경 동작(PB Tech 구매평), S23 울트라에서 UVC 카메라 직결 동작(검색 결과 요약) | 일화. S25 울트라 보고는 없음 |
| 다른 위험 | One UI 업데이트 뒤 UVC 카메라가 안 붙었다는 A13 사용자 글 | Samsung EU 커뮤니티(1건) |

→ **사용자가 직접 확인해야 한다** (§5).

### 1-4. 경로 판정표 (사용자 확인 결과 → 경로)

| 사용자 확인 ⓐ Camera2 Probe 앱에 External 카메라가 보임 | ⓑ UVC 앱(USB Camera 등)에 화면이 나옴 | 경로 | 앱 변경 크기 |
|---|---|---|---|
| 예 | (상관없음) | **경로 1: 표준 `camera` 패키지** — 플러그인·Flutter 판 올리기 + 카메라 고르기를 external 우선으로 | 작음. 프레임이 지금처럼 YUV420 `CameraImage`라 판정 코드는 그대로 |
| 아니오 | 예 | **경로 2: UVC 라이브러리** (`flutter_ffi_uvc` 1순위) | 중간. 프레임 입력부·미리보기 교체 |
| 아니오 | 아니오 | 진행 중단, 원인 보고(OTG 젠더·케이블·폰 USB 호스트 설정 확인 후 재시도). 우회 경로(무선 카메라 B안 등)는 사용자 결정 | — |

### 1-5. 경로 2 후보 (UVC 라이브러리)

| 패키지 | 최신판·시점 | 라이선스 | 유지보수 | 프레임 형식 | 지금 파이프라인과 잇는 방법 |
|---|---|---|---|---|---|
| **`flutter_ffi_uvc`** (1순위) | 1.1.2, 조회일 기준 약 21일 전, 인증 게시자 cornpip.dev | BSD-3 (libuvc·libusb·libjpeg-turbo는 각자 라이선스) | 판이 빨리 나온다(0.6 → 1.1.2). 받은 수 1.51k, 좋아요 5 | 카메라 쪽 MJPEG(자동 선택 1순위)·H.264. 앱에 오는 것은 `copyLatestFrame()` → **RGBA 바이트**. "일부 장치는 스트림은 돌지만 프레임이 없다"고 명시, 멈춤 감시 기능 있음 | 끌어오기 방식이다: 타이머로 `copyLatestFrame()`을 불러 RGBA를 받는다. 판정 3곳(`:981`, `:1114`, `:1385`)이 `CameraImage`(YUV) 대신 RGBA를 받도록 입력 변환부를 하나 두어야 한다. 미리보기는 Texture 위젯. Dart ≥3.8.1이라 지금 Flutter 3.32.2에서 된다(추정 — Flutter 3.32.2의 Dart가 3.8.1인지 `flutter --version`으로 확인) |
| `uvccamera` | 0.0.13, 약 19개월 전, 인증 게시자 uvccamera.org | Apache-2.0 | 멈춘 것으로 보임(추정) | 페이지에 프레임 형식 없음 | API가 `camera` 패키지와 비슷하다고 적혀 있다. 이미지 스트림 여부 미확인 |
| `flutter_uvc_camera` | 1.0.0, 약 17개월 전, 미인증 | MIT | 멈춘 것으로 보임(추정) | 프레임 콜백이 **H.264 인코딩 프레임** | 판정에 쓰려면 H.264를 다시 풀어야 한다. "Android 10 이상은 targetSdk를 27로 낮춰야 할 수 있다" → 지금 앱 설정과 맞지 않아 제외 권장 |
| 직접 구현 (AndroidUSBCamera 등 네이티브 + 플랫폼 채널) | — | 라이브러리마다 다름 | 우리가 유지 | YUV/NV21 콜백을 받을 수 있음(추정) | 가장 손이 많이 간다. 위 후보가 모두 실패할 때만 |

- `flutter_ffi_uvc`는 저장소 규칙대로 **2주 이상 된 판으로 고정**한다(1.1.2는 조건 충족).
- 카메라 B0305 출력: MJPG/YUV, 1080p·720p 30fps, 최대 300mA, 5V(Pi Hut 사양표). 앱이 쓰는 해상도는 `ResolutionPreset.medium`(`camera_screen.dart:396`)이라 720p MJPG면 충분하다(추정).

### 1-6. 경로 공통 위험

| 위험 | 내용 | 대응 |
|---|---|---|
| 폰 배터리 | 카메라 전원(최대 300mA)을 폰이 준다. 사용 중 충전 불가 | §6 배터리 기준 실측. PD 충전 통과 USB-C 허브로 충전+카메라 동시 사용은 가능할 수 있음(추정, 미조사) |
| 카메라 내장 마이크 | B0305에는 마이크가 있다(Pi Hut 상품명 "with Microphone"). 폰이 USB 오디오 장치로 잡을 수 있다 | 골전도 헤드폰 출력이 바뀌지 않는지 첫 연결 때 확인(추정 위험) |
| 화각·센서 변화 | 모델 4개는 폰 세로 사진으로 학습 → 새 카메라에서 정확도가 떨어질 수 있다(`HardwarePlan.md` §4 제약) | 개발자 현장 시험 전에 새 카메라 영상으로 정확도부터 잰다 |
| 케이블 빠짐 | 가슴 → 주머니 케이블이 걸려 빠질 수 있다 | `HardwarePlan.md` §4 "USB 카메라 빠짐 → 안내 중단 + P0 알림" 그대로 |

---

## 2. 부품 목록과 국내 가격 (조회 2026-10-29, 배송비 별도)

| # | 부품 | 고른 상품 | 판매처 | 가격(원) | 수량 | 소계(원) | 재고 | 출처 |
|---|---|---|---|---|---|---|---|---|
| 1 | 광각 USB 카메라 | Arducam B0305 IMX708 Wide USB-C (가로 102°) | **국내 소매 없음.** DigiKey KR (해외 배송) | 142,564 (**추정** — 검색 결과 스니펫 값. 같은 날 DigiKey KR 상품 페이지는 "더 이상 판매하지 않음") | 1 | 142,564 | 재고 0 (DigiKey). Pi Hut £57.60 품절 | https://www.digikey.kr/en/products/detail/arducam/B0305/19116505 , https://thepihut.com/products/arducam-wide-angle-12mp-imx708-usb-c-uvc-fixed-focus-camera-module |
| 2 | BLE 마이컴 | Seeed XIAO ESP32-C3 [113991054] | 디바이스마트 | 9,600 | 1 | 9,600 | 있음 (약 1일) | https://www.devicemart.co.kr (검색 "XIAO ESP32C3") |
| 3 | 진동 모터 | MotorBank 코인형 Ø10mm DVM1027, DC3V 100mA | 디바이스마트 | 6,400 | 2 | 12,800 | 있음 (약 3일) | 디바이스마트 (검색 "코인 진동모터") |
| 4 | 모터 드라이버 | Voltly DRV8833 모터 드라이버 모듈 [VLT-MD012] (2채널 → 모터 2개를 한 장으로) | 디바이스마트 | 1,700 | 1 | 1,700 | 있음 (약 3일) | 디바이스마트 (검색 "DRV8833") |
| 5 | 배터리 | PeakPower 380mAh 3.7V 1S 리튬폴리머 | 디바이스마트 | 7,000 | 1 | 7,000 | 있음 (약 2일) | 디바이스마트 (검색 "리포 배터리 3.7V") |
| 5b | 충전 모듈 | **따로 사지 않음** — XIAO ESP32-C3에 리튬 충전 칩 내장(빠른 충전 380mA) | — | 0 | — | 0 | — | https://wiki.seeedstudio.com/XIAO_ESP32C3_Getting_Started/ |
| 6 | 가슴 하네스 | 텔레신 GP-UCS-001 액션캠 체스트 스트랩 (어깨끈 분리형, 하중 0.3kg) | 다나와 최저가 | 14,500 | 1 | 14,500 | 2몰 | https://search.danawa.com (검색 "액션캠 체스트 마운트") |
| 7 | 골전도 헤드폰 | 샥즈 오픈무브 S661 (정품) | 다나와 최저가 | 101,150 | 1 | 101,150 | 27몰 | https://search.danawa.com (검색 "샥스 오픈무브") |
| 8 | OTG 젠더 | 대원TMT Type-C(수) → USB-A(암) 2.0 OTG, 0.1m [DW-OTG31N-01M] | 디바이스마트 | 1,700 | 1 | 1,700 | 있음 (약 3일) | 디바이스마트 (검색 "USB C to C 케이블 OTG") |
| 9 | 기타 | 전선·스위치·수축튜브·카메라 고정판(1/4인치 나사 또는 3D 프린트) | — | **추정** 10,000 | — | 10,000 | — | 추정 |
| | **합계** | | | | | **301,014** | | |
| | 헤드폰 제외 합계 | | | | | **199,864** | | |

### 2-1. 고른 이유와 대안

| 항목 | 고른 것 | 대안 | 이유 |
|---|---|---|---|
| 카메라 | B0305 | ① 디바이스마트 B030401 (IMX708 USB **표준 화각 66°**, 자동초점) 80,000원 재고 있음 — 화각이 H0 결정(약 100~108°, `HardwarePlan.md` §5 H0 결과)에 못 미쳐 **제외** ② Arducam 공식몰·해외 판매처 직구 — 공식몰은 접속 확인 페이지(Cloudflare)라 가격 미조회 | §9-1 1순위. 국내에서 못 구하면 해외 직구 기간(약 1~2주, 추정)이 일정 위험 |
| 카메라 케이블 | 동봉 케이블(USB-C → USB-A, 1m) + OTG 젠더 | USB-C ↔ USB-C 데이터 케이블 하나로 대체 가능(추정 — 카메라 어댑터 보드 C 단자가 C-C로 붙는지 미확인) | Pi Hut 구성품 "1x USB2.0 Cable (1m)", 설명 "USB-C to USB-A cable" |
| 마이컴 | XIAO ESP32-C3 | XIAO nRF52840 15,900원(디바이스마트, 해외 재고 약 1일) | ESP32-C3: 더 싸고 국내 재고, 충전 칩 내장, BLE 5.0, 21×17.8mm, 깊은 잠 44µA(Seeed 위키). 약점: 배터리 전압을 소프트웨어로 못 읽는다(분압 저항을 따로 달아야 함, 위키), 동작 전류는 nRF52보다 클 것(추정). 체험 1회 30분 기준으로는 결정적 차이가 아니라고 봄(추정) |
| 모터 | DVM1027 (사양 표기 있음) | Voltly 1027 900원(사양 표기 적음) | 같은 크기 대체 가능. 옷 위에서 느껴지는 세기는 실측 항목 |
| 드라이버 | DRV8833 | 트랜지스터+다이오드 직접 구성 | 한 장으로 좌우 2채널, 2.7V부터 동작(Pololu·Adafruit 표기)이라 1셀 리튬 직결 가능 |
| 배터리 | 380mAh | 500mAh 이상 | 디바이스마트 검색에서 1셀 500mAh급 일반 배터리를 찾지 못했다. 충전 전류 380mA = 1C라 380mAh 이상을 권장(추정). 사용 시간 = 마이컴 + 모터 100mA × 작동 비율 → 약 2~3시간(추정, 미측정) |
| 헤드폰 | 샥즈 오픈무브 | 아이리버 IB-GX1 49,900원(다나와 광고 표시가, 추정) | 사용자가 이미 가진 헤드폰이 있으면 0원 |

- 쿠팡·엘레파츠: 엘레파츠는 검색 결과가 스크립트로 그려져 이번 조회에서 읽지 못했다. 쿠팡은 조회하지 않았다. 가격 비교가 더 필요하면 사람이 직접 확인한다.

---

## 3. BLE 진동 신호 규약 초안

### 3-1. 앱의 진동 출력 지점 (코드 읽기 결과, 변경 없음)

| 지점 | 무엇을 내나 | 근거 |
|---|---|---|
| `FeedbackService._vibrate(kind, pattern)` | 이탈(left/right)·복귀(recover) 진동을 **실제로 내는 유일한 곳**. `kind`가 방향을 들고 온다 | `feedback_service.dart:1336-1374` (`Vibration.vibrate` `:1350`, `:1352`) |
| `FeedbackService.surfaceAlert()` | 노면: 차도(짧게 3번)·선형 블록 위(짧게 1번) | `feedback_service.dart:1476-1540` (`Vibration.vibrate` `:1517`, `:1519`) |
| `alert()`의 진동 결정 | `vibClass`(= 감지 클래스, 또는 T143 "이미 틀었음"의 중앙 쪽 클래스)로 `decidePattern` | `feedback_service.dart:1261-1303` |
| `_onDirectionDue()` (T142 반복 타이머) | 같은 방향 반복 진동을 폰 타이머가 울림 | `feedback_service.dart:1308-1324` |
| `stopDirectionVibration(why)` | 상태 바뀜·hold·일시정지·종료 때 반복 중단 | `feedback_service.dart:1329-1333` |
| 반복 간격 (T146) | 단계 0 = 600ms, 단계 1 = 350ms, 단계 2 = 300ms | `audio_policy.dart:384`, `:398-402` |
| 진동 1번 길이 | 150ms, 좌우 같은 모양 | `audio_policy.dart:407`, `:469` |
| 복귀 확인 | 60ms 1번 | `audio_policy.dart:459` |
| 판정 멈춤 감지 | 경고 호출이 1초 넘게 없으면 반복 중단 | `direction_repeat_timer.dart:31` |

### 3-2. 방향 → 모터 (진동 뜻 = 가야 할 쪽이 울림, `HardwarePlan.md` §1)

| `kind` / 클래스 | 앱 음성·화살표 | 울릴 모터 | 근거 |
|---|---|---|---|
| `left` (왼쪽으로 벗어남) | "오른쪽으로" | **오른쪽** | `app_strings.dart:571` (`'left': '오른쪽으로'`), 화살표 = 가야 할 방향 주석 `:568-569` |
| `right` | "왼쪽으로" | **왼쪽** | `app_strings.dart:572` |
| T143 "이미 틀었음" (`vibAs`) | 중앙 쪽 클래스 | 위와 같은 규칙 (클래스가 같은 뜻이라서) | `feedback_service.dart:684-694` 주석 "좌우 모터 2개 기기에서 뜻이 생긴다" |
| `recover` | 딩 + 짧은 진동 | **양쪽** 60ms | `audio_policy.dart:459` |
| `road` (차도) | P0 음성 | **양쪽** 짧게 3번 | `feedback_service.dart:1563` |
| `line_on` (선형 블록 위) | 진동만 | **양쪽** 짧게 1번 | `feedback_service.dart:1509` |

### 3-3. GATT 구성 (초안)

| 항목 | 값 |
|---|---|
| 서비스 | 자체 128비트 UUID 1개 (펌웨어 작성 때 생성) |
| CMD 특성 | Write Without Response. 폰 → 기기 |
| STATUS 특성 | Notify. 기기 → 폰 |
| 연결 간격 | 15~30ms 요청(추정 — 안드로이드는 앱이 정확한 값을 못 정하고 우선순위만 요청 가능). 실측 지연은 기록으로 잰다 |

### 3-4. CMD 형식 (바이트 순서, 시간 단위 10ms)

| op | 이름 | 바이트 | 뜻 |
|---|---|---|---|
| 0x01 | PULSE | `01 side dur seq` | 모터 `side`(1=왼, 2=오, 3=양쪽)를 `dur`×10ms 켠다. 기기는 `dur`가 지나면 **스스로 끈다**. 앱의 방향 진동 1번 = `dur`=15 |
| 0x02 | PATTERN | `02 side n on1 off1 … seq` | 짧게 3번(차도) 같은 묶음. `n` ≤ 4쌍 |
| 0x03 | STOP | `03 seq` | 즉시 끔 |
| 0x10 | PING | `10 seq` | 연결 확인. 기기는 STATUS로 같은 `seq`를 돌려준다 |
| 0x11 | TEST | `11 side seq` | 착용 확인용(설정 화면 "왼쪽 시험"·"오른쪽 시험") |

STATUS: `type seq batt flags` — `type` 1=PONG, 2=오류. `batt`는 분압 저항을 달면 %, 없으면 0xFF.

**박자는 폰이 잰다.** 지금 앱은 T142 타이머로 600/350/300ms마다 `_vibrate`를 부른다. 그 부름마다 PULSE 하나를 보내면 앱 박자 로직을 그대로 쓴다. 기기가 스스로 반복하는 방식(간격을 기기에 넘김)은 BLE 끊김 때 진동이 계속될 위험이 있어 **이번 초안에서는 쓰지 않는다.** BLE 지연 흔들림이 박자를 망치는지는 실측 뒤 다시 정한다.

### 3-5. 연결 확인과 끊김 감지

| 상황 | 폰 | 기기 |
|---|---|---|
| 평상시 | 1초마다 PING. PONG 왕복 시간을 기록 | PING·CMD를 받으면 마지막 수신 시각 갱신 |
| 3초 동안 PONG 없음, 또는 BLE 연결 끊김 이벤트 | **폰 진동으로 자동 대체 + 음성 1회 알림** (`HardwarePlan.md` §4 고장 시 동작) | — |
| 기기가 3초 동안 아무것도 못 받음 | — | 켜져 있던 모터 끔. 양쪽 **길게 1번(500ms, 추정 값)** 으로 "연결 끊김"을 몸에 알림. 그 뒤 광고(advertising) 재시작 |
| 재연결 | 기기 진동으로 되돌림 + 음성 1회 | 정상 |
| 앱 종료·화면 꺼짐 | STOP 보낸 뒤 연결 해제 | — |

- 3초·500ms는 초안 값이다(추정). 개발자 현장 시험에서 조정한다.
- 기기의 "끊김 길게 1번"은 방향 진동(150ms)·복귀(60ms)와 길이로 구분된다(추정 — 옷 위에서 구분되는지는 실측).

### 3-6. 앱에 붙일 위치 (설계만, 코드 변경 없음)

| 할 일 | 위치 | 비고 |
|---|---|---|
| 진동 출력을 바꿔 끼울 수 있게 만들기 (`HapticOut`: 폰 / BLE) | `_vibrate()`의 `Vibration.vibrate` 두 줄(`:1350`, `:1352`)과 `surfaceAlert()`의 두 줄(`:1517`, `:1519`) | `kind`로 모터를 고른다(§3-2). 판정·박자 코드(`decidePattern`, `DirectionRepeatTimer`)는 그대로 |
| BLE 끊김 → 폰 진동 대체 | `HapticOut` 안 | 대체될 때 `vib` 기록에 `out: phone/ble` |
| STOP | `stopDirectionVibration()`(`:1329`), `dispose()`(`:1580`) | PULSE가 스스로 꺼지므로 필수는 아니지만 진동 중 멈춤을 위해 보냄 |
| 기록 (T106) | `vibrationLogData()`(`:1099`)에 `out`, `seq` 추가, 새 줄 `ble`(연결·끊김·PONG 왕복 ms) | §4 "BLE 진동 명령·연결 상태 항목 추가 → 지연 실측" |
| BLE 패키지 | `universal_ble` (BSD-3, 인증 게시자 navideck.com, write without response·연결 상태 스트림 지원) | `flutter_blue_plus` 2.x는 영리 목적 사용에 유료 라이선스가 필요하다고 README에 적혀 있어 2순위. `universal_ble` 최신판(3.1.2)은 조회일 기준 8일 전이라 2주 이상 된 판으로 고정 |
| 권한 | Android 12 이상 `BLUETOOTH_SCAN`·`BLUETOOTH_CONNECT` | `permission_handler`가 이미 있음(`pubspec.yaml`) |

- 폰 진동은 지금 좌우 같은 모양이다(T136). 기기에서 좌우 모터로 나누면 T116(폰 진동 뜻 맞추기, `docs/Tasks.md:131`)의 "벗어난 쪽 vs 가야 할 쪽" 문제는 기기 쪽에서는 생기지 않는다.

---

## 4. `docs/HardwarePlan.md` 수정 내용
- 맨 위 결정 표에 **A안 결정(2026-10-29)** 을 넣었다.
- §5 진행 순서 표를 A안 순서(A0~A5)로 다시 썼다. 이전 H1~H6 표는 지우지 않고 "이전 계획"으로 남겼다.
- §7 안전 수칙과 "실사용자 체험(H6) 전 조건"(금지 3번)은 그대로 두었다.

## 5. 사용자가 직접 확인할 것

**조건 (오케스트레이터 2026-10-29):** 사용자에게 USB 웹캠이 없다. 가진 카메라는 OV7670뿐인데 DVP 병렬 방식이라 USB가 아니다(마이컴을 거쳐야 함). 그래서 OV7670은 계획대로 보류하고 A안에 쓰지 않는다(`HardwarePlan.md` §1). 인식 확인용 카메라를 하나 사야 한다.

### 5-1. 두 가지 인식 경로 (따로 확인해야 한다)

| 경로 | 무엇이 카메라를 여나 | 갤럭시가 해 줘야 하는 것 | 확인 앱 | 앱 경로 |
|---|---|---|---|---|
| **안드로이드 카메라 HAL 경로** (시스템 카메라) | 안드로이드 카메라 서비스(Camera2/CameraX)가 외부 카메라를 카메라 목록에 올림 | 제조사가 외부 카메라 HAL(provider)을 넣어야 함. 넣었는지는 기종마다 다름(source.android.com External USB cameras) | 카메라 정보 앱(Camera2 API Probe류)에서 External 카메라가 생기는가 | 경로 1 |
| **사용자 공간 UVC 경로** (앱이 USB를 직접 엶) | 앱 안의 libusb/libuvc(예: saki4510t UVCCamera 계열, `flutter_ffi_uvc`)가 USB 장치를 직접 엶 | USB 호스트(OTG)만 되면 됨. Android 11 이상에서는 앱이 카메라 권한을 받아야 UVC 장치에 접근 가능(AOSP 문서) | UVC 뷰어 앱(USB Camera·CameraFi류)에 화면이 나오는가 | 경로 2 |

### 5-2. 갤럭시에서 UVC를 쓴 사례 (조회 2026-10-29)

| 기기 | 경로 | 결과 | 출처 |
|---|---|---|---|
| Galaxy Tab S6 Lite (Android 10 출고) | 사용자 공간(앱 + HDMI 캡처 장치, UVC) | **동작** ("처음부터 바로 됨") | Samsung EU 커뮤니티 Note 9 글 2021-02-27 https://eu.community.samsung.com/t5/galaxy-note-series/uvc-na-note-9-uvc-in-note-9/td-p/2951913 |
| Galaxy Note 9 (Android 10으로 업데이트) | 사용자 공간 | **실패.** 글쓴이는 2020-03 Google이 UVC를 막았고 고친 판은 Android 11이 필요하다고 씀(본인 주장, 미검증) | 같은 글 |
| Galaxy S21 Ultra | 미상(앱 이름 없음) | USB 내시경 **동작** (구매평) | https://www.pbtech.co.nz/product/SEVOEM9440/USB-3-IN-1-Inspection-Camera-EndoScope-2MP-Lens-Di |
| Galaxy S23 Ultra | 사용자 공간(추정) | 소형 UVC 카메라 직결 **동작** (판매 사이트 글, 신뢰도 낮음) | AliExpress Wiki "android uvc camera github" |
| Galaxy S24 Ultra | 사용자 공간 | 싸구려 내시경 + 앱 6개 **모두 실패.** 카메라 불량 가능성이 거론됐고 환불받음. 원인 불명 | https://eu.community.samsung.com/t5/galaxy-s24-series/endoscopy-cam/td-p/11018176 (2024-11-06) |
| Galaxy A13 (One UI 5 → 6) | 사용자 공간 | 업데이트 뒤 UVC 카메라 **안 붙음** | Samsung EU 커뮤니티 (§1-3) |
| Galaxy S25 울트라 | 둘 다 | **사례 없음 → 미확인** | — |

- 해석(추정): 사용자 공간 경로는 여러 갤럭시에서 된 사례가 있다. 실패 사례는 카메라 불량이나 OS 판 문제로 설명될 수 있다. 카메라 HAL 경로(External 카메라)는 갤럭시에서 된 사례를 하나도 찾지 못했다. 그래서 **경로 2 가능성이 경로 1보다 높다고 본다(추정).**

### 5-3. 인식 확인용 카메라 비교

| 항목 | (a) B0305를 바로 사서 첫 시험 | (b) 국내 저가 UVC 웹캠을 먼저 사서 확인 |
|---|---|---|
| 고른 상품 | Arducam B0305 | 앱코 APC850 FHD 웹캠 (USB, 1080p 30fps, 시야각 110°, 마이크) |
| 가격 | 약 142,564원 (**추정**, DigiKey KR 검색 스니펫) — 어차피 살 물건이라 추가 비용 0 | **26,800원** (다나와 가격비교 최저, 77몰, 2026-10-29) — 추가 비용 |
| 도착 | **불확실.** 국내 재고 없음, Pi Hut 품절, DigiKey 재고 0·"판매 종료" 표시. 해외 직구 기간 미확인 | 국내 쇼핑몰 1~3일(추정) |
| 확인되는 것 | 폰 쪽(HAL·사용자 공간) + **이 카메라 자체**(MJPG 모드, 마이크가 소리 경로에 주는 영향)를 한 번에 | **폰 쪽**(HAL·사용자 공간)만. 웹캠이 되어도 B0305가 꼭 된다는 보장은 없다(UVC 칩·지원 형식이 다름, 추정) |
| 실패했을 때 | 폰 문제인지 카메라 문제인지 가르기 어렵다. 14만 원짜리 부품이 남음(PC·라즈베리파이에서는 쓸 수 있음) | 2.7만 원 손실. 웹캠 불량 가능성을 빼려면 PC에서 먼저 동작 확인 가능 |
| 덤 | — | 110° 광각이라 B0305 도착 전 앱 변경(A2)·초기 화면 확인에 임시 카메라로 쓸 수 있다(추정 — 센서·왜곡이 달라 학습 데이터용은 아님) |
| UVC 표기 | 상품 페이지에 UVC 명시 | 상품 정보에 "UVC" 문구 없음. 일반 PC 웹캠은 대부분 UVC라 드라이버 없이 붙는다(추정). 확실히 하려면 대안: Arducam B0196 (IMX219 8MP, **UVC 명시**) 40,000원, 디바이스마트 약 2일 |

**추천: (b).** 이유: ① B0305는 도착 시점이 불확실해서, 기다리면 앱 경로 결정(A0)과 앱 변경(A2)이 함께 밀린다. ② 확인하려는 위험 두 가지(폰 HAL 지원, 사용자 공간 동작)는 모두 **폰 쪽** 문제라서 아무 UVC 카메라로도 가를 수 있다. ③ 추가 비용이 26,800원으로 작고, 임시 카메라로도 쓸 수 있다. B0305 주문을 웹캠 확인과 동시에 할지, 확인 뒤에 할지는 사용자가 정한다. 동시에 주문하면 일정은 빨라지지만 폰이 둘 다 실패할 때 14만 원 위험이 생긴다.

OTG 젠더(Type-C 수 → USB-A 암, 1,700원, §2 #8)는 웹캠과 B0305가 같이 쓴다.

### 5-4. 확인 순서 (웹캠 도착 뒤)

| # | 할 일 | 보는 것 | 결과 쓰는 곳 |
|---|---|---|---|
| U0 | (선택) 웹캠을 PC에 먼저 꽂아 본다 | 화면이 나오는가 — 웹캠 불량 제외 | 오케스트레이터에게 |
| U1 | 웹캠을 S25 울트라에 OTG 젠더로 꽂는다 | 연결 알림 또는 앱 선택 창이 뜨는가 | 오케스트레이터에게 |
| U2 | 플레이스토어 "Camera2 API Probe" 같은 카메라 정보 앱을 연다 | 카메라 목록에 **External**(외부) 카메라가 새로 생기는가 → §1-4 ⓐ | 같은 곳 |
| U3 | 플레이스토어 "USB Camera" 같은 UVC 앱을 연다 | 웹캠 화면이 나오는가, 해상도는 얼마인가 → §1-4 ⓑ | 같은 곳 |
| U4 | U1~U3 동안 골전도(또는 블루투스) 헤드폰으로 음악을 튼다 | 소리가 헤드폰에 그대로 나오는가(웹캠 마이크 때문에 바뀌지 않는가) | 같은 곳 |
| U5 | (선택) 개발자 옵션의 USB 설정 | 웹캠을 꽂았을 때 폰이 "충전만"이 아니라 호스트로 동작하는가 | 같은 곳 |

- 앱 이름은 예시다. 이번 조사에서 특정 앱을 검증하지 않았다. 설치는 사용자가 정한다.
- B0305가 도착하면 U1~U4를 한 번 더 한다(카메라 자체 확인).

## 6. 출처 (조회 2026-10-29)
- 로컬 소스: `%LOCALAPPDATA%/Pub/Cache/hosted/pub.dev/camera_android_camerax-0.6.19+1/` (`lib/src/android_camera_camerax.dart:274-321`, `:1420-1428`; `android/build.gradle` CameraX 1.5.0-beta01)
- https://raw.githubusercontent.com/flutter/packages/main/packages/camera/camera_android_camerax/lib/src/android_camera_camerax.dart
- https://pub.dev/packages/camera_android_camerax/changelog , https://pub.dev/packages/camera_android_camerax/versions
- https://source.android.com/docs/core/camera/external-usb-cameras
- https://www.sammobile.com/?p=16662419 (SamMobile, 2026-06-26 갱신: 유선 웹캠 기능 S26 전용)
- https://www.pbtech.co.nz/product/SEVOEM9440/USB-3-IN-1-Inspection-Camera-EndoScope-2MP-Lens-Di (S21 울트라 구매평)
- https://eu.community.samsung.com/t5/mobile-apps-services/uvc-camera-cannot-connect-to-samsung-a13-one-ui-6-0/m-p/9333557/highlight/true
- https://eu.community.samsung.com/t5/galaxy-note-series/uvc-na-note-9-uvc-in-note-9/td-p/2951913 (Note 9 실패, Tab S6 Lite 동작)
- https://eu.community.samsung.com/t5/galaxy-s24-series/endoscopy-cam/td-p/11018176 (S24 Ultra 내시경 실패)
- https://github.com/saki4510t/UVCCamera (사용자 공간 UVC 라이브러리)
- https://search.danawa.com (검색: 웹캠 — 앱코 APC850 26,800원), 디바이스마트 (검색: USB 웹캠 — Arducam B0196 40,000원)
- https://pub.dev/packages/flutter_ffi_uvc , https://pub.dev/packages/uvccamera , https://pub.dev/packages/flutter_uvc_camera
- https://pub.dev/packages/universal_ble , https://pub.dev/packages/flutter_blue_plus
- https://thepihut.com/products/arducam-wide-angle-12mp-imx708-usb-c-uvc-fixed-focus-camera-module (B0305 사양·구성품·£57.60 품절)
- https://www.digikey.kr/en/products/detail/arducam/B0305/19116505
- https://www.devicemart.co.kr (검색: IMX708, IMX708 USB, XIAO ESP32C3, XIAO nRF52840, 코인 진동모터, DRV8833, 리포 배터리 3.7V, USB C to C 케이블 OTG)
- https://search.danawa.com (검색: 샥스 오픈무브, 액션캠 체스트 마운트)
- https://wiki.seeedstudio.com/XIAO_ESP32C3_Getting_Started/
