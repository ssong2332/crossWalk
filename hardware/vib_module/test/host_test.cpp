// T153: vib_protocol.h 호스트 시험 (Arduino 없이 g++로 빌드).
// 바이트 예시는 앱 시험(crosswalk_app/test/vib_module_test.dart)과 같은 값을 쓴다.
#include <cstdio>

#include "../vib_protocol.h"

static int failures = 0;
static int checks = 0;

#define CHECK(cond)                                              \
  do {                                                           \
    checks++;                                                    \
    if (!(cond)) {                                               \
      failures++;                                                \
      std::printf("실패 %s:%d  %s\n", __FILE__, __LINE__, #cond); \
    }                                                            \
  } while (0)

using namespace vib;

static void testParse() {
  Command c;
  // 앱: 방향 진동 [0,150], 오른쪽 모터, 세기 200, 번호 7
  const uint8_t pulse[] = {0x01, 2, 15, 200, 7};
  CHECK(parse(pulse, sizeof(pulse), c) == ERR_NONE);
  CHECK(c.op == OP_PULSE && c.side == SIDE_RIGHT && c.strength == 200);
  CHECK(c.seq == 7 && c.n == 1 && c.steps[0].onMs == 150);

  // 앱: 차도 짧게 3번 [0,125,125,125,125,125] → 13 단위, 마지막 끄기 0
  const uint8_t pat[] = {0x02, 3, 255, 3, 13, 13, 13, 13, 13, 0, 9};
  CHECK(parse(pat, sizeof(pat), c) == ERR_NONE);
  CHECK(c.op == OP_PATTERN && c.side == SIDE_BOTH && c.n == 3);
  CHECK(c.steps[2].onMs == 130 && c.steps[2].offMs == 0 && c.seq == 9);

  const uint8_t stop[] = {0x03, 5};
  CHECK(parse(stop, sizeof(stop), c) == ERR_NONE && c.op == OP_STOP);
  const uint8_t ping[] = {0x10, 6};
  CHECK(parse(ping, sizeof(ping), c) == ERR_NONE && c.seq == 6);

  // 오류
  const uint8_t one[] = {0x01};
  CHECK(parse(one, sizeof(one), c) == ERR_SHORT);
  const uint8_t badOp[] = {0x7F, 1};
  CHECK(parse(badOp, sizeof(badOp), c) == ERR_OP && c.seq == 1);
  const uint8_t badSide[] = {0x01, 0, 15, 255, 3};
  CHECK(parse(badSide, sizeof(badSide), c) == ERR_SIDE);
  const uint8_t badSide4[] = {0x01, 4, 15, 255, 3};
  CHECK(parse(badSide4, sizeof(badSide4), c) == ERR_SIDE);
  const uint8_t tooMany[] = {0x02, 3, 255, 5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2};
  CHECK(parse(tooMany, sizeof(tooMany), c) == ERR_PAIRS);
  const uint8_t badLen[] = {0x02, 3, 255, 2, 1, 1, 9};
  CHECK(parse(badLen, sizeof(badLen), c) == ERR_SHORT);
  const uint8_t pulseLong[] = {0x01, 1, 15, 255, 3, 0};
  CHECK(parse(pulseLong, sizeof(pulseLong), c) == ERR_SHORT);
}

static void testPlayer() {
  Player p;
  Command c;
  const uint8_t pulse[] = {0x01, 1, 15, 255, 1};
  parse(pulse, sizeof(pulse), c);
  p.startCommand(c, 1000);
  CHECK(p.update(1000) == SIDE_LEFT);
  CHECK(p.update(1149) == SIDE_LEFT);
  CHECK(p.update(1150) == 0);  // 150ms 뒤 스스로 끔
  CHECK(!p.active());
  CHECK(p.update(5000) == 0);

  // 짧게 3번: 켬 130 / 끔 130 / … / 마지막 켬 130 뒤 끝
  const uint8_t pat[] = {0x02, 3, 255, 3, 13, 13, 13, 13, 13, 0, 9};
  parse(pat, sizeof(pat), c);
  p.startCommand(c, 0);
  CHECK(p.update(10) == SIDE_BOTH);
  CHECK(p.update(140) == 0);
  CHECK(p.update(270) == SIDE_BOTH);
  CHECK(p.update(400) == 0);
  CHECK(p.update(530) == SIDE_BOTH);
  CHECK(p.update(800) == 0 && !p.active());

  // 새 명령이 진행 중인 것을 바꾼다, STOP은 바로 끈다
  p.startCommand(c, 0);
  const uint8_t right[] = {0x01, 2, 15, 255, 2};
  parse(right, sizeof(right), c);
  p.startCommand(c, 50);
  CHECK(p.update(60) == SIDE_RIGHT);
  p.stop();
  CHECK(p.update(61) == 0);
}

static void testWrap() {
  // millis() 한 바퀴: 시작이 0xFFFFFF00이어도 경과 시간으로 맞다.
  Player p;
  Step s{150, 0};
  p.start(SIDE_LEFT, 255, &s, 1, 0xFFFFFF00u);
  CHECK(p.update(0xFFFFFF80u) == SIDE_LEFT);  // 128ms
  CHECK(p.update(0x00000010u) == 0);          // 272ms
}

static void testWatchdog() {
  Watchdog w;
  CHECK(!w.expiredOnce(100000));  // 한 번도 받지 않았으면 알리지 않는다
  w.feed(1000);
  CHECK(!w.expiredOnce(3999));
  CHECK(w.expiredOnce(4000));  // 3초
  CHECK(!w.expiredOnce(9000));  // 한 번만
  w.feed(9000);
  CHECK(!w.expiredOnce(11000));
  CHECK(w.expiredOnce(12500));
}

static void testDuty() {
  CHECK(dutyFor(255, 191) == 191);
  CHECK(dutyFor(0, 191) == 0);
  CHECK(dutyFor(110, 191) == 82);
}

int main() {
  testParse();
  testPlayer();
  testWrap();
  testWatchdog();
  testDuty();
  std::printf("검사 %d개, 실패 %d개\n", checks, failures);
  return failures == 0 ? 0 : 1;
}
