// T153: BLE 좌우 진동 모듈 규약 v1 — 명령 해석·진동 재생·무응답 감시.
// Arduino에 기대지 않는다(호스트 g++ 시험: test/host_test.cpp).
// 앱 쪽 값: crosswalk_app/lib/services/vib_module.dart (VibModuleProtocol). 둘이 같아야 한다.
#pragma once
#include <stddef.h>
#include <stdint.h>

namespace vib {

// 명령 (폰 → 기기, CMD 특성). 시간 단위 10ms.
constexpr uint8_t OP_PULSE = 0x01;    // 01 side dur str seq
constexpr uint8_t OP_PATTERN = 0x02;  // 02 side str n (on off)*n seq
constexpr uint8_t OP_STOP = 0x03;     // 03 seq
constexpr uint8_t OP_PING = 0x10;     // 10 seq  → STATUS PONG

// 상태 (기기 → 폰, STATUS 특성 Notify): type seq batt flags
constexpr uint8_t ST_PONG = 0x01;
constexpr uint8_t ST_ERROR = 0x02;  // flags = 오류 번호
constexpr uint8_t BATT_UNKNOWN = 0xFF;  // 분압 저항이 없으면 배터리를 못 읽는다

// 모터 고르기(비트)
constexpr uint8_t SIDE_LEFT = 1;
constexpr uint8_t SIDE_RIGHT = 2;
constexpr uint8_t SIDE_BOTH = 3;

// 오류 번호
constexpr uint8_t ERR_NONE = 0;
constexpr uint8_t ERR_SHORT = 1;  // 길이가 모자람
constexpr uint8_t ERR_OP = 2;     // 모르는 op
constexpr uint8_t ERR_SIDE = 3;   // side가 1~3이 아님
constexpr uint8_t ERR_PAIRS = 4;  // n이 0이거나 4보다 큼

constexpr uint32_t UNIT_MS = 10;
constexpr uint8_t MAX_PAIRS = 4;

// T152 §3-5 초안 값(추정): 3초 동안 아무것도 못 받으면 모터를 끄고 끊김을 알린다.
constexpr uint32_t LINK_TIMEOUT_MS = 3000;
// 끊김 알림: 양쪽 길게 1번(방향 150ms·복귀 60ms와 길이로 구분, 추정 값).
constexpr uint32_t LOST_BUZZ_MS = 500;

struct Step {
  uint32_t onMs;
  uint32_t offMs;
};

struct Command {
  uint8_t op = 0;
  uint8_t seq = 0;
  uint8_t side = 0;
  uint8_t strength = 0;
  uint8_t n = 0;
  Step steps[MAX_PAIRS] = {};
};

inline bool validSide(uint8_t s) { return s >= SIDE_LEFT && s <= SIDE_BOTH; }

// 바이트 → 명령. 성공하면 ERR_NONE. 실패해도 out.seq는 알 수 있으면 채운다(오류 응답용).
inline uint8_t parse(const uint8_t* d, size_t len, Command& out) {
  out = Command();
  if (len < 2) return ERR_SHORT;
  out.op = d[0];
  out.seq = d[len - 1];
  switch (out.op) {
    case OP_STOP:
    case OP_PING:
      return len == 2 ? ERR_NONE : ERR_SHORT;
    case OP_PULSE:
      if (len != 5) return ERR_SHORT;
      out.side = d[1];
      if (!validSide(out.side)) return ERR_SIDE;
      out.strength = d[3];
      out.n = 1;
      out.steps[0].onMs = static_cast<uint32_t>(d[2]) * UNIT_MS;
      out.steps[0].offMs = 0;
      return ERR_NONE;
    case OP_PATTERN: {
      if (len < 5) return ERR_SHORT;
      out.side = d[1];
      if (!validSide(out.side)) return ERR_SIDE;
      out.strength = d[2];
      out.n = d[3];
      if (out.n == 0 || out.n > MAX_PAIRS) return ERR_PAIRS;
      if (len != static_cast<size_t>(4 + 2 * out.n + 1)) return ERR_SHORT;
      for (uint8_t i = 0; i < out.n; i++) {
        out.steps[i].onMs = static_cast<uint32_t>(d[4 + 2 * i]) * UNIT_MS;
        out.steps[i].offMs = static_cast<uint32_t>(d[5 + 2 * i]) * UNIT_MS;
      }
      return ERR_NONE;
    }
    default:
      return ERR_OP;
  }
}

// 진동 재생. 받은 길이만큼 켠 뒤 스스로 끈다(기기는 반복하지 않는다 — 박자는 폰이 잰다).
// 새 명령이 오면 진행 중인 것을 버리고 새것을 시작한다.
class Player {
 public:
  void start(uint8_t side, uint8_t strength, const Step* steps, uint8_t n,
             uint32_t now) {
    if (n > MAX_PAIRS) n = MAX_PAIRS;
    side_ = side;
    strength_ = strength;
    n_ = n;
    for (uint8_t i = 0; i < n; i++) steps_[i] = steps[i];
    startedAt_ = now;
    active_ = n > 0;
  }

  void startCommand(const Command& c, uint32_t now) {
    start(c.side, c.strength, c.steps, c.n, now);
  }

  void stop() { active_ = false; }

  bool active() const { return active_; }
  uint8_t strength() const { return strength_; }

  // 지금 켜야 할 모터(비트). 0이면 모두 끔. 끝나면 스스로 멈춘다.
  // millis()가 한 바퀴 돌아도 뺄셈이 맞도록 경과 시간으로 계산한다.
  uint8_t update(uint32_t now) {
    if (!active_) return 0;
    uint32_t t = now - startedAt_;
    for (uint8_t i = 0; i < n_; i++) {
      if (t < steps_[i].onMs) return side_;
      t -= steps_[i].onMs;
      if (t < steps_[i].offMs) return 0;
      t -= steps_[i].offMs;
    }
    active_ = false;
    return 0;
  }

 private:
  bool active_ = false;
  uint8_t side_ = 0;
  uint8_t strength_ = 0;
  uint8_t n_ = 0;
  Step steps_[MAX_PAIRS] = {};
  uint32_t startedAt_ = 0;
};

// 무응답 감시: 마지막으로 받은 때부터 LINK_TIMEOUT_MS가 지나면 한 번 알린다.
class Watchdog {
 public:
  void feed(uint32_t now) {
    last_ = now;
    armed_ = true;
  }
  // 처음 넘긴 순간에만 true(한 번). 다시 feed되면 다시 무장한다.
  bool expiredOnce(uint32_t now) {
    if (!armed_) return false;
    if (now - last_ < LINK_TIMEOUT_MS) return false;
    armed_ = false;
    return true;
  }
  void disarm() { armed_ = false; }
  bool armed() const { return armed_; }

 private:
  uint32_t last_ = 0;
  bool armed_ = false;
};

// 세기(0~255) → PWM 듀티(0~maxDuty). maxDuty는 모터 정격에 맞춘 상한.
inline uint32_t dutyFor(uint8_t strength, uint32_t maxDuty) {
  return (static_cast<uint32_t>(strength) * maxDuty + 127) / 255;
}

}  // namespace vib
