# criteria.md 규칙으로 dets.json 판정. 추론 없음(결과 읽기만).
import csv, json, sys
ST = 'train/obstacle_stage0'; OUT = f'{ST}/stage1'
GATE = {'screen': (142.8, 216.6), 'h0': (37.8, 322.2)}
NIGHT = ('20260929', '20261012', '20261016', 'h0/night')
EXCLUDE = {('Screen_Recording_20261002_131228.mp4', '1'), ('h0/20261014_165824_c5.mp4', '1'),
           ('Screen_Recording_20260929_210334.mp4', '2')}


def in_gate(v, bx):
    lo, hi = GATE['h0' if v.startswith('h0') else 'screen']
    return lo <= (bx[0] + bx[2]) / 2 <= hi


def episodes(frames, thr, v, t0, t1):
    """창 [t0,t1] 안 경고 묶음: (시작t, 끝t, 최고점수, 상자). 연속 2프레임 칸 안 검출 = 성립, 1초 이상 끊기면 새 묶음."""
    eps, run, last_end = [], [], None
    for fr in frames:
        if not (t0 <= fr['t'] <= t1):
            run = []; continue
        hits = [d for d in fr['det'] if d[4] >= thr and in_gate(v, d)]
        if hits:
            run.append((fr['t'], max(hits, key=lambda d: d[4])))
            if len(run) >= 2:
                if eps and run[-1][0] - eps[-1][1] < 1.0:
                    eps[-1][1] = run[-1][0]; eps[-1][2] = max(eps[-1][2], run[-1][1][4])
                else:
                    eps.append([run[-2][0], run[-1][0], max(run[-2][1][4], run[-1][1][4]), run[-2][1]])
        else:
            run = []
    return eps


def main(thr):
    dets = {(d['video'], d['n']): d for d in json.load(open(f'{OUT}/dets.json', encoding='utf-8'))}
    arr = {(r['영상'], r['건너기']): r for r in csv.DictReader(open(f'{ST}/arrival_bollard.csv', encoding='utf-8'))}
    rec, fa, n_fa = [], [], 0
    for key, d in dets.items():
        v = key[0]; night = any(s in v for s in NIGHT)
        ar = arr.get(key)
        if key in EXCLUDE:
            continue
        if ar and ar['가운데진입_s'][:1].isdigit() and '먼 곳만' not in ar['가운데진입_s']:
            vis, line = float(ar['처음보임_s']), float(ar['볼라드선도달_s'])
            w0, w1 = vis - 1, line - 2.4
            eps = episodes(d['frames'], thr, v, w0, w1) if w1 >= w0 else []
            late = episodes(d['frames'], thr, v, w0, line)  # 참고: 선 도달 전 아무 때나
            rec.append({'video': v, 'n': key[1], 'night': night, 'window': [w0, round(w1, 2)], 'eps': eps,
                        'first_any_before_line': (round(line - late[0][0], 2) if late else None),
                        'ctr_dist': ar['가운데진입거리_m(추정)']})
            fw = (d['t0'], vis - 1); kind = '가운데건(보이기 전)'
            n_fa += 1
        else:
            fw = (d['t0'], d['t1']); n_fa += 1
            kind = '옆칸' if ar else '볼라드없음'
        for e in episodes(d['frames'], thr, v, *fw):
            fa.append({'video': v, 'n': key[1], 'night': night, 'ep': e,
                       'kind': kind})
    return rec, fa, n_fa


if __name__ == '__main__':
    out = {}
    for thr in (0.3, 0.5):
        rec, fa, n = main(thr)
        ok = sum(1 for r in rec if r['eps'])
        print(f'thr {thr}: 재현 후보 {ok}/{len(rec)}  오경보 묶음 {len(fa)} / 건너기 {n}  -> 20회당 {len(fa)/n*20:.2f}')
        for r in rec:
            print('  R', r['video'][-30:], r['n'], 'night' if r['night'] else 'day', r['window'], 'eps', [(e[0], e[1], e[2]) for e in r['eps']], 'first_any_before_line', r['first_any_before_line'], 'ctr', r['ctr_dist'])
        for f in fa:
            print('  F', f['video'][-30:], f['n'], f['kind'], f['ep'][:3], f['ep'][3][:4])
        out[str(thr)] = {'recall': rec, 'false_alarms': fa, 'n_fa_crossings': n}
    json.dump(out, open(f'{OUT}/eval.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
