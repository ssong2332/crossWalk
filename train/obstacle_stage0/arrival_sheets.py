# 도착 직전 볼라드 검토용: 건너기 끝 -9s ~ +2s, 0.5초 간격 시트. 추론 없음.
# 타일 왼쪽 눈금 = 원본 높이의 10% 간격(볼라드 크기 가늠용), 노란 세로선 = 가운데 1/3.
import csv, cv2, json, glob, os, numpy as np
OUT = 'train/obstacle_stage0/arrival'; os.makedirs(f'{OUT}/sheets', exist_ok=True)
LOGS = {'20261002': 'logs/log_20261002_123306.jsonl', '20261012': 'logs/log_20261012_182701.jsonl',
        '20261016': 'logs/log_20261016_183319-11.jsonl', '20261019': 'logs/log_20261019_164736.jsonl'}
align = {}
for f in glob.glob('train/field_t106/2026*/summary.json'):
    for a in json.load(open(f, encoding='utf-8'))['video_alignment']:
        align[a['video']] = (a['start_epoch'], a['offset_s'])
_st = {}
def states(day):
    if day not in _st:
        ev = [json.loads(l) for l in open(LOGS[day], encoding='utf-8') if l.strip()] if day in LOGS else []
        _st[day] = [(d['t'] / 1000, d['to']) for d in ev if d.get('ev') == 'state']
    return _st[day]
def state_at(st, t):
    s = None
    for tt, to in st:
        if tt <= t: s = to
        else: break
    return s
def wr(p, im): open(p, 'wb').write(cv2.imencode('.jpg', im, [cv2.IMWRITE_JPEG_QUALITY, 85])[1].tobytes())
def sheet(v, n, t0, t1, cols=8):
    path = 'videos/' + v; name = os.path.basename(v)
    st = al = None
    if name.startswith('Screen'):
        st = states(name.split('_')[2]); al = align.get(name)
    cap = cv2.VideoCapture(path)
    if 'h0' not in path: cap.set(cv2.CAP_PROP_POS_MSEC, max(t0 - 1.5, 0) * 1000)
    nxt = t0; tiles = []
    while nxt <= t1:
        ok, f = cap.read()
        if not ok: break
        ms = cap.get(cv2.CAP_PROP_POS_MSEC)
        if ms / 1000 < nxt: continue
        h, w = f.shape[:2]; port = h > w
        if port: f = f[:int(h * 0.78)]
        tw = 240 if port else 400; th = int(f.shape[0] * tw / w)
        im = cv2.resize(f, (tw, th), interpolation=cv2.INTER_AREA)
        for k in range(1, 10):  # 원본 높이 10% 눈금
            y = int(h * k / 10 * tw / w)
            if y < th: cv2.line(im, (0, y), (8, y), (0, 0, 255), 2)
        cv2.line(im, (tw // 3, 0), (tw // 3, th), (0, 255, 255), 1); cv2.line(im, (2 * tw // 3, 0), (2 * tw // 3, th), (0, 255, 255), 1)
        lab = f'{ms/1000:.1f}s'
        if st and al:
            s = state_at(st, al[0] + ms / 1000 - al[1])
            if s: lab += ' ' + s
        cv2.rectangle(im, (0, 0), (tw, 22), (0, 0, 0), -1); cv2.putText(im, lab, (3, 16), 0, 0.55, (255, 255, 255), 1)
        tiles.append(im); nxt += 0.5
    while len(tiles) % cols: tiles.append(np.zeros_like(tiles[0]))
    grid = np.vstack([np.hstack(tiles[r * cols:(r + 1) * cols]) for r in range(len(tiles) // cols)])
    out = f'{OUT}/sheets/{os.path.splitext(name)[0]}_{n}.jpg'; wr(out, grid); return out
for r in csv.DictReader(open('train/obstacle_stage0/crossings.csv', encoding='utf-8-sig')):
    if not r['도착끝 볼라드'].startswith('있음'): continue
    e = int(r['끝_ms']) / 1000
    print(sheet(r['영상'], r['건너기 번호'], max(e - 9, int(r['시작_ms']) / 1000), e + 2))
