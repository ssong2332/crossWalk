# T194 B 구현 확인용 재생: 앱 규칙 "좌/우 → front는 front가 HOLD초 이어진 뒤에만 복귀
# (복귀 진동·딩·'직진하세요')"를 기록의 alert 프레임에 다시 적용해 전/후를 센다.
#   전: 기록에 실제로 나간 복귀 진동(vib kind=recover)과 '직진하세요'(say)
#   후: front가 시작된 뒤 HOLD 이상 지난 첫 front alert 프레임에서만 복귀(그 전에 front가 끝나면 없음)
#   F(거짓 직진 대리): front가 2.0초 안에 끝나고 다시 left/right (fast_turn_scan과 같은 정의, 추정)
# 사용: PYTHONIOENCODING=utf-8 python train/t194/front_hold_replay.py [HOLD초=1.0]
# 근사: 끝 '이미 틀었음'(vibAs)·하강 유지(T157 P1)는 따로 보지 않는다 — 기록의 front 시작 시각만 본다.
import json, sys, statistics as st

LOGS = ['C:/vibecoding/crossWalk/logs/log_20261122_185021.jsonl',
        'C:/vibecoding/crossWalk/logs/log_20261118_183224.jsonl']
DEV = {'left', 'right'}
STRAIGHT = '직진하세요'


def load(f):
    return [json.loads(l) for l in open(f, encoding='utf-8') if l.strip()]


def fronts(R):
    """좌/우 바로 다음에 온 front 구간: (시작 ms, 끝 ms, 다음 상태)."""
    S = [r for r in R if r['ev'] == 'state']
    out = []
    for p, s, n in zip(S, S[1:], S[2:]):
        if p['to'] in DEV and s['to'] == 'front':
            out.append((s['ms'], n['ms'], n['to']))
    return out


def run(f, hold_ms):
    R = load(f)
    F = fronts(R)
    front_alerts = [r['ms'] for r in R if r['ev'] == 'alert' and r.get('cls') == 'front']
    rec = [r['ms'] for r in R if r['ev'] == 'vib' and r.get('kind') == 'recover']
    says = [r['ms'] for r in R if r['ev'] == 'say' and r.get('text') == STRAIGHT]

    def seg(ms):  # ms가 속한 front 구간
        for a, b, n in F:
            if a - 150 <= ms < b + 150:
                return a, b, n
        return None

    out = dict(fronts=len(F), F=0, T=0, recF_before=0, recT_before=0,
               recF_after=0, recT_after=0, sayF_before=0, sayF_after=0,
               rec_delay=[], say_shift=[], say_after=0, say_before=len(says), lostT=[])
    for a, b, n in F:
        d = b - a
        isF = d <= 2000 and n in DEV
        out['F' if isF else 'T'] += 1
        before = any(a - 150 <= m < b + 150 for m in rec)
        conf = next((m for m in front_alerts if a + hold_ms <= m < b), None)
        if before:
            out['recF_before' if isF else 'recT_before'] += 1
        if before:
            # 규칙은 막기만 한다: 원래 복귀가 HOLD 뒤였으면(T157 하강 유지 등) 그대로.
            first = min(m for m in rec if a - 150 <= m < b + 150)
            new = first if first - a >= hold_ms else conf
            if new is not None:
                out['recF_after' if isF else 'recT_after'] += 1
                if not isF:
                    out['rec_delay'].append((new - first) / 1000)
            elif not isF:
                out['lostT'].append((round(d / 1000, 2), n))
        for m in says:
            if a - 150 <= m < b + 150:
                if isF:
                    out['sayF_before'] += 1
                # 후: 지금 시각이 HOLD 전이면 HOLD 뒤 첫 front 프레임으로 밀림, 그 전에 끝나면 없음
                if m - a >= hold_ms:
                    out['say_after'] += 1
                    out['say_shift'].append(0.0)
                    if isF:
                        out['sayF_after'] += 1
                elif conf is not None:
                    out['say_after'] += 1
                    out['say_shift'].append((conf - m) / 1000)
                    if isF:
                        out['sayF_after'] += 1
    # 좌/우 직후가 아닌 front의 '직진하세요'(예: 정지 중)는 그대로 센다.
    in_seg = sum(1 for m in says if seg(m))
    out['say_after'] += len(says) - in_seg
    return out


def summ(xs):
    if not xs:
        return '-'
    return f'중앙 {st.median(xs):.2f} / 최소 {min(xs):.2f} / 최대 {max(xs):.2f} (n={len(xs)})'


def selftest():
    R = [dict(ev='state', to='left', ms=0), dict(ev='state', to='front', ms=1000),
         dict(ev='alert', cls='front', ms=1000), dict(ev='vib', kind='recover', ms=1000),
         dict(ev='alert', cls='front', ms=1400),
         dict(ev='state', to='right', ms=1500),
         dict(ev='state', to='front', ms=3000), dict(ev='vib', kind='recover', ms=3000),
         dict(ev='alert', cls='front', ms=3000), dict(ev='alert', cls='front', ms=4100),
         dict(ev='say', text=STRAIGHT, ms=3700),
         dict(ev='state', to='none', ms=9000), dict(ev='state', to='none', ms=9500)]
    import tempfile, os
    p = os.path.join(tempfile.mkdtemp(), 't.jsonl')
    with open(p, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(json.dumps(r) for r in R))
    o = run(p, 1000)
    assert (o['F'], o['T']) == (1, 1), o
    assert (o['recF_before'], o['recF_after']) == (1, 0), o
    assert (o['recT_before'], o['recT_after']) == (1, 1), o
    assert o['rec_delay'] == [1.1], o
    assert o['lostT'] == [], o
    assert o['say_shift'] == [0.4], o


if __name__ == '__main__':
    hold = float(sys.argv[1]) if len(sys.argv) > 1 else 1.0
    selftest()
    print(f'자체 검증 통과. HOLD={hold}초')
    for f in LOGS:
        o = run(f, int(hold * 1000))
        name = f.rsplit('/', 1)[1]
        print(f'\n== {name} ==')
        print(f"좌/우 뒤 front 구간 {o['fronts']} (F {o['F']} / T {o['T']})")
        print(f"복귀 진동이 나간 F(거짓 직진): 전 {o['recF_before']} → 후 {o['recF_after']}")
        print(f"복귀 진동이 나간 T(진짜 직진): 전 {o['recT_before']} → 후 {o['recT_after']}")
        print(f"F 동안 '직진하세요': 전 {o['sayF_before']} → 후 {o['sayF_after']}")
        print(f"'직진하세요' 전체: 전 {o['say_before']} → 후 {o['say_after']}")
        print(f"T 복귀 진동·딩 지연(초): {summ(o['rec_delay'])}")
        print(f"복귀가 없어지는 T (front 길이초, 다음 상태): {sorted(o['lostT'])}")
        print(f"'직진하세요' 지연(초, 남은 것): {summ(o['say_shift'])}")
