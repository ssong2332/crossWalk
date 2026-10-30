"""T159: 후보 하나를 판정표 핵심 안만 빠르게 본다(전체 표는 t159_report.py).
    python train/t159_quick.py <이름> [점수,...]
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import t159_report as r  # noqa: E402
import t159_level_eval as ev  # noqa: E402

name = sys.argv[1]
scores = sys.argv[2].split(",") if len(sys.argv) > 2 else ["ord_reg", "ord_agree"]
f = lambda m: "/".join(f"{x * 100:.0f}" for x in m["rec"])
for sc in scores:
    for mode in ("plain", "tta"):
        d = r.from_t159(name, f"{sc}_{mode}")
        for ge in [(12, 25), (12, 27.5), (12, 30), (12, 20, 30)]:
            _, o = ev.evaluate(d, ge, {"전체": .8, "T150": .8, "기존": 0}, "x")
            a, t = o["전체"], o["T150"]
            sk = lambda m: max(m["s_to_top"], m["top_to_s"]) if len(ge) == 3 else m["top_to_s"]
            v = "통과" if a["pass"] and t["pass"] else ("반대 방향만 미달" if a["pass_wo_opp"] and t["pass_wo_opp"] else "")
            print(name, sc, mode, ge, f(a), f(t), f"{sk(a) * 100:.1f}/{sk(t) * 100:.1f}",
                  f"opp {a['opp']}/4;{t['opp']}/3", v, flush=True)
