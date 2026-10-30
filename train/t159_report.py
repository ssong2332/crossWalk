"""T159: 후보별 단계 판정표 -> train/t159/metrics.md (자동 생성).

후보 = (예측 CSV, 점수 조합). 판정 정의는 `t159_level_eval.py` 머리말.
    python train/t159_report.py
"""

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import t159_level_eval as ev  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
T151 = REPO / "train" / "t151"
OUT = REPO / "train" / "t159"

GT3 = [(12, 20, 30)]
GT2 = [(12, 20), (12, 22.5), (12, 25), (12, 27.5), (12, 30)]


def from_t151(name, key):
    d = ev.read_preds(T151 / f"cv_pred_{name}.csv", key)
    return d


def from_t159(name, score):
    """score: reg / ord_sgn / ord_reg / ord_agree  ×  _plain / _tta."""
    import csv
    with open(OUT / f"cv_pred_{name}.csv", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    base, mode = score.rsplit("_", 1)
    v = lambda c: np.array([float(r[c]) for r in rows])
    if mode == "plain":
        reg, oa, pr = v("reg_plain"), v("ord_plain"), v("pr_plain")
    else:
        reg = (v("reg_plain") + v("reg_flip")) / 2
        oa = (v("ord_plain") + v("ord_flip")) / 2
        pr = (v("pr_plain") + v("pr_flip")) / 2
    if base == "reg":
        s = reg
    elif base == "ord_sgn":
        s = np.where(pr >= 0.5, 1.0, -1.0) * oa
    elif base == "ord_reg":
        s = np.sign(reg) * oa
    else:  # ord_agree: 회귀 부호와 방향 머리가 다르면 직진(0)으로 둔다
        sg = np.sign(reg)
        s = np.where(sg == np.where(pr >= 0.5, 1.0, -1.0), sg * oa, 0.0)
    return {"src": np.array([r["src"] for r in rows]), "key": [(r["class"], r["filename"]) for r in rows],
            "fold": np.array([int(r["fold"]) for r in rows]), "group": np.array([r["group"] for r in rows]),
            "gt": np.array([float(r["geo_deg"]) for r in rows]), "pr": s}


LABELS = {"ord224": "ord224 (순서형, 224)", "ord288": "ord288 (순서형, 288 입력 변경)",
          "ordbw224": "ordbw224 (순서형, 큰 각 가중·반전 일관성)", "ordrot224": "ordrot224 (순서형, 회전 ±30)",
          "full224": "full224 (순서형, 시야 전체 — 입력 변경)",
          "fullbw224": "fullbw224 (순서형, 시야 전체·큰 각 가중·반전 일관성 — 입력 변경)"}


def candidates():
    c = [("G1 (T151) 단일", lambda: from_t151("G1", "plain")),
         ("G1 (T151) 반전 TTA", lambda: from_t151("G1", "tta"))]
    for f in sorted(OUT.glob("cv_pred_*.csv")):
        name = f.stem[len("cv_pred_"):]
        label = LABELS.get(name, name)
        for sc, sl in [("reg", "회귀"), ("ord_sgn", "순서형|각|·방향머리"), ("ord_reg", "순서형|각|·회귀부호"),
                       ("ord_agree", "순서형|각|·두 부호 일치만")]:
            for mode, ml in [("plain", "단일"), ("tta", "반전 TTA")]:
                c.append((f"{label} {sl} {ml}", lambda n=name, s=f"{sc}_{mode}": from_t159(n, s)))
    return c


def fixed_t103():
    """배포 T103(T150만) 고정 문턱 12/20/30 — 비교 기준."""
    d = ev.read_preds(T151 / "deployed_pred_t150.csv", "plain")
    return ev.judge(d["gt"], d["pr"], (12, 20, 30), (12, 20, 30), 0.80, ev.OPP_REF["T150"])


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    L = ["# T159 지표 (자동 생성: `python train/t159_report.py`)", "",
         "정답 = 기하각. 예측 문턱은 묶인 fold 조정(fold k 문턱은 나머지 4 fold의 전체·T150 여유 최솟값 최대).", ""]
    m = fixed_t103()
    L += ["## 기준: 배포 T103, T150 304장, 앱 문턱 12/20/30 그대로", ""] + ev.header(3) + \
         [ev.verdict_row("T150", m, 3), ""] + ev.fmt_cm(m, ev.names_for((12, 20, 30))) + [""]
    summary = []
    detail = []
    for label, load in candidates():
        d = load()
        for ge in GT3 + GT2:
            lines, out = ev.evaluate(d, ge, {"전체": 0.80, "T150": 0.80, "기존": 0.0}, label)
            detail += lines + [""]
            a, t = out["전체"], out["T150"]
            K = len(ge)
            summary.append((label, ge, a, t, K))
    L += ["## 요약 (판정: 전체와 T150 둘 다 통과해야 통과)", "",
          "| 후보 | 안 | 전체 재현(직진/…/최고) | T150 재현(직진/…/최고) | 건너뜀·강→직진 최대(전체/T150) "
          "| 반대 방향 후보 / T103 (전체; T150) | 판정 |", "|---" * 7 + "|"]
    for label, ge, a, t, K in summary:
        rec = lambda m: "/".join(f"{x * 100:.0f}" for x in m["rec"])
        sk = lambda m: max(m["s_to_top"], m["top_to_s"]) if K == 3 else m["top_to_s"]
        ok = a["pass"] and t["pass"]
        okw = a["pass_wo_opp"] and t["pass_wo_opp"]
        v = "**통과**" if ok else ("반대 방향만 미달" if okw else "미달")
        an = f"3단계 {'/'.join(f'{x:g}' for x in ge)}" if K == 3 else f"2단계 B={ge[1]:g}"
        L.append(f"| {label} | {an} | {rec(a)} | {rec(t)} | {sk(a) * 100:.1f}% / {sk(t) * 100:.1f}% "
                 f"| {a['opp']} / {a['opp_ref']}; {t['opp']} / {t['opp_ref']} | {v} |")
    L += ["", "## 상세", ""] + detail
    (OUT / "metrics.md").write_text("\n".join(L) + "\n", encoding="utf-8")
    print("\n".join(L[:12 + len(summary) + 4]))


if __name__ == "__main__":
    main()
