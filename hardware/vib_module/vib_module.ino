// T153: 횡단보도 안내 앱용 BLE 좌우 진동 모듈 펌웨어 (Seeed XIAO ESP32-C3).
// 규약: vib_protocol.h, README.md. 앱: crosswalk_app/lib/services/vib_module.dart.
//
// 빌드: Arduino IDE 2 + 보드 패키지 "esp32 by Espressif Systems" 3.x, 보드 "XIAO_ESP32C3".
// 이 PC에서는 빌드하지 못했다(도구 없음 — README §빌드). 규약 부분만 호스트 시험을 통과했다.
//
// 동작 요약
// - BLE 서비스 1개: CMD(쓰기, 응답 없음) + STATUS(알림).
// - 명령마다 받은 길이만큼 켠 뒤 스스로 끈다. 기기는 반복하지 않는다(박자는 폰).
// - 3초 동안 아무것도 못 받거나 연결이 끊기면 모터를 끄고 양쪽 길게 1번(끊김 알림).
// - 연결이 끊기면 광고를 다시 시작한다.

#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

#include "vib_protocol.h"

// 앱(vib_module.dart)과 같은 값.
#define VIB_DEVICE_NAME "CW-VIB"
#define SERVICE_UUID "aef7a022-c301-40c9-8c59-0126d6388255"
#define CMD_UUID "aef7a023-c301-40c9-8c59-0126d6388255"
#define STATUS_UUID "aef7a024-c301-40c9-8c59-0126d6388255"

// 배선 (README §배선). DRV8833: 왼쪽 모터 = A 출력, 오른쪽 모터 = B 출력.
// XIAO ESP32-C3의 D0(GPIO2)·D8(GPIO8)·D9(GPIO9)는 부팅 설정 핀이라 피했다.
static const int PIN_L_IN1 = D1;  // AIN1 (PWM)
static const int PIN_L_IN2 = D2;  // AIN2 (LOW 고정)
static const int PIN_R_IN1 = D3;  // BIN1 (PWM)
static const int PIN_R_IN2 = D4;  // BIN2 (LOW 고정)
static const int PIN_SLEEP = D5;  // DRV8833 nSLEEP(모듈에 있으면). HIGH = 동작

// PWM: 20kHz(사람 귀에 덜 들림, 추정), 8비트.
static const uint32_t PWM_FREQ = 20000;
static const uint8_t PWM_BITS = 8;
// 듀티 상한: 모터 정격 3V(DVM1027) / 리튬 만충 약 4.2V ≈ 0.71 → 0.75 × 255 ≈ 191 (추정).
// 배터리 전압이 내려가면 실제 세기도 약해진다(전압 보정 없음).
static const uint32_t MAX_DUTY = 191;

static BLECharacteristic* gStatus = nullptr;
static BLEServer* gServer = nullptr;

// BLE 콜백(다른 작업)과 loop()가 함께 쓰는 값.
static portMUX_TYPE gMux = portMUX_INITIALIZER_UNLOCKED;
static volatile bool gHasCmd = false;
static uint8_t gCmdBuf[16];
static size_t gCmdLen = 0;
static volatile bool gConnected = false;
static volatile bool gJustDisconnected = false;

static vib::Player gPlayer;
static vib::Watchdog gWatchdog;
static bool gEverConnected = false;
static uint8_t gLastMask = 0xFF;
static uint8_t gLastStrength = 0;

static void writeMotors(uint8_t mask, uint8_t strength) {
  if (mask == gLastMask && strength == gLastStrength) return;
  gLastMask = mask;
  gLastStrength = strength;
  const uint32_t duty = vib::dutyFor(strength, MAX_DUTY);
  ledcWrite(PIN_L_IN1, (mask & vib::SIDE_LEFT) ? duty : 0);
  ledcWrite(PIN_R_IN1, (mask & vib::SIDE_RIGHT) ? duty : 0);
}

static void motorsOff() {
  gPlayer.stop();
  writeMotors(0, 0);
}

static void notifyStatus(uint8_t type, uint8_t seq, uint8_t flags) {
  if (gStatus == nullptr || !gConnected) return;
  uint8_t buf[4] = {type, seq, vib::BATT_UNKNOWN, flags};
  gStatus->setValue(buf, sizeof(buf));
  gStatus->notify();
}

// 끊김 알림: 양쪽 길게 1번. 연결된 적이 있을 때만.
static void lostBuzz(uint32_t now) {
  if (!gEverConnected) return;
  vib::Step s{vib::LOST_BUZZ_MS, 0};
  gPlayer.start(vib::SIDE_BOTH, 255, &s, 1, now);
}

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer*) override {
    gConnected = true;
  }
  void onDisconnect(BLEServer*) override {
    gConnected = false;
    gJustDisconnected = true;
  }
};

class CmdCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    // 콜백에서는 복사만 하고, 해석·재생은 loop()에서 한다.
    uint8_t* data = c->getData();
    size_t len = c->getLength();
    if (data == nullptr || len == 0) return;
    if (len > sizeof(gCmdBuf)) len = sizeof(gCmdBuf);
    portENTER_CRITICAL(&gMux);
    memcpy(gCmdBuf, data, len);
    gCmdLen = len;
    gHasCmd = true;  // 앞 명령을 아직 못 꺼냈으면 새것으로 덮는다(최신 우선).
    portEXIT_CRITICAL(&gMux);
  }
};

static void startAdvertising() {
  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  BLEDevice::startAdvertising();
}

void setup() {
  pinMode(PIN_L_IN2, OUTPUT);
  pinMode(PIN_R_IN2, OUTPUT);
  digitalWrite(PIN_L_IN2, LOW);
  digitalWrite(PIN_R_IN2, LOW);
  pinMode(PIN_SLEEP, OUTPUT);
  digitalWrite(PIN_SLEEP, HIGH);
  // esp32 보드 패키지 3.x API(2.x는 ledcSetup/ledcAttachPin — README §빌드).
  ledcAttach(PIN_L_IN1, PWM_FREQ, PWM_BITS);
  ledcAttach(PIN_R_IN1, PWM_FREQ, PWM_BITS);
  writeMotors(0, 0);

  BLEDevice::init(VIB_DEVICE_NAME);
  gServer = BLEDevice::createServer();
  gServer->setCallbacks(new ServerCallbacks());
  BLEService* service = gServer->createService(SERVICE_UUID);
  BLECharacteristic* cmd = service->createCharacteristic(
      CMD_UUID, BLECharacteristic::PROPERTY_WRITE |
                    BLECharacteristic::PROPERTY_WRITE_NR);
  cmd->setCallbacks(new CmdCallbacks());
  gStatus = service->createCharacteristic(STATUS_UUID,
                                          BLECharacteristic::PROPERTY_NOTIFY);
  gStatus->addDescriptor(new BLE2902());
  service->start();
  startAdvertising();
}

void loop() {
  const uint32_t now = millis();

  // 1) 연결 끊김: 모터 끄고 끊김 알림, 광고 다시 시작.
  if (gJustDisconnected) {
    gJustDisconnected = false;
    motorsOff();
    if (gWatchdog.armed()) lostBuzz(now);  // 무응답으로 이미 알렸으면 다시 울리지 않는다
    gWatchdog.disarm();
    delay(50);  // 스택이 정리될 시간(추정 값)
    startAdvertising();
  }

  // 2) 받은 명령 처리.
  if (gHasCmd) {
    uint8_t buf[sizeof(gCmdBuf)];
    size_t len;
    portENTER_CRITICAL(&gMux);
    len = gCmdLen;
    memcpy(buf, gCmdBuf, len);
    gHasCmd = false;
    portEXIT_CRITICAL(&gMux);

    gEverConnected = true;
    gWatchdog.feed(now);
    vib::Command c;
    const uint8_t err = vib::parse(buf, len, c);
    if (err != vib::ERR_NONE) {
      notifyStatus(vib::ST_ERROR, c.seq, err);
    } else if (c.op == vib::OP_PING) {
      notifyStatus(vib::ST_PONG, c.seq, 0);
    } else if (c.op == vib::OP_STOP) {
      motorsOff();
    } else {
      gPlayer.startCommand(c, now);
    }
  }

  // 3) 3초 무응답: 모터 끄고 끊김 알림(한 번). 연결은 폰 쪽이 끊는다.
  if (gWatchdog.expiredOnce(now)) {
    motorsOff();
    lostBuzz(now);
  }

  // 4) 모터 출력.
  writeMotors(gPlayer.update(now), gPlayer.strength());
  delay(1);
}
