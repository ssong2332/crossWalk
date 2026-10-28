"""T148: 멈춤(점형)·선형 점자블록 오발화 — 노란색 확인 조건의 오프라인 재생(분석 전용).

세트(사람 판정, 근거는 train/t148_report.md):
  10/28 낮 `logs/crosswalk log 18e954a.txt` — 멈춤 블록 말함 16건(틀림 7·맞음 9), 선형 진동 10건(틀림 6·맞음 4)
           (T145 `train/field_1028/report_events.md` D·L 번호)
  10/26 밤 `logs/log_20261026_213316.jsonl` — 멈춤 블록 맞음 17건, 선형 있음 맞음 11건
           (`train/field_1026/tactile.json` j=='O')

방법:
  1. 이벤트 시각에 가장 가까운 앱 저장 프레임(1초 1장, `train/frames_1028b`·`train/frames_1026`)을
     앱과 같게 전처리(시계 방향 90° 회전 → 224×224로 누름 → ImageNet 정규화)해 노면 모델
     (`crosswalk_app/assets/model/crosswalk_surface.onnx`)을 돌린다. 앱이 실제로 본 프레임과는
     최대 ±0.6초 다르다(앱 노면 판정은 10프레임마다, 저장은 1초마다) — 근사.
  2. 아래 절반 앞 칸(가운데 1/3)에서 모델이 점형(5)/선형(4)으로 본 픽셀의 224 입력 RGB를 HSV로
     바꿔 '노란 픽셀 비율'(노란 픽셀 수 / 그 클래스 픽셀 수)을 잰다.
  3. 기록의 surf 줄만으로 연속 확인 횟수(2→3·4)를 바꿔 재생해, 각 이벤트가 그대로 나는지 본다.

실행(저장소 루트에서, 기록·프레임이 있는 체크아웃):
  PYTHONIOENCODING=utf-8 python <이 파일> [--sheet 출력.jpg]
출력: train/t148/events.csv, train/t148/summary.json (이 스크립트 옆 t148/)
"""
import argparse
import bisect
import csv
import glob
import json
import os
import sys

import cv2
import numpy as np
import onnxruntime as ort

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL = os.path.join(HERE, '..', 'crosswalk_app', 'assets', 'model', 'crosswalk_surface.onnx')
OUT = os.path.join(HERE, 't148')
S = 224
LIN, DOT = 4, 5

# 10/28 D 번호(dotBlock surf.ev 순서) 중 말한 것, 틀린 것 — report_events.md 4절.
D_SPOKEN = {1, 2, 4, 8, 10, 12, 16, 17, 20, 22, 23, 24, 26, 27, 28, 29}
D_FALSE = {1, 12, 16, 17, 22, 24, 26}
# 10/28 L 번호(vib kind=line_on 순서) 중 노란 선형이 보이는 것 — report_events.md 5절.
L_TRUE = {3, 6, 7, 8}


def load_log(p):
    out = []
    for i, l in enumerate(open(p, encoding='utf-8'), 1):
        d = json.loads(l)
        d['_n'] = i
        out.append(d)
    return out


def frames(d):
    fs = sorted((int(os.path.basename(p)[2:-4]), p) for p in glob.glob(os.path.join(d, 'f_*.jpg')))
    return fs, [t for t, _ in fs]


def near(fs, ts, t, tol=1500):
    i = bisect.bisect_left(ts, t)
    c = [j for j in (i - 1, i) if 0 <= j < len(ts)]
    if not c:
        return None
    j = min(c, key=lambda j: abs(ts[j] - t))
    return fs[j] if abs(ts[j] - t) <= tol else None


def sets(root):
    """[(set, id, kind, truth, t, frame_path, dt, logged_F)]"""
    rows = []
    L = load_log(os.path.join(root, 'logs', 'crosswalk log 18e954a.txt'))
    fs, ts = frames(os.path.join(root, 'train', 'frames_1028b'))
    surf = [d for d in L if d['ev'] == 'surf' and d.get('ok')]
    st = [d['t'] for d in surf]
    def lastF(t):
        i = bisect.bisect_right(st, t) - 1
        return surf[i]['F'] if i >= 0 else None
    k = 0
    for d in L:
        if d['ev'] == 'surf.ev' and 'dotBlock' in d['names']:
            k += 1
            if k in D_SPOKEN:
                fr = near(fs, ts, d['t'])
                rows.append(('1028', f'D{k}', 'dot', k not in D_FALSE, d['t'], fr[1] if fr else None,
                             fr[0] - d['t'] if fr else None, lastF(d['t']), d['_n']))
    k = 0
    for d in L:
        if d['ev'] == 'vib' and d.get('kind') == 'line_on':
            k += 1
            fr = near(fs, ts, d['t'])
            rows.append(('1028', f'L{k}', 'lin', k in L_TRUE, d['t'], fr[1] if fr else None,
                         fr[0] - d['t'] if fr else None, lastF(d['t']), d['_n']))
    tj = json.load(open(os.path.join(root, 'train', 'field_1026', 'tactile.json'), encoding='utf-8'))
    for x in tj:
        if x['ev'] in ('dotBlock', 'linearOn') and x['j'] == 'O':
            p = os.path.join(root, 'train', 'frames_1026', x['frame']) if x['frame'] else None
            rows.append(('1026', f"S{x['n']}", 'dot' if x['ev'] == 'dotBlock' else 'lin', True, x['t'], p,
                         x['dt'], x['F'], x['ln']))
    return rows


def preprocess(path):
    """앱 `AngleEstimator.preprocessFrame(cropRatio: 1.0)`과 같게: 회전 → 224 → (RGB uint8, 정규화 텐서)."""
    im = cv2.rotate(cv2.imdecode(np.fromfile(path, np.uint8), 1), cv2.ROTATE_90_CLOCKWISE)
    rgb = cv2.cvtColor(cv2.resize(im, (S, S), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2RGB)
    x = (rgb.astype(np.float32) / 255 - np.array([0.485, 0.456, 0.406], np.float32)) / \
        np.array([0.229, 0.224, 0.225], np.float32)
    return rgb, x.transpose(2, 0, 1)[None]


def hsv(rgb):
    """앱(Dart)에서 같은 식을 쓴다: H 0~360°, S·V 0~1."""
    f = rgb.astype(np.float32) / 255
    r, g, b = f[..., 0], f[..., 1], f[..., 2]
    mx, mn = f.max(-1), f.min(-1)
    d = mx - mn
    h = np.zeros_like(mx)
    m = d > 1e-6
    rr = m & (mx == r)
    gg = m & (mx == g) & ~rr
    bb = m & ~rr & ~gg
    h[rr] = (60 * ((g - b)[rr] / d[rr])) % 360
    h[gg] = 60 * ((b - r)[gg] / d[gg]) + 120
    h[bb] = 60 * ((r - g)[bb] / d[bb]) + 240
    s = np.where(mx > 1e-6, d / np.maximum(mx, 1e-6), 0)
    return h, s, mx


def front_region():
    m = np.zeros((S, S), bool)
    m[S // 2:, S // 3:2 * S // 3] = True
    return m


def replay(L, N, ratio, kind):
    """기록 surf 줄로 SurfaceGuide 3(점형)·5(선형 있음)을 연속 N회·비율 ratio로 다시 낸다 → 이벤트 시각 목록.
    선형은 단순화: 앞 칸이 꺼지면 바로 다시 켤 수 있게 둔다(옆·잃음 판정 생략)."""
    val, cand, n, armed, off, on, ev = False, None, 0, True, None, False, []
    idx = 3 if kind == 'dot' else 2
    for d in L:
        if d['ev'] != 'surf' or not d.get('ok'):
            continue
        t = d['t']
        if d['st'] not in ('none', 'crossed'):
            val, cand, n, armed, off, on = False, None, 0, True, None, False
            continue
        x = d['F'][idx] >= ratio
        ch = False
        if x == val:
            cand, n = None, 0
        else:
            if x == cand:
                n += 1
            else:
                cand, n = x, 1
            if n >= N:
                val, cand, n, ch = x, None, 0, True
        if kind == 'dot':
            if ch and val and armed:
                ev.append(t)
                armed = False
            if val:
                off = None
            else:
                off = off or t
                if t - off >= 3000:
                    armed = True
        else:
            if val and not on:
                ev.append(t)
            on = val
    return ev


def replay_table(root, rows):
    """연속 N·비율별로 세트 이벤트가 살아남는지(원래 시각 −1.5~+4초 안에 다시 나는지)."""
    logs = {'1028': load_log(os.path.join(root, 'logs', 'crosswalk log 18e954a.txt')),
            '1026': load_log(os.path.join(root, 'logs', 'log_20261026_213316.jsonl'))}
    out = []
    for kind in ('dot', 'lin'):
        for N in (2, 3, 4, 5):
            for ratio in (0.05, 0.10, 0.15, 0.20):
                ev = {s: replay(L, N, ratio, kind) for s, L in logs.items()}
                keptX, keptO, lostO = [], [], []
                for (sset, eid, k, truth, t, *_r) in rows:
                    if k != kind:
                        continue
                    hit = any(t - 1500 <= e <= t + 4000 for e in ev[sset])
                    if truth:
                        (keptO if hit else lostO).append(eid)
                    elif hit:
                        keptX.append(eid)
                nX = sum(1 for r in rows if r[2] == kind and not r[3])
                out.append(dict(kind=kind, N=N, ratio=ratio, X_left=len(keptX), X_total=nX,
                                O_left=len(keptO), O_total=len(keptO) + len(lostO),
                                X_left_ids=keptX, O_lost_ids=lostO,
                                events_1028=len(ev['1028']), events_1026=len(ev['1026'])))
    return out


def color_table(res):
    """노란 픽셀 비율(점형/선형 픽셀 중 H 25~65°, S≥0.35, V≥0.15) 기준값별 막힘/생존. 측정 불가(n<20)는 따로 센다."""
    out = []
    for kind in ('dot', 'lin'):
        for k in (0.05, 0.10, 0.20, 0.30, 0.50):
            X = [r for r in res if r['kind'] == kind and not r['truth']]
            O = [r for r in res if r['kind'] == kind and r['truth']]
            def passes(r):
                return r.get('yellow') is not None and r['yellow'] >= k
            out.append(dict(kind=kind, yellow_min=k,
                            X_blocked=sum(1 for r in X if r.get('yellow') is not None and not passes(r)),
                            X_total=len(X),
                            O_kept=sum(1 for r in O if passes(r)),
                            O_measured=sum(1 for r in O if r.get('yellow') is not None),
                            O_kept_1028=sum(1 for r in O if r['set'] == '1028' and passes(r)),
                            O_kept_1026=sum(1 for r in O if r['set'] == '1026' and passes(r)),
                            unmeasured=[r['id'] for r in X + O if r.get('yellow') is None]))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', default='.')
    ap.add_argument('--sheet', default=None)
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    sess = ort.InferenceSession(MODEL, providers=['CPUExecutionProvider'])
    inp = sess.get_inputs()[0].name
    FR = front_region()
    BOT = np.zeros((S, S), bool)
    BOT[S // 2:] = True
    rows = sets(a.root)
    res = []
    tiles = []
    for (sset, eid, kind, truth, t, path, dt, F, ln) in rows:
        r = dict(set=sset, id=eid, kind=kind, truth=int(truth), t=t, line=ln, dt=dt,
                 frame=os.path.basename(path) if path else '')
        r['log_dot'] = round(F[3], 3) if F else None
        r['log_lin'] = round(F[2], 3) if F else None
        if path:
            rgb, x = preprocess(path)
            sess_logits = sess.run(None, {inp: x})[0][0]
            mask = sess_logits.argmax(0)
            h, s, v = hsv(rgb)
            cls = DOT if kind == 'dot' else LIN
            sel = FR & (mask == cls)
            n = int(sel.sum())
            r['re_ratio'] = round(n / FR.sum(), 3)
            r['n'] = n
            if n >= 20:
                r['h_med'] = round(float(np.median(h[sel])), 1)
                r['s_med'] = round(float(np.median(s[sel])), 3)
                r['v_med'] = round(float(np.median(v[sel])), 3)
                yel = (h[sel] >= 25) & (h[sel] <= 65) & (s[sel] >= 0.35) & (v[sel] >= 0.15)
                r['yellow'] = round(float(yel.mean()), 3)
                # 상대 색차: Lab b*(노랑 쪽) — 이 클래스 픽셀 중앙값 − 아래 절반의 나머지 바닥(선형·점형 제외) 중앙값.
                lab = cv2.cvtColor(rgb, cv2.COLOR_RGB2LAB).astype(np.float32)
                bg = BOT & (mask != LIN) & (mask != DOT)
                r['db'] = round(float(np.median(lab[..., 2][sel]) - np.median(lab[..., 2][bg])), 1)
                lg = sess_logits
                p = np.exp(lg - lg.max(0))
                p /= p.sum(0)
                r['p_mean'] = round(float(p[cls][sel].mean()), 3)
            if a.sheet:
                im = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR).copy()
                ov = im.copy()
                ov[mask == cls] = (255, 0, 255)
                im2 = cv2.addWeighted(im, 0.55, ov, 0.45, 0)
                cv2.rectangle(im2, (S // 3, S // 2), (2 * S // 3, S - 1), (0, 255, 0), 1)
                both = np.hstack([im, im2])
                lab = f"{sset} {eid} {'O' if truth else 'X'} s{r.get('s_med')} h{r.get('h_med')}"
                cv2.rectangle(both, (0, 0), (both.shape[1], 16), (0, 0, 0), -1)
                cv2.putText(both, lab, (2, 12), 0, 0.42, (0, 255, 255), 1)
                tiles.append(both)
        res.append(r)
    keys = ['set', 'id', 'kind', 'truth', 't', 'line', 'frame', 'dt', 'log_dot', 'log_lin', 're_ratio', 'n',
            'h_med', 's_med', 'v_med', 'yellow', 'db', 'p_mean']
    with open(os.path.join(OUT, 'events.csv'), 'w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, keys)
        w.writeheader()
        for r in res:
            w.writerow({k: r.get(k) for k in keys})
    summary = dict(color=color_table(res), replay=replay_table(a.root, rows))
    json.dump(summary, open(os.path.join(OUT, 'summary.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    for c in summary['color']:
        print('color', c)
    for c in summary['replay']:
        print('replay', {k: v for k, v in c.items() if not k.endswith('_ids')})
    if a.sheet and tiles:
        cols = 4
        while len(tiles) % cols:
            tiles.append(np.zeros_like(tiles[0]))
        rows = [np.hstack(tiles[i:i + cols]) for i in range(0, len(tiles), cols)]
        cv2.imencode('.jpg', np.vstack(rows), [cv2.IMWRITE_JPEG_QUALITY, 80])[1].tofile(a.sheet)


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    main()
