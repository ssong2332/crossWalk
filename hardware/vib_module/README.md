# BLE 좌우 진동 모듈 펌웨어 (T153)

작성 2026-10-29. 보드: Seeed XIAO ESP32-C3. 앱 쪽 코드: `crosswalk_app/lib/services/vib_module.dart`. 설계 초안: `docs/HardwareA_T152.md` §3. 보고서: `docs/T153_ble_vib.md`.

## 금지
- 규약 값(UUID, op, 단위)을 한쪽만 바꾸지 않는다. `vib_protocol.h`와 `vib_module.dart`를 함께 바꾸고 양쪽 시험을 돌린다.
- 기기가 스스로 진동을 반복하게 만들지 않는다. 끊겼을 때 진동이 계속될 위험이 있다(T152 §3-4).
- 추정 값(아래 "추정" 표시)을 확인 없이 사실로 옮겨 적지 않는다.

## 상태

| 항목 | 상태 | 근거 |
|---|---|---|
| 규약 해석·재생·무응답 감시 (`vib_protocol.h`) | 이 PC에서 호스트 시험 통과 (검사 39개, 실패 0) | 아래 §시험 |
| 펌웨어 전체 (`vib_module.ino`) | **빌드하지 못함** — 이 PC에 Arduino IDE·arduino-cli·PlatformIO·ESP-IDF가 없다 | `which arduino-cli pio platformio idf.py` → 모두 없음, `%LOCALAPPDATA%\Arduino15` 없음 (2026-10-29) |
| 실물 동작 | 미확인 (부품 없음) | — |

도구를 설치하지 않은 이유: 보드 패키지(컴파일러 포함)를 새로 내려받아야 하는데, 이번 작업 범위에서 승인받지 않았다. 사용자가 Arduino IDE를 설치하면 아래 §빌드 순서로 바로 빌드된다(추정 — 실제 빌드는 미확인).

## 왜 Arduino인가 (ESP-IDF가 아니라)

| 기준 | Arduino (esp32 보드 패키지 3.x) | ESP-IDF |
|---|---|---|
| 사용자가 올리기 | Arduino IDE에서 열고 "업로드" 1번 | 명령줄 도구·환경 설정 필요 |
| Seeed 공식 안내 | XIAO ESP32-C3 시작하기가 Arduino 기준 | 있음 |
| BLE | 보드 패키지에 BLE 라이브러리 들어 있음, 추가 설치 없음 | 직접 구성 |
| 파일 수 | `.ino` 1개 + 헤더 1개 | 프로젝트 구조 필요 |
| 약점 | 세밀한 전력 관리가 어렵다 | — |

체험 1회 30분이 목표(`docs/HardwarePlan.md` §6)라 전력 최적화보다 올리기 쉬움을 골랐다.

## 규약 v1 (확정본 — 앱과 같음)

| 항목 | 값 |
|---|---|
| 광고 이름 | `CW-VIB` |
| 서비스 UUID | `aef7a022-c301-40c9-8c59-0126d6388255` |
| CMD 특성 (폰 → 기기, Write / Write Without Response) | `aef7a023-c301-40c9-8c59-0126d6388255` |
| STATUS 특성 (기기 → 폰, Notify) | `aef7a024-c301-40c9-8c59-0126d6388255` |
| 시간 단위 | 10ms (1바이트 → 최대 2550ms) |
| side | 1 = 왼쪽, 2 = 오른쪽, 3 = 양쪽 |
| 세기 str | 0~255 → PWM 듀티 0~191 (상한 191은 추정, 아래 §배선) |

| op | 이름 | 바이트 | 기기 동작 |
|---|---|---|---|
| 0x01 | PULSE | `01 side dur str seq` | side 모터를 dur×10ms 켜고 스스로 끈다 |
| 0x02 | PATTERN | `02 side str n on1 off1 … onN offN seq` (n 1~4) | 켬·끔을 차례로. 끝나면 끈다 |
| 0x03 | STOP | `03 seq` | 바로 끈다 |
| 0x10 | PING | `10 seq` | STATUS PONG `01 seq FF 00` |
| (오류) | — | — | STATUS ERROR `02 seq FF code` (code 1 길이, 2 op, 3 side, 4 n) |

T152 초안과 다른 점:

| 항목 | T152 §3-4 초안 | v1 | 이유 |
|---|---|---|---|
| 세기 | 없음 | PULSE·PATTERN에 `str` 1바이트 | 작업 지시(왼쪽/오른쪽/양쪽, 지속 ms, 세기). 착용 위치 시험에서 세기 체감을 비교 |
| TEST (0x11) | 있음 | 없음 | 앱 "왼쪽/오른쪽/양쪽 시험" 버튼이 PULSE 150ms를 보낸다 — 실제 방향 진동과 같은 모양 |

### 진동 뜻 (앱이 고름 — 기기는 side만 본다)

| 앱 kind | side | 근거 |
|---|---|---|
| left (왼쪽으로 벗어남, 음성 "오른쪽으로") | 2 오른쪽 | 가야 할 쪽이 울림 (`docs/HardwarePlan.md` §1) |
| right | 1 왼쪽 | 같음 |
| recover · road · line_on | 3 양쪽 | T152 §3-2 |

### 끊김

| 상황 | 폰 (앱) | 기기 |
|---|---|---|
| 평상시 | 1초마다 PING, PONG 왕복 ms 기록 | 받을 때마다 감시 시각 갱신 |
| PONG 3초 없음 / BLE 끊김 / 쓰기 실패 | 폰 진동으로 대체 + 음성 1번 "진동 모듈 연결이 끊겼습니다", 3초마다 다시 찾기 | — |
| 3초 동안 아무것도 못 받음 | — | 모터 끔 + 양쪽 길게 1번(500ms, 추정 값) |
| BLE 끊김 | — | 모터 끔 + (아직 안 알렸으면) 길게 1번 + 광고 다시 시작 |
| 다시 연결 | 모듈로 되돌림 + 음성 1번 "진동 모듈이 연결되었습니다" | — |
| 사용자가 설정을 끔 | STOP 보낸 뒤 연결 해제, 음성 없음 | 끊김 → 길게 1번 (설정을 끈 것이라도 기기는 구분 못 함) |

## 부품과 배선

부품은 `docs/HardwareA_T152.md` §2의 진동 모듈 부분이다(가격은 그 문서, 2026-10-29 조회).

| # | 부품 | 수량 |
|---|---|---|
| 2 | Seeed XIAO ESP32-C3 | 1 |
| 3 | 코인 진동 모터 DVM1027 (Ø10mm, DC3V 100mA) | 2 |
| 4 | DRV8833 모터 드라이버 모듈 (2채널) | 1 |
| 5 | 리튬폴리머 3.7V 380mAh 1셀 | 1 |
| — | 전선(모터 연장선, 하네스 앞까지 닿는 길이), 작은 스위치, 수축튜브, 벨크로·테이프 | 추정 |

| XIAO ESP32-C3 | DRV8833 | 메모 |
|---|---|---|
| D1 | AIN1 | 왼쪽 모터 PWM |
| D2 | AIN2 | LOW 고정 |
| D3 | BIN1 | 오른쪽 모터 PWM |
| D4 | BIN2 | LOW 고정 |
| D5 | nSLEEP (모듈에 핀이 있으면) | HIGH. 모듈이 이미 끌어올려 두었으면 연결 안 해도 됨(추정 — 모듈 판매 페이지 회로 확인 필요) |
| GND | GND | 공통 접지 |
| 뒷면 BAT+ (스위치 거쳐) | VM | DRV8833은 2.7V부터 동작(T152 §2-1) |
| 뒷면 BAT− | GND | |

| DRV8833 출력 | 모터 |
|---|---|
| AOUT1 / AOUT2 | 왼쪽 모터 (극성 무관 — 코인 모터는 방향이 바뀌어도 떨린다, 추정) |
| BOUT1 / BOUT2 | 오른쪽 모터 |

- D0(GPIO2)·D8(GPIO8)·D9(GPIO9)는 ESP32-C3 부팅 설정 핀이라 쓰지 않았다(핀 번호 대응은 Seeed 위키 핀 표 기준, 실물 확인 필요).
- 듀티 상한 191/255 ≈ 75%: 모터 정격 3V ÷ 리튬 만충 약 4.2V ≈ 0.71에 여유를 둔 값(추정). 전압 보정은 없어서 배터리가 내려가면 세기도 약해진다.
- 배터리 잔량은 못 읽는다(XIAO ESP32-C3는 분압 저항을 따로 달아야 함, T152 §2-1). STATUS의 batt는 0xFF.

### 납땜이 필요한가

| 작업 | 필요 | 비고 |
|---|---|---|
| XIAO 헤더 핀 | 예 (추정 — 헤더가 납땜되지 않은 채로 오는지 판매 페이지 확인 필요) | 브레드보드로 시험하려면 필요 |
| DRV8833 모듈 헤더 핀 | 예 (추정, 같은 이유) | |
| 배터리 → XIAO 뒷면 BAT+/BAT− 패드 | **예** | 패드라서 납땜 말고는 붙일 방법이 없다 |
| 모터 리드선 → 연장선 | 예 (또는 단자대) | 모터 선이 가늘고 짧다(추정). 위치를 바꿔 가며 시험하려면 길게 늘여야 한다 |

납땜 없이 먼저 해 볼 수 있는 방법(추정): 배터리 대신 USB-C 보조배터리로 XIAO를 켜고, DRV8833 VM을 XIAO 5V 핀에 연결(USB 전원일 때만 5V가 나옴, 추정). 헤더 핀과 모터 선은 여전히 남는다.

## 빌드 (Arduino IDE 2)

1. Arduino IDE 2 설치.
2. 파일 → 기본 설정 → 추가 보드 관리자 URL에 `https://espressif.github.io/arduino-esp32/package_esp32_index.json` (Seeed 위키 안내와 같음).
3. 보드 관리자에서 **esp32 by Espressif Systems 3.x** 설치. (2.x를 쓰면 `ledcAttach`가 없어 빌드 오류 — 그때는 3.x로 올린다.)
4. `hardware/vib_module/vib_module.ino` 열기 (폴더 이름과 파일 이름이 같아야 한다 — 이미 같다).
5. 도구 → 보드 → **XIAO_ESP32C3**. 확인(✓) 버튼으로 빌드.

명령줄(arduino-cli, **이 PC에서 실행해 보지 않음**):

```
arduino-cli core install esp32:esp32 --additional-urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
arduino-cli compile --fqbn esp32:esp32:XIAO_ESP32C3 hardware/vib_module
```

`test/` 폴더는 Arduino 빌드가 읽지 않는다(스케치 빌드는 폴더 맨 위와 `src/`만 컴파일, 추정).

## 펌웨어 올리기

1. XIAO를 USB-C 데이터 케이블로 PC에 꽂는다.
2. 도구 → 포트에서 새로 생긴 COM 포트를 고른다.
3. 업로드(→) 버튼.
4. 올라가지 않으면: XIAO의 **BOOT 버튼을 누른 채** USB를 꽂고 다시 업로드(Seeed 위키 안내, 추정 — 실물 확인 필요).
5. 확인: 폰 앱 설정 → 진동 모듈 (개발) → 진동 모듈 연결 켬 → 상태가 "연결됨" → "왼쪽 시험"·"오른쪽 시험"으로 각각 한쪽만 떨리는지 본다. nRF Connect 같은 BLE 앱으로 `CW-VIB`가 보이는지도 확인할 수 있다.

## 시험 (이 PC에서 실행함)

Git Bash, 저장소 루트에서:

```
mkdir -p hardware/vib_module/build && g++ -std=c++17 -Wall -Wextra -o hardware/vib_module/build/host_test.exe hardware/vib_module/test/host_test.cpp && hardware/vib_module/build/host_test.exe
```

결과(2026-10-29, g++ 16.1.0 MinGW-W64): `검사 39개, 실패 0개`, 종료 코드 0. 바이트 예시는 앱 시험(`crosswalk_app/test/vib_module_test.dart`)과 같은 값을 쓴다(PULSE `01 02 0F C8 07`, 차도 PATTERN `02 03 FF 03 0D 0D 0D 0D 0D 00 09`).
