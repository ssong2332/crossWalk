# T194 A: 정지 중 좌우 진동 재생. 기록의 vib(left/right)마다 정지 여부·끝 여부를 붙이고
# 앱 규칙(FeedbackService.stillVibSkip)을 그대로 적용해 전후를 센다.
#   끝(직전 alert edge) → 냄 / 걷는 중 → 냄 / 정지 중: 첫·반대쪽·단계 올라감 → 냄, 같은 쪽 같거나 낮은 단계 → 막음
#   서 있음이 바뀌면(still 줄) 기억을 비운다.
# 한계(추정): 막은 진동이 없어졌을 때 뒤따르는 판정·타이머 박자는 그대로라고 본다(앱도 박자는 이어 간다).
# 사용: PYTHONIOENCODING=utf-8 python train/t194/still_vib_replay.py [log ...]
import json,sys,collections as C
logs=sys.argv[1:] or ['C:/vibecoding/crossWalk/logs/log_20261122_185021.jsonl']
for LOG in logs:
    R=[json.loads(l) for l in open(LOG,encoding='utf-8') if l.strip()]
    still=False; edge=False; side=None; lv=0; c=C.Counter()
    for r in R:
        ev=r['ev']
        if ev=='still': still=r['on']; side=None
        elif ev=='alert': edge=bool(r.get('edge'))
        elif ev=='vib' and r.get('kind') in ('left','right'):
            k=r['kind']; l=r.get('lvl') or 0; w='정지' if still else '걷기'
            c[w+' 전']+=1; c[w+' 전 끝' if edge else w+' 전 끝아님']+=1
            skip=False
            if still and not edge:
                if side==k and l<=lv: skip=True
                else: side=k; lv=l
            if not skip: c[w+' 후']+=1
            else: c['막음 '+('timer' if r.get('src')=='timer' else 'alert')]+=1
    print(LOG.split('/')[-1])
    for k in ['정지 전','정지 전 끝','정지 전 끝아님','정지 후','걷기 전','걷기 후','막음 alert','막음 timer']: print(f'  {k}: {c[k]}')
