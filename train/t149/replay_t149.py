"""T149: 진입 안내 규칙(approach -> 위 / none -> 위 + 건넌 뒤 9초 침묵)을 기록으로 재생한다.

feedback_service.dart `decidePhaseMessage`의 진입 판정만 옮겼다:
- 입력은 기록의 `alert` 줄(cls = alert()가 받은 클래스, 프레임마다).
- 건넌 신호: cls=crossed, 또는 `hold.end said:true` 직후 alert(none/approach) (T140).
- 같은 문장 3초 재쿨다운(T123)도 적용한다.

사용: python train/t149/replay_t149.py <로그>... [--window 9]
"""
import json
import sys
import datetime as dt

ON = {'front', 'left', 'right'}
ENTRY = '횡단보도 진입.'


def kst(ms):
    return (dt.datetime(1970, 1, 1) + dt.timedelta(milliseconds=ms, hours=9)).strftime('%H:%M:%S.%f')[:-3]


def replay(path, window_s):
    prev = ''
    last_crossed = None
    ground_crossed = False
    last_entry = None
    old, new = [], []
    for line in open(path, encoding='utf-8'):
        if not line.startswith('{'):
            continue
        try:
            e = json.loads(line)
        except ValueError:
            continue
        t, ev = e.get('t'), e.get('ev')
        if ev == 'hold.end' and e.get('said'):
            ground_crossed = True
            continue
        if ev != 'alert':
            continue
        cls = e.get('cls')
        from_none = prev == 'none' and (last_crossed is None or t - last_crossed >= window_s * 1000)
        if cls in ON and prev == 'approach':
            old.append(t)
        entering = cls in ON and (prev == 'approach' or from_none)
        if entering and (last_entry is None or t - last_entry >= 3000):
            last_entry = t
            new.append((t, prev, cls, None if last_crossed is None else (t - last_crossed) / 1000))
        gc = ground_crossed and cls in ('none', 'approach')
        ground_crossed = False
        if gc or cls == 'crossed':
            last_crossed = t
        prev = cls
    return old, new


def main():
    args = sys.argv[1:]
    window = 9.0
    if '--window' in args:
        i = args.index('--window')
        window = float(args[i + 1])
        del args[i:i + 2]
    for p in args:
        old, new = replay(p, window)
        old_set = set(old)
        print(f'== {p} (창 {window}초)')
        print(f'기존 규칙(approach -> 위) 진입 요청 {len(old)}번, 새 규칙 {len(new)}번')
        for t, prev, cls, gap in new:
            if t in old_set:
                continue
            g = '-' if gap is None else f'{gap:.1f}'
            print(f'  추가 {kst(t)}  {prev} -> {cls}  건넌 뒤 {g}초')


if __name__ == '__main__':
    main()
