# 0단계 영상 검토용 프레임 시트 (추론 없음: 프레임 추출·리사이즈·글자만)
import cv2, json, glob, os, sys, numpy as np, datetime
OUT = 'train/obstacle_stage0'
LOGS = {'20261002': 'logs/log_20261002_123306.jsonl', '20261012': 'logs/log_20261012_182701.jsonl',
        '20261016': 'logs/log_20261016_183319-11.jsonl', '20261019': 'logs/log_20261019_164736.jsonl'}
def wr(p, im): open(p, 'wb').write(cv2.imencode('.jpg', im, [cv2.IMWRITE_JPEG_QUALITY, 85])[1].tobytes())
align = {}
for f in glob.glob('train/field_t106/2026*/summary.json'):
    for a in json.load(open(f, encoding='utf-8'))['video_alignment']:
        align[a['video']] = (a['start_epoch'], a['offset_s'])
def states(day):
    if day not in LOGS: return None
    ev = [json.loads(l) for l in open(LOGS[day], encoding='utf-8') if l.strip()]
    return [(d['t'] / 1000, d['to']) for d in ev if d.get('ev') == 'state']
def state_at(st, t):
    s = None
    for tt, to in st:
        if tt <= t: s = to
        else: break
    return s
def frames(path, step):
    cap = cv2.VideoCapture(path); nxt = 0.0; out = []
    while True:
        ok, f = cap.read()
        if not ok: break
        ms = cap.get(cv2.CAP_PROP_POS_MSEC)
        if ms / 1000 >= nxt:
            out.append((ms, f)); nxt += step
    return out
def run(path, step, tw, cols, rows):
    name = os.path.basename(path); day = name.split('_')[-2] if name.startswith('Screen') else None
    st = states(day) if day else None; al = align.get(name)
    fr = frames(path, step); per = cols * rows; meta = []
    for si in range(0, len(fr), per):
        chunk = fr[si:si + per]; th = None; tiles = []
        for ms, f in chunk:
            h, w = f.shape[:2]; th = int(h * tw / w)
            im = cv2.resize(f, (tw, th), interpolation=cv2.INTER_AREA)
            # 경로 구역(가운데 1/3) 표시선
            cv2.line(im, (tw // 3, 0), (tw // 3, th), (0, 255, 255), 1); cv2.line(im, (2 * tw // 3, 0), (2 * tw // 3, th), (0, 255, 255), 1)
            lab = f'{ms/1000:.1f}s'
            s = None
            if st and al: s = state_at(st, al[0] + ms / 1000 - al[1])
            if s: lab += ' ' + s
            meta.append((ms, s))
            cv2.rectangle(im, (0, 0), (tw, 22), (0, 0, 0), -1); cv2.putText(im, lab, (3, 16), 0, 0.5, (255, 255, 255), 1)
            tiles.append(im)
        while len(tiles) < per: tiles.append(np.zeros_like(tiles[0]))
        grid = np.vstack([np.hstack(tiles[r * cols:(r + 1) * cols]) for r in range(rows)])
        wr(f'{OUT}/sheets/{os.path.splitext(name)[0]}_{si//per:02d}.jpg', grid)
    return meta
res = {}
for p in sorted(glob.glob('videos/Screen_Recording_*.mp4')):
    res[os.path.basename(p)] = run(p, 1.5, 180, 10, 2)
for p in sorted(glob.glob('videos/h0/*.mp4')) + sorted(glob.glob('videos/h0/night/*.mp4')):
    res[os.path.basename(p)] = run(p, 1.0, 320, 5, 4)
json.dump(res, open(f'{OUT}/sheets/_meta.json', 'w'), ensure_ascii=False)
print('done', sum(len(v) for v in res.values()))
