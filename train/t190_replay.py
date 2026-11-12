"""T190 재생: 발밑 인도 해제(hold.end ground)에서 '건넜습니다'를 낸 줄(said=true)에
새 규칙(서서 기다리다 해제되면 막음)을 적용해 바뀌는 줄을 뽑는다.

규칙(`FeedbackService.noWalkCrossed`와 같다):
  R1 해제 순간 still 구간이 열려 있음                          -> 막음
  R2 위 지속 안에 W초 이상 still 구간이 있고, 그 마지막 구간이
     끝난 뒤 해제까지 T초 미만                                -> 막음
사용: python train/t190_replay.py [로그 폴더] [W] [T]   (기본 C:/vibecoding/crossWalk/logs 9.5 6)
"""
import datetime
import glob
import json
import sys

LOG_DIR = sys.argv[1] if len(sys.argv) > 1 else 'C:/vibecoding/crossWalk/logs'
W = float(sys.argv[2]) if len(sys.argv) > 2 else 9.5
T = float(sys.argv[3]) if len(sys.argv) > 3 else 6.0


def ts(t):
    return datetime.datetime.fromtimestamp(t / 1000).strftime('%m/%d %H:%M:%S.%f')[:-5]


def main():
    seen = set()
    total = changed = 0
    for path in sorted(glob.glob(LOG_DIR + '/*')):
        try:
            ev = [json.loads(l) for l in open(path, encoding='utf-8') if l.startswith('{')]
        except Exception:
            continue
        if not ev:
            continue
        key = ev[0].get('file') or path  # 같은 기록의 두 사본(.jsonl/.txt)은 한 번만
        if key in seen:
            continue
        seen.add(key)
        spans = []
        for e in ev:
            if e['ev'] == 'still':
                if e['on']:
                    spans.append([e['t'], None])
                elif spans and spans[-1][1] is None:
                    spans[-1][1] = e['t']
        for e in ev:
            if e['ev'] != 'hold.end' or 'walk_ms' not in e or not e['said']:
                continue
            total += 1
            t = e['t']
            t0 = t - (e['dur'] or 0) * 1000
            why = None
            if any(s <= t and (en is None or en > t) for s, en in spans):
                why = 'R1 still'
            else:
                waits = [(max(s, t0), en) for s, en in spans
                         if en is not None and t0 < en <= t]
                waits = [(a, b) for a, b in waits if (b - a) / 1000 >= W]
                if waits:
                    after = (t - waits[-1][1]) / 1000
                    if after < T:
                        why = f'R2 wait={(waits[-1][1] - waits[-1][0]) / 1000:.1f}s after={after:.1f}s'
            if why:
                changed += 1
                print(f"{key}  {ts(t)}  dur={e['dur']}  walk={e['walk_ms'] / 1000:.1f}  -> {why}")
    print(f'said=true {total}, 막힘 {changed}, 그대로 {total - changed} (W={W}, T={T})')


if __name__ == '__main__':
    main()
