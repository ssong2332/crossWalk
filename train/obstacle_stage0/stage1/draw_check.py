# 검출 상자를 입력(360x480) 위에 그려 눈으로 확인. 추론 결과(dets.json)만 사용.
import json, sys, os, cv2, numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from run_det import to_input, frames
OUT = 'train/obstacle_stage0/stage1/check'; os.makedirs(OUT, exist_ok=True)
dets = {(d['video'], d['n']): d for d in json.load(open('train/obstacle_stage0/stage1/dets.json', encoding='utf-8'))}


def tile(v, n, t, thr=0.3):
    d = dets[(v, n)]
    fr = min(d['frames'], key=lambda f: abs(f['t'] - t))
    for tt, f in frames('videos/' + v, fr['t'] - 0.01, fr['t'] + 0.2):
        _, can = to_input(f); break
    im = cv2.cvtColor(can, cv2.COLOR_RGB2BGR)
    lo, hi = ((37.8, 322.2) if v.startswith('h0') else (142.8, 216.6))
    cv2.line(im, (int(lo), 0), (int(lo), 480), (0, 255, 255), 1); cv2.line(im, (int(hi), 0), (int(hi), 480), (0, 255, 255), 1)
    for x0, y0, x1, y1, s in fr['det']:
        if s >= thr:
            cv2.rectangle(im, (int(x0), int(y0)), (int(x1), int(y1)), (0, 0, 255), 2)
            cv2.putText(im, f'{s:.2f}', (int(x0), max(int(y0) - 3, 10)), 0, 0.45, (0, 0, 255), 1)
    cv2.rectangle(im, (0, 0), (360, 18), (0, 0, 0), -1)
    cv2.putText(im, f'{os.path.basename(v)[-19:-4]} {fr["t"]:.1f}s', (2, 13), 0, 0.42, (255, 255, 255), 1)
    return im


if __name__ == '__main__':
    name = sys.argv[1]; specs = sys.argv[2:]
    ims = [tile(*s.split('|')[:2], float(s.split('|')[2])) for s in specs]
    while len(ims) % 6: ims.append(np.zeros_like(ims[0]))
    g = np.vstack([np.hstack(ims[i:i + 6]) for i in range(0, len(ims), 6)])
    open(f'{OUT}/{name}.jpg', 'wb').write(cv2.imencode('.jpg', g)[1].tobytes()); print(name)
