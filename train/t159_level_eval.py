"""T159: 이탈 단계 판정 — 오케스트레이터 채택 판정표대로 예측을 평가한다.

입력은 T151 형식 예측 CSV(src,class,filename,fold,group,geo_deg,...,pred_tta,pred_plain).
정답은 항상 기하각(geo_deg). 예측은 부호 있는 각도 점수 하나(|점수|에 문턱을 건다).

판정 정의 (보고서 §판정 정의 표와 같음):
  - 직진 = 정답 |각| < 12.
  - 3단계: 정답 단계 = 정답 경계 GT3(기본 12/20/30)로 0(직진)/1/2/3(최고).
           예측 단계 = 예측 문턱 (p1, p2, p3)로 같은 방식.
           통과 = 단계 1·2·3 재현 각각 ≥70%, 건너뜀(직진→3, 3→직진 각각 그 정답 행 대비) ≤3%,
                  반대 방향 ≤ T103, 직진 재현 ≥ 기준값.
  - 2단계: 정답 = 직진(<12) / 약(12~B) / 강(≥B), B는 20~30.
           통과 = 강 재현 ≥80%, 약 재현 ≥70%, 강→직진(강 행 대비) ≤3%, 반대 방향 ≤ T103, 직진 재현 ≥ 기준값.
  - 반대 방향 = 정답 |각| ≥12 이고 예측 단계 ≥1 인데 부호가 다른 장수.
    기준(사용자 결정 (나), 10/29): 같은 세트의 배포 T103(단일 추론, 앱 문턱 12) 장수 이하.
    T150 3장, 전체 1,331장 4장(`train/t159/deployed_pred_all.csv`, 기존 1,027장은 T103이 학습한 사진).
예측 문턱은 '묶인 fold 조정'(fold k는 나머지 fold로 고른 문턱을 씀)으로 고른다. 같은 데이터로
고른 문턱(낙관값)은 참고로만 쓴다.
"""

import csv
import itertools
from pathlib import Path

import numpy as np

STRAIGHT = 12.0
N_FOLDS = 5
TUNE_STRAIGHT_REF = 0.80  # 문턱 고를 때 직진 재현 하한(T103 T150 80%)
OPP_REF = {"전체": 4, "T150": 3, "기존": 1}  # 배포 T103 반대 방향 장수


def read_preds(path, key="plain"):
    """key: 'plain' | 'tta' | 열 이름. 반환: dict(arrays)."""
    with open(path, encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    col = {"plain": "pred_plain", "tta": "pred_tta"}.get(key, key)
    return {
        "src": np.array([r["src"] for r in rows]),
        "key": [(r["class"], r["filename"]) for r in rows],
        "fold": np.array([int(r["fold"]) for r in rows]),
        "group": np.array([r["group"] for r in rows]),
        "gt": np.array([float(r["geo_deg"]) for r in rows]),
        "pr": np.array([float(r[col]) for r in rows]),
    }


def sub(d, mask):
    return {k: (v[mask] if isinstance(v, np.ndarray) else [x for x, m in zip(v, mask) if m])
            for k, v in d.items()}


def levels(a, edges):
    a = np.abs(a)
    return sum((a >= e).astype(int) for e in edges)


def judge(gt, pr, gt_edges, pr_edges, straight_ref, opp_ref=0):
    """gt_edges/pr_edges 길이 3 = 3단계, 길이 2 = 2단계. 반환 dict(지표, 통과 여부, 여유)."""
    K = len(gt_edges)
    lg = levels(gt, gt_edges)
    lp = levels(pr, pr_edges)
    cm = np.bincount(lg * (K + 1) + lp, minlength=(K + 1) ** 2).reshape(K + 1, K + 1)
    rec = [cm[i, i] / cm[i].sum() if cm[i].sum() else float("nan") for i in range(K + 1)]
    top = K
    n0, nt = cm[0].sum(), cm[top].sum()
    s_to_top = cm[0, top] / n0 if n0 else 0.0
    top_to_s = cm[top, 0] / nt if nt else 0.0
    dev = (np.abs(gt) >= STRAIGHT) & (lp >= 1)
    opp = int((dev & (np.sign(gt) != np.sign(pr))).sum())
    m = {"cm": cm, "rec": rec, "s_to_top": s_to_top, "top_to_s": top_to_s, "opp": opp,
         "n": len(gt), "mae": float(np.abs(gt - pr).mean())}
    if K == 3:
        slack = [rec[1] - .70, rec[2] - .70, rec[3] - .70, .03 - s_to_top, .03 - top_to_s,
                 rec[0] - straight_ref]
    else:
        slack = [rec[2] - .80, rec[1] - .70, .03 - top_to_s, rec[0] - straight_ref]
    m["slack"] = slack
    m["pass_wo_opp"] = all(s >= 0 for s in slack)
    m["opp_ref"] = opp_ref
    m["pass"] = m["pass_wo_opp"] and opp <= opp_ref
    return m


def grid(K):
    t1s = np.arange(6.0, 20.01, 0.5)
    if K == 2:
        for t1 in t1s:
            for t2 in np.arange(t1 + 1, 40.01, 0.5):
                yield (t1, t2)
    else:
        for t1 in t1s:
            for t2 in np.arange(t1 + 1, 35.01, 0.5):
                for t3 in np.arange(t2 + 1, 45.01, 1.0):
                    yield (t1, t2, t3)


def tune(gt, pr, gt_edges, straight_ref, groups=None):
    """여유(slack)의 최솟값이 가장 큰 예측 문턱. 동점이면 평균 여유가 큰 쪽.
    groups(불리언 마스크 목록)를 주면 각 묶음(전체·T150)의 여유 중 최솟값으로 고른다."""
    groups = groups or [np.ones(len(gt), bool)]
    best, bestv = None, (-9, -9)
    for th in grid(len(gt_edges)):
        s = sum((judge(gt[g], pr[g], gt_edges, th, straight_ref)["slack"] for g in groups), [])
        v = (min(s), float(np.mean(s)))
        if v > bestv:
            best, bestv = th, v
    return best


def nested(d, gt_edges, straight_ref):
    """fold k의 문턱은 fold≠k로 고른다. 반환: (fold별 문턱, 각 행의 '예측 단계 판정용 점수')."""
    lp_score = np.zeros_like(d["pr"])
    ths = {}
    # 문턱이 fold마다 다르므로 점수를 '표준 문턱'으로 옮겨 놓는다: 단계 j ↔ 정답 경계 j 사이 값.
    for k in range(N_FOLDS):
        tr = d["fold"] != k
        g = [np.ones(tr.sum(), bool), d["src"][tr] == "t150"]
        th = tune(d["gt"][tr], d["pr"][tr], gt_edges, straight_ref, g)
        ths[k] = th
        te = d["fold"] == k
        lv = levels(d["pr"][te], th)
        # 단계 lv를 gt_edges 기준의 대표값으로 바꾼다(부호 유지).
        rep = np.array([0.0] + [e + 0.01 for e in gt_edges])
        lp_score[te] = np.sign(d["pr"][te]) * rep[lv]
    return ths, lp_score


def fmt_cm(m, names):
    L = ["| 정답＼예측 | " + " | ".join(names) + " | 재현 |", "|---" * (len(names) + 2) + "|"]
    for i, nm in enumerate(names):
        L.append(f"| {nm} | " + " | ".join(str(v) for v in m["cm"][i])
                 + f" | {m['rec'][i] * 100:.0f}% |")
    return L


def names_for(gt_edges):
    e = [f"{x:g}" for x in gt_edges]
    if len(gt_edges) == 3:
        return ["직진<12", f"{e[0]}~{e[1]}", f"{e[1]}~{e[2]}", f"≥{e[2]}"]
    return ["직진<12", f"약 {e[0]}~{e[1]}", f"강 ≥{e[1]}"]


def verdict_row(label, m, K):
    r = m["rec"]
    if K == 3:
        cells = [f"{r[0] * 100:.0f}%", f"{r[1] * 100:.0f}%", f"{r[2] * 100:.0f}%",
                 f"{r[3] * 100:.0f}%", f"{m['s_to_top'] * 100:.1f}% / {m['top_to_s'] * 100:.1f}%"]
    else:
        cells = [f"{r[0] * 100:.0f}%", f"{r[1] * 100:.0f}%", f"{r[2] * 100:.0f}%",
                 f"{m['top_to_s'] * 100:.1f}%"]
    ok = "**통과**" if m["pass"] else ("반대 방향만 미달" if m["pass_wo_opp"] else "미달")
    return f"| {label} | {m['n']} | " + " | ".join(cells) + f" | {m['opp']} / {m['opp_ref']} | {ok} |"


def header(K):
    if K == 3:
        return ["| 대상 | n | 직진 재현 | 1단계 재현 | 2단계 재현 | 3단계 재현 | 건너뜀 직진→3 / 3→직진 "
                "| 반대 방향 후보 / T103 | 판정 |", "|---" * 9 + "|"]
    return ["| 대상 | n | 직진 재현 | 약 재현 | 강 재현 | 강→직진 | 반대 방향 후보 / T103 | 판정 |",
            "|---" * 8 + "|"]


def evaluate(d, gt_edges, straight_ref, label):
    """묶인 fold 문턱으로 전체·T150·기존 판정. 반환: (markdown 줄, 결과 dict)."""
    K = len(gt_edges)
    ths, score = nested(d, gt_edges, TUNE_STRAIGHT_REF)
    out = {"ths": ths}
    L = [f"#### {label} — 정답 경계 {'/'.join(f'{x:g}' for x in gt_edges)}", "",
         "fold별 예측 문턱(나머지 fold로 고름): "
         + ", ".join(f"{k}: {'/'.join(f'{x:g}' for x in t)}" for k, t in ths.items()), ""]
    L += header(K)
    # score는 단계 대표값이므로 judge의 예측 문턱을 정답 경계로 두면 그대로 단계가 된다.
    for nm, mask in [("전체", np.ones(len(d["gt"]), bool)), ("T150", d["src"] == "t150"),
                     ("기존", d["src"] == "existing")]:
        if not mask.any():
            continue
        ref = straight_ref.get(nm, 0.80) if isinstance(straight_ref, dict) else straight_ref
        m = judge(d["gt"][mask], score[mask], gt_edges, gt_edges, ref, OPP_REF[nm])
        out[nm] = m
        L.append(verdict_row(nm, m, K))
    L += ["", "혼동표 (전체, 행=정답, 열=예측)", ""] + fmt_cm(out["전체"], names_for(gt_edges))
    if "T150" in out:
        L += ["", "혼동표 (T150)", ""] + fmt_cm(out["T150"], names_for(gt_edges))
    return L, out


if __name__ == "__main__":
    import sys
    p = Path(sys.argv[1])
    for key in ("plain", "tta"):
        d = read_preds(p, key)
        for ge in [(12, 20, 30), (12, 25)]:
            L, _ = evaluate(d, ge, 0.80, f"{p.name} {key}")
            print("\n".join(L), "\n")
