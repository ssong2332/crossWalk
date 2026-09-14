"""T90: 기준선 / (a) / (b) CV 결과를 앱 임계값으로 같은 자로 비교."""
import json, sys
from collections import Counter
from pathlib import Path
TH = {"front": 0.40, "none": 0.40, "approach": 0.55, "left": 0.55, "right": 0.55}
def dec(p):
    l = max(p, key=p.get); return l if p[l] >= TH[l] else "nocall"
def summarize(path):
    recs = json.load(open(path, encoding="utf-8"))
    seen = set(); rows = []
    for r in recs:  # 근사중복 클러스터당 1장 (주 지표와 동일)
        if r["dupc"] in seen: continue
        seen.add(r["dupc"]); rows.append((r["true"], dec(r["probs"])))
    n = Counter(t for t, _ in rows); c = Counter(rows)
    on = ("front", "left", "right")
    out = {
        "n": len(rows),
        "none→approach": c[("none", "approach")] / n["none"],
        "none→위(f/l/r)": sum(c[("none", x)] for x in on) / n["none"],
        "none 재현": c[("none", "none")] / n["none"],
        "approach 재현": c[("approach", "approach")] / n["approach"],
        "front 재현": c[("front", "front")] / n["front"],
        "left 재현": c[("left", "left")] / n["left"],
        "right 재현": c[("right", "right")] / n["right"],
        "위→none": sum(c[(x, "none")] for x in on) / sum(n[x] for x in on),
        "approach→none": c[("approach", "none")] / n["approach"],
    }
    return out
names = sys.argv[1:] or ["groupkfold_t90_baseline", "groupkfold_t90_a", "groupkfold_t90_b"]
res = {nm: summarize(Path(nm) / "all_probs.json") for nm in names if (Path(nm) / "all_probs.json").exists()}
keys = list(next(iter(res.values())).keys())
print(f"{'지표':18}" + "".join(f"{nm.replace('groupkfold_t90_',''):>12}" for nm in res))
for k in keys:
    print(f"{k:18}" + "".join(f"{res[nm][k]:>12}" if k == "n" else f"{res[nm][k]*100:>11.1f}%" for nm in res))
