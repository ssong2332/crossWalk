# 도착 신호 후보를 기록에서 뽑아 영상 시각으로 옮김. 추론 없음(기록 읽기만).
import json, glob, sys
LOGS = {'20261002': 'logs/log_20261002_123306.jsonl', '20261012': 'logs/log_20261012_182701.jsonl',
        '20261016': 'logs/log_20261016_183319-11.jsonl', '20261019': 'logs/log_20261019_164736.jsonl'}
align = {}
for f in glob.glob('train/field_t106/2026*/summary.json'):
    for a in json.load(open(f, encoding='utf-8'))['video_alignment']:
        align[a['video']] = (a['start_epoch'], a['offset_s'])
def signals(video, t0, t1):
    day = video.split('_')[2]; s0, off = align[video]
    ev = [json.loads(l) for l in open(LOGS[day], encoding='utf-8') if l.strip()]
    v = lambda d: d['t'] / 1000 - s0 + off
    out = {'crossed': None, 'hold_ground': None, 'side50': None, 'dot10': None, 'surf_n': 0}
    for d in ev:
        tv = v(d)
        if not (t0 <= tv <= t1): continue
        if d['ev'] == 'state' and d['to'] == 'crossed' and out['crossed'] is None: out['crossed'] = round(tv, 1)
        if d['ev'] == 'hold.end' and d.get('why') == 'ground' and out['hold_ground'] is None: out['hold_ground'] = round(tv, 1)
        if d['ev'] == 'surf' and d.get('ok'):
            out['surf_n'] += 1
            F = d['F']
            if F[0] >= 0.5 and out['side50'] is None: out['side50'] = round(tv, 1)
            if F[3] >= 0.10 and out['dot10'] is None: out['dot10'] = round(tv, 1)
    return out
if __name__ == '__main__':
    print(signals(sys.argv[1], float(sys.argv[2]), float(sys.argv[3])))


def sustained(video, t_mid, t_line, idx, thr):
    """t_mid~t_line 사이에서, 그 시각부터 t_line까지 앞 칸 비율이 계속 thr 이상인 가장 이른 시각."""
    day = video.split('_')[2]; s0, off = align[video]
    rows = []
    for l in open(LOGS[day], encoding='utf-8'):
        d = json.loads(l)
        if d.get('ev') == 'surf' and d.get('ok'):
            tv = d['t'] / 1000 - s0 + off
            if t_mid <= tv <= t_line: rows.append((tv, d['F'][idx]))
    best = None
    for tv, r in reversed(rows):
        if r >= thr: best = tv
        else: break
    return (round(best, 1) if best is not None else None), len(rows)
