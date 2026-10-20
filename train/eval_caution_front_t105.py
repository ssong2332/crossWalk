"""T105: 주의 구역 발 앞 판정의 면적 기준별 재현율·정밀도 (경고 판정표 초안 근거).

T105 모델(`model/crosswalk_surface_t105.pt`)로 test(폴더 홀드아웃 4,718장)를 추론하고,
발 앞 영역(가운데 1/3 × 아래 1/2)에서 클래스 면적 비율을 사진마다 구한다.
  | 지표           | 정의                                                        |
  | 같은 기준      | 정답 >= t 를 양성, 예측 >= t 를 경보로 본 재현율·정밀도       |
  | 5% 정답 대비   | 정답 >= 5%(학습 평가 기준)를 양성, 예측 >= t 를 경보로 본 값   |
  | 경보율         | 예측 >= t 인 사진 / 전체 사진 (프레임마다 울릴 비율의 상한, 추정) |
t = 5%, 10%, 15%, 25%. 클래스 6 계단 / 7 맨홀·그레이팅 / 8 가로수 구역.
출력: train/caution_front_t105.json, 표준출력.
실행: python -u train/eval_caution_front_t105.py
"""
import csv
import json
import os

import numpy as np
import torch
from torch.utils.data import DataLoader

import train_seg_t105 as t

OUT = os.path.join(t.REPO, "train", "caution_front_t105.json")
CLS = {6: "계단", 7: "맨홀·그레이팅", 8: "가로수 구역"}
TH = [0.05, 0.10, 0.15, 0.25]


def main():
    torch.set_num_threads(4)
    with open(os.path.join(t.CACHE, "index.csv"), encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    keys = t.split_folders(rows)["test"]
    model = t.LRASPPSmall(t.N_CLS, pretrained=False)
    model.load_state_dict(torch.load(t.PT_OUT))
    model.eval()
    fy, fx = t.FRONT
    gt, pr = {c: [] for c in CLS}, {c: [] for c in CLS}
    with torch.no_grad():
        for x, y in DataLoader(t.SegSet(keys, False), batch_size=32):
            p = model(x).argmax(1)
            for c in CLS:
                gt[c] += (y[:, fy, fx] == c).float().mean((1, 2)).tolist()
                pr[c] += (p[:, fy, fx] == c).float().mean((1, 2)).tolist()
    n = len(keys)
    res = {"n_images": n}
    print(f"test {n}장")
    for c, name in CLS.items():
        g, q = np.array(gt[c]), np.array(pr[c])
        res[name] = []
        print(f"\n{name}")
        print(f"  {'기준':>4s} | {'같은 기준 재현':>10s} {'정밀도':>10s} | {'5%정답 재현':>10s} {'정밀도':>10s} | 경보율")
        for th in TH:
            a_g, a_q, g5 = g >= th, q >= th, g >= 0.05
            r1 = (a_g & a_q).sum() / max(a_g.sum(), 1)
            p1 = (a_g & a_q).sum() / max(a_q.sum(), 1)
            r2 = (g5 & a_q).sum() / max(g5.sum(), 1)
            p2 = (g5 & a_q).sum() / max(a_q.sum(), 1)
            print(f"  {th * 100:3.0f}% | {r1 * 100:5.1f}% ({(a_g & a_q).sum()}/{a_g.sum()}) "
                  f"{p1 * 100:5.1f}% ({a_q.sum()}) | {r2 * 100:5.1f}% ({g5.sum()}) {p2 * 100:5.1f}% | "
                  f"{a_q.mean() * 100:.1f}%")
            res[name].append(dict(th=th, gt_pos=int(a_g.sum()), pred_pos=int(a_q.sum()),
                                  tp_same=int((a_g & a_q).sum()), recall_same=float(r1),
                                  precision_same=float(p1), gt5_pos=int(g5.sum()),
                                  recall_vs_gt5=float(r2), precision_vs_gt5=float(p2),
                                  alarm_rate=float(a_q.mean())))
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(res, f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
