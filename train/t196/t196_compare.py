"""T196: eval_base / eval_t196(1차) / eval_t196b(2차) 나란히 비교 + 판정표 적용.
실행 (워크트리 루트): PYTHONIOENCODING=utf-8 python train/t196/t196_compare.py
판정표 (1차 실행 전에 확정, 2차도 같음):
  AIHub val·test mIoU 하락 > 0.005 -> 퇴행 / 클래스별 IoU 하락 > 0.01 -> 퇴행
  젖은 평가 16장 '차도' 판정 감소 -> 개선, 증가 -> 퇴행
  T193 진짜 차도(road): 기준에서 잡던 장을 하나라도 놓치면 퇴행 (2차 학습 구간 장면은 세 모델 모두 비교에서 뺀다)
  T193 road 아닌 장 '차도' 판정: 감소 -> 개선, 증가 -> 퇴행
  교체 PR = 개선 >= 1 그리고 퇴행 0
"""
import json, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from t196_finetune import ROAD_EVAL_DROP, in_spans  # noqa: E402

NAMES = ["배경", "인도", "차도", "횡단보도", "점자선형", "점자점형", "계단", "맨홀", "가로수"]


def road(x):
    return x["road"] >= 0.5


def judge(b, m):
    bad, good = [], []
    for k in ("val", "test"):
        if b[k]["miou"] - m[k]["miou"] > 0.005:
            bad.append(f"{k} mIoU {m[k]['miou'] - b[k]['miou']:+.4f}")
        for n, x, y in zip(NAMES, b[k]["iou"], m[k]["iou"]):
            if x - y > 0.01:
                bad.append(f"{k} {n} IoU {y - x:+.4f}")
    wb, wm = sum(map(road, b["wet_eval"].values())), sum(map(road, m["wet_eval"].values()))
    (good if wm < wb else bad if wm > wb else []).append(f"젖은 평가 차도 {wb}->{wm}")
    keep = [f for f in b["t193"] if not in_spans(f, ROAD_EVAL_DROP)]
    lost = [f for f in keep if b["t193"][f]["label"] == "road" and road(b["t193"][f]) and not road(m["t193"][f])]
    if lost:
        bad.append(f"진짜 차도 놓침 {len(lost)}: " + ", ".join(Path(f).name for f in lost))
    nb = sum(road(b["t193"][f]) for f in keep if b["t193"][f]["label"] != "road")
    nm = sum(road(m["t193"][f]) for f in keep if m["t193"][f]["label"] != "road")
    (good if nm < nb else bad if nm > nb else []).append(f"road 아닌 장 차도 {nb}->{nm}")
    return good, bad, keep


if __name__ == "__main__":
    E = {k: json.load(open(HERE / f"eval_{k}.json", encoding="utf-8")) for k in ("base", "t196", "t196b")}
    b = E["base"]
    keep = [f for f in b["t193"] if not in_spans(f, ROAD_EVAL_DROP)]
    assert len(b["t193"]) - len(keep) == 8, len(keep)  # 학습 구간에 걸린 T193 road 8장
    print("| 항목 | 기준(T105) | 1차 | 2차 |\n|---|---|---|---|")
    for k in ("val", "test"):
        print(f"| {k} mIoU | " + " | ".join(f"{E[m][k]['miou']:.4f}" for m in E) + " |")
        for i, n in enumerate(NAMES):
            print(f"| {k} {n} IoU | " + " | ".join(f"{E[m][k]['iou'][i]:.4f}" for m in E) + " |")
    print("| 젖은 평가 16장 차도 판정 | " + " | ".join(str(sum(map(road, E[m]["wet_eval"].values()))) for m in E) + " |")
    print("| 젖은 평가 16장 평균 차도/cw | " + " | ".join(
        f"{sum(x['road'] for x in E[m]['wet_eval'].values()) / 16:.3f}/{sum(x['cw'] for x in E[m]['wet_eval'].values()) / 16:.3f}" for m in E) + " |")
    for k in b["mistake"]:
        print(f"| 오안내 {k} 차도/cw | " + " | ".join(f"{E[m]['mistake'][k]['road']:.2f}/{E[m]['mistake'][k]['cw']:.2f}" for m in E) + " |")
    for lb in ("road", "on", "approach", "sidewalk"):
        fs = [f for f in keep if b["t193"][f]["label"] == lb]
        print(f"| T193 {lb} {len(fs)}장 차도 판정 | " + " | ".join(str(sum(road(E[m]["t193"][f]) for f in fs)) for m in E) + " |")
        print(f"| T193 {lb} {len(fs)}장 횡단보도(cw>=0.5) | " + " | ".join(str(sum(E[m]["t193"][f]["cw"] >= 0.5 for f in fs)) for m in E) + " |")
    for m in ("t196", "t196b"):
        good, bad, _ = judge(b, E[m])
        print(f"\n[{m}] 개선 {good}\n[{m}] 퇴행 {bad}\n[{m}] 판정: {'교체 PR' if good and not bad else 'PR 없음'}")
