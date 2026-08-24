"""T55: 출력 헤드 2개(상태 + 방향) 구조의 세션 단위 5-fold 측정.

왜 (2026-08-23~24 측정 이력):
  `approach`를 5-class의 한 칸으로 두는 한 `right` recall이 75% 근처에서 움직이지 않았다.
    843장 4-class                 89.9%
    638장 5-class 손실가중 ON      70.6%
    561장 4-class approach 제외    88.1%
    638장 5-class 손실가중 OFF     75.2%
    637장 5-class 재라벨링         75.0%   <- 재라벨링해도 그대로 (McNemar p=1.0000)
  손실가중·임계값·재라벨링 세 축을 모두 소진했다. 남은 구조적 원인은
  **`approach`와 `right`가 같은 출력 자리를 놓고 경쟁한다**는 것이다.

무엇을 바꾸나:
  하나의 5-class 출력을 두 개로 분리한다.
    상태 head : none / approach / on(횡단보도 위)
    방향 head : left / front / right   (none에서는 정의되지 않음 -> 손실 마스킹)
  `front`/`left`/`right`는 그 자체가 방향이므로 방향 head에 합류한다. 그 결과
  방향 학습량이 approach만 쓸 때의 11/29/19에서 **left 100 / front 169 / right 139**로 늘어난다.
  이것이 사용자가 요구한 "거리가 있어도 방향은 인지"를 데이터를 쪼개지 않고 만족시킨다.
  approach의 방향 정답은 `train/approach_direction.csv`(77행 전부 기입)에서 온다.

비교 가능성:
  결과를 **5-class 결합 확률**로 환산해 기존과 같은 형식으로 저장한다.
    P(none)=Ps[none], P(approach)=Ps[approach],
    P(front)=Ps[on]*Pd[front], P(left)=Ps[on]*Pd[left], P(right)=Ps[on]*Pd[right]
  합이 1이므로 임계값·집계·보고 코드를 그대로 재사용할 수 있고, 이전 측정과 직접 비교된다.

동일하게 유지하는 것 (차이를 헤드 구조 하나로 좁히기 위해):
  세션 분할·근사중복·fold 배정·transform·에폭/LR/스케줄러·시드·샘플러,
  그리고 USE_LOSS_WEIGHT=False (T53에서 확인한 공짜 이득).
"""
import csv
import json
import random
from pathlib import Path

import torch
import torch.nn as nn
import torch.optim as optim
from PIL import Image
from torch.utils.data import DataLoader, Dataset, WeightedRandomSampler
from torchvision.models import MobileNet_V3_Small_Weights, mobilenet_v3_small

import build_cache
import groupkfold_cv as G

G.USE_LOSS_WEIGHT = False
OUT_DIR = Path(__file__).resolve().parent / "groupkfold_twohead_out"
DIR_CSV = Path(__file__).resolve().parent / "approach_direction.csv"

STATES = ["none", "approach", "on"]
DIRS = ["left", "front", "right"]
IGNORE = -100  # nn.CrossEntropyLoss 기본 ignore_index

# 5-class 라벨 -> (상태, 방향). approach의 방향은 CSV에서 채운다.
STATE_OF = {"none": "none", "approach": "approach", "front": "on", "left": "on", "right": "on"}
DIR_OF = {"front": "front", "left": "left", "right": "right"}


def load_direction_map():
    """파일명 -> 방향. approach는 CSV, on(front/left/right)은 폴더명에서 파생."""
    m = {}
    with open(DIR_CSV, encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            d = row["direction"].strip()
            if d:
                m[row["file"]] = d
    return m


class TwoHeadDataset(Dataset):
    def __init__(self, items, tf):
        self.items = items  # (path, state_idx, dir_idx)
        self.tf = tf

    def __len__(self):
        return len(self.items)

    def __getitem__(self, i):
        path, si, di = self.items[i]
        if G.USE_CACHE:
            path = build_cache.cache_path(Path(path))
        return self.tf(Image.open(path).convert("RGB")), si, di


class TwoHead(nn.Module):
    def __init__(self):
        super().__init__()
        m = mobilenet_v3_small(weights=MobileNet_V3_Small_Weights.DEFAULT)
        in_f = m.classifier[3].in_features
        m.classifier[3] = nn.Identity()
        self.backbone = m
        self.state_head = nn.Linear(in_f, len(STATES))
        self.dir_head = nn.Linear(in_f, len(DIRS))

    def forward(self, x):
        f = self.backbone(x)
        return self.state_head(f), self.dir_head(f)


def to5(ps, pd):
    """상태·방향 확률을 기존 5-class 확률로 환산한다 (합 = 1)."""
    on = ps[STATES.index("on")]
    return {
        "none": float(ps[STATES.index("none")]),
        "approach": float(ps[STATES.index("approach")]),
        "front": float(on * pd[DIRS.index("front")]),
        "left": float(on * pd[DIRS.index("left")]),
        "right": float(on * pd[DIRS.index("right")]),
    }


def label_items(items, dirmap):
    """G.load_images()의 레코드에 상태·방향 인덱스를 붙인다."""
    missing = []
    for r in items:
        cls = r["cls"]
        r["si"] = STATES.index(STATE_OF[cls])
        if cls == "none":
            r["di"] = IGNORE
        elif cls == "approach":
            d = dirmap.get(r["file"])
            if d is None:
                missing.append(r["file"])
                r["di"] = IGNORE
            else:
                r["di"] = DIRS.index(d)
        else:
            r["di"] = DIRS.index(DIR_OF[cls])
    if missing:
        raise RuntimeError(
            f"approach {len(missing)}장의 방향이 CSV에 없다 - 중단. 예: {missing[:5]}\n"
            f"  {DIR_CSV}에 해당 행을 추가할 것."
        )
    return items


def run_fold(k, items, device):
    test_items = [r for r in items if r["fold"] == k]
    rest_sess = sorted({r["session"] for r in items if r["fold"] != k})
    rnd = random.Random(G.SEED + 100 + k)
    rnd.shuffle(rest_sess)
    val_sess = set(rest_sess[: max(1, len(rest_sess) // 8)])
    train_items = [r for r in items if r["fold"] != k and r["session"] not in val_sess]
    val_items = [r for r in items if r["fold"] != k and r["session"] in val_sess]

    tc = G.Counter_cls(train_items)
    print(f"[fold {k}] train={len(train_items)} val={len(val_items)} test={len(test_items)}", flush=True)
    print(f"[fold {k}] 5-class 분포: {dict(tc)}", flush=True)
    st_cnt = {s: sum(1 for r in train_items if r["si"] == i) for i, s in enumerate(STATES)}
    ds_cnt = {d: sum(1 for r in train_items if r["di"] == i) for i, d in enumerate(DIRS)}
    print(f"[fold {k}] 상태: {st_cnt} | 방향: {ds_cnt}", flush=True)

    def mk(rs, tf):
        return TwoHeadDataset([(r["path"], r["si"], r["di"]) for r in rs], tf)

    train_ds, val_ds, test_ds = mk(train_items, G.TRAIN_TF), mk(val_items, G.EVAL_TF), mk(test_items, G.EVAL_TF)

    # 샘플러는 이전 실험과 동일하게 **5-class 빈도** 기준을 쓴다. 기준을 바꾸면
    # 헤드 구조 외의 변수가 하나 더 생겨 비교가 흐려진다.
    sw = [1.0 / tc[r["cls"]] for r in train_items]
    sampler = WeightedRandomSampler(sw, num_samples=len(sw), replacement=True)
    train_loader = DataLoader(train_ds, batch_size=G.BATCH_SIZE, sampler=sampler, num_workers=0)
    val_loader = DataLoader(val_ds, batch_size=G.BATCH_SIZE, shuffle=False, num_workers=0)
    test_loader = DataLoader(test_ds, batch_size=G.BATCH_SIZE, shuffle=False, num_workers=0)

    crit_s = nn.CrossEntropyLoss()
    crit_d = nn.CrossEntropyLoss(ignore_index=IGNORE)  # none은 방향 손실에서 제외
    model = TwoHead().to(device)

    def train_epoch(opt):
        model.train()
        tot, n = 0.0, 0
        for imgs, si, di in train_loader:
            imgs, si, di = imgs.to(device), si.to(device), di.to(device)
            opt.zero_grad()
            os_, od = model(imgs)
            loss = crit_s(os_, si)
            if (di != IGNORE).any():  # 배치 전체가 none이면 방향 손실은 정의되지 않는다
                loss = loss + crit_d(od, di)
            loss.backward()
            opt.step()
            tot += loss.item() * imgs.size(0)
            n += imgs.size(0)
        return tot / n

    def eval_joint_acc(loader, rs):
        """모델 선택 기준 = 배포 시 실제로 쓰는 5-class 결합 판정의 정확도."""
        model.eval()
        corr, i = 0, 0
        with torch.no_grad():
            for imgs, _, _ in loader:
                ls, ld = model(imgs.to(device))
                ps = torch.softmax(ls, 1).cpu().numpy()
                pdv = torch.softmax(ld, 1).cpu().numpy()
                for a, b in zip(ps, pdv):
                    p = to5(a, b)
                    corr += int(max(p, key=p.get) == rs[i]["cls"])
                    i += 1
        return corr / max(i, 1)

    for p in model.backbone.features.parameters():
        p.requires_grad = False
    opt = optim.Adam(filter(lambda p: p.requires_grad, model.parameters()), lr=G.LR_FROZEN)
    for e in range(G.EPOCHS_FROZEN):
        tl = train_epoch(opt)
        va = eval_joint_acc(val_loader, val_items)
        print(f"[fold {k}] frozen {e+1:02d}/{G.EPOCHS_FROZEN} loss={tl:.4f} val={va:.4f}", flush=True)

    for p in model.parameters():
        p.requires_grad = True
    opt = optim.Adam(model.parameters(), lr=G.LR_FINETUNE)
    sched = optim.lr_scheduler.CosineAnnealingLR(opt, T_max=G.EPOCHS_FINETUNE)
    best, best_state = -1.0, None
    for e in range(G.EPOCHS_FINETUNE):
        tl = train_epoch(opt)
        va = eval_joint_acc(val_loader, val_items)
        sched.step()
        print(f"[fold {k}] ft     {e+1:02d}/{G.EPOCHS_FINETUNE} loss={tl:.4f} val={va:.4f}", flush=True)
        if va > best:
            best, best_state = va, {kk: v.detach().cpu().clone() for kk, v in model.state_dict().items()}
    if best_state:
        model.load_state_dict(best_state)
    print(f"[fold {k}] best val_acc={best:.4f}", flush=True)

    model.eval()
    recs, i = [], 0
    with torch.no_grad():
        for imgs, _, _ in test_loader:
            ls, ld = model(imgs.to(device))
            ps = torch.softmax(ls, 1).cpu().numpy()
            pdv = torch.softmax(ld, 1).cpu().numpy()
            for a, b in zip(ps, pdv):
                r = test_items[i]
                recs.append({
                    "file": r["file"], "true": r["cls"], "fold": k,
                    "session": r["session"], "dupc": r["dupc"],
                    "probs": to5(a, b),
                    "state_probs": {STATES[j]: float(a[j]) for j in range(len(STATES))},
                    "dir_probs": {DIRS[j]: float(b[j]) for j in range(len(DIRS))},
                    "true_dir": (None if r["di"] == IGNORE else DIRS[r["di"]]),
                })
                i += 1
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    json.dump(recs, open(OUT_DIR / f"fold{k}_probs.json", "w"), ensure_ascii=False)
    print(f"[fold {k}] 완료 - held-out {len(recs)}장", flush=True)
    return recs


def report_direction(recs):
    """새로 얻은 능력 자체를 따로 본다: 방향 head가 approach에서도 맞히는가."""
    print("\n" + "=" * 76)
    print("[방향 head 단독 정확도] - 상태와 무관하게 방향만 본다 (argmax, 임계값 없음)")
    print("=" * 76)
    groups = (
        ("approach (거리 있음)", lambda r: r["true"] == "approach"),
        ("on (횡단보도 위)", lambda r: r["true"] in ("front", "left", "right")),
        ("전체", lambda r: r["true_dir"] is not None),
    )
    for name, sel in groups:
        sub = [r for r in recs if sel(r) and r["true_dir"]]
        if not sub:
            continue
        hit = sum(1 for r in sub if max(r["dir_probs"], key=r["dir_probs"].get) == r["true_dir"])
        lo, hi = G.wilson(hit, len(sub))
        print(f"  {name:20s} {hit:3d}/{len(sub):3d} = {hit/len(sub)*100:5.1f}%  95% CI [{lo*100:.1f}%, {hi*100:.1f}%]")
    print("\n  방향별:")
    for d in DIRS:
        sub = [r for r in recs if r["true_dir"] == d]
        hit = sum(1 for r in sub if max(r["dir_probs"], key=r["dir_probs"].get) == d)
        lo, hi = G.wilson(hit, len(sub))
        print(f"    {d:6s} {hit:3d}/{len(sub):3d} = {hit/len(sub)*100:5.1f}%  CI [{lo*100:.1f}%, {hi*100:.1f}%]")


def main():
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"[T55 헤드 2개] Device: {device} | {G.N_FOLDS}-fold | 손실가중 OFF", flush=True)
    if G.USE_CACHE:
        made, kept = build_cache.build(verbose=False)
        print(f"224 캐시: 신규 {made} / 유지 {kept}", flush=True)
    items = label_items(G.load_images(), load_direction_map())
    n_sess = G.assign_sessions(items)
    n_dupc = G.dup_clusters(items)
    print(f"이미지 {len(items)}장 / 세션 {n_sess}개 / 근사중복 클러스터 {n_dupc}개", flush=True)
    G.split_folds(items, n_sess)

    all_recs = []
    for k in range(G.N_FOLDS):
        all_recs += run_fold(k, items, device)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    json.dump(all_recs, open(OUT_DIR / "all_probs.json", "w"), ensure_ascii=False)
    G.report(all_recs, "[주 지표] 세션단위 분할 + 근사중복 1장 집계", key="dupc")
    G.report(all_recs, "[참고] 세션단위 분할, 중복 미제거 전체 집계")
    report_direction(all_recs)


if __name__ == "__main__":
    main()
