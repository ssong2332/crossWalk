"""T196: 노면 모델(T105) 미세조정 — 11/18 젖은 야간 횡단보도 (라벨: train/t196/final_labels.csv).

방법 (사용자 승인 1안): 젖은 사진은 발 앞 영역(224 기준 행 112:224, 열 74:149 = 앱 SurfaceGuide 앞 칸)만
  클래스 3(횡단보도), 나머지 픽셀은 손실에서 무시(255). T105 가중치에서 시작, AIHub train과 섞어 학습.
젖은 사진 분할 (같은 장소 연속 촬영 -> 시간순, 사이 2장 버림):
  학습 = idx 1~17, 버림 = 18~19, 평가 = 21~36 (20 = 제외 라벨). ★ 3·11은 학습 쪽, 25·30은 평가 쪽.
평가 (모드 eval <pt>): AIHub val·test 클래스별 IoU / 젖은 평가 16장 / '차도' 오안내 프레임 /
  T193 정답 106장(11/18 제외)의 발 앞 '차도' 판정(차도 비율 >= 0.5, SurfaceGuide.manyRatio).
  야외 프레임 입력은 앱과 같이 시계방향 90° 회전 후 전체를 224로 NEAREST (t193/eval_app.py와 같음).

실행 (워크트리 루트, 데이터는 T196_DATA_ROOT=C:/vibecoding/crossWalk):
  PYTHONIOENCODING=utf-8 python train/t196/t196_finetune.py eval  model/crosswalk_surface_t105.pt  base
  PYTHONIOENCODING=utf-8 python train/t196/t196_finetune.py train                                 (-> model/crosswalk_surface_t196.pt)
  PYTHONIOENCODING=utf-8 python train/t196/t196_finetune.py eval  model/crosswalk_surface_t196.pt  t196
  PYTHONIOENCODING=utf-8 python train/t196/t196_finetune.py export model/crosswalk_surface_t196.pt
  2차 (젖은 가중치 0.3 + 11/11 진짜 차도 19장, 가중치 0.3):
  T196_TAG=t196b T196_WET_W=0.3 T196_ROAD_W=0.3 python train/t196/t196_finetune.py train
  python train/t196/t196_finetune.py eval model/crosswalk_surface_t196b.pt t196b
  (T193 '진짜 차도' 비교는 ROAD_EVAL_DROP 구간을 뺀 장만 쓴다 — 학습 장면과 같은 구간)
출력: train/t196/eval_<이름>.json
환경변수: T196_STEPS(기본 200), T196_VAL_MAX(0 = 전체)
"""
import csv, json, os, random, sys, time
from pathlib import Path
import numpy as np
import torch
import torch.nn as nn
from PIL import Image, ImageEnhance
from torch.utils.data import DataLoader

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import train_seg_t105 as T  # noqa: E402

DATA = Path(os.environ.get("T196_DATA_ROOT", "C:/vibecoding/crossWalk"))
T.CACHE = str(DATA / "train" / "seg_cache_t105")  # workers=0이라 모듈 전역을 바꿔도 된다
T.IMG_DIR = str(DATA / "train" / "seg_cache_t104" / "img")
FRAMES = DATA / "train" / "frames_1118"
S = T.SIZE
ZONE = (slice(S // 2, S), slice(S // 3, 2 * S // 3))  # 앱 앞 칸: 아래 절반, 가운데 1/3 (74..148)
STEPS = int(os.environ.get("T196_STEPS", "200"))
# 2차 (T196_TAG=t196b): 젖은 손실 가중치 낮춤 + 11/11 밤 진짜 차도(골목 아스팔트) 발 앞 칸 = 클래스 2
TAG = os.environ.get("T196_TAG", "t196")
WET_W = float(os.environ.get("T196_WET_W", "1.0"))
ROAD_W = float(os.environ.get("T196_ROAD_W", "0"))
ROAD_DIR = DATA / "train" / "frame_1111"
# field_1111 7-5 '차도입니다' 두 구간 18:21:24.7~31.1, 18:22:36.2~49.1 (1초 간격 전부, 직접 확인: 발 앞 칸 아스팔트).
# 구간 끝 f_1794388968342(18:22:49.1)는 과속방지턱 줄무늬가 칸에 걸려 학습에서 뺐다 -> 학습 19장.
ROAD_SPANS = [(1794388884000, 1794388891500), (1794388955000, 1794388967500)]
# T193 평가에서 뺄 구간 (학습 구간과 같은 장면이라 누수): 학습 구간 + 끝 장
ROAD_EVAL_DROP = [(1794388884000, 1794388891500), (1794388955000, 1794388969000)]


def in_spans(name, spans):
    t = int(Path(name).stem[2:])
    return any(a <= t <= b for a, b in spans)
VAL_MAX = int(os.environ.get("T196_VAL_MAX", "0"))
WET_TRAIN, WET_EVAL = range(1, 18), range(21, 37)
# '차도' 오안내 순간 가장 가까운 프레임 (report 2-1 / 8-1): ★ 4장 + 18:40:29.6(+0.4s) + 18:44:18.8(-0.2s)
MISTAKE = {"18:39:48.8 ★(학습쪽)": "f_1794994788769.jpg", "18:39:57.0 ★(학습쪽)": "f_1794994796983.jpg",
           "18:40:11.5 ★": "f_1794994811461.jpg", "18:40:16.7 ★": "f_1794994816671.jpg",
           "18:40:29.6 인도(#6)": "f_1794994830018.jpg", "18:44:18.8 인도 타일(#7)": "f_1794995058582.jpg"}


def wet_rows():
    rows = list(csv.DictReader(open(HERE / "final_labels.csv", encoding="utf-8-sig")))
    assert len(rows) == 36 and [r["final_label"] for r in rows].count("crosswalk") == 35
    return {int(r["idx"]): r for r in rows}


def upright(path):
    return Image.open(path).convert("RGB").transpose(Image.Transpose.ROTATE_270)


def norm(im):
    a = (np.asarray(im, np.float32) / 255.0 - T.MEAN) / T.STD
    return torch.from_numpy(a.transpose(2, 0, 1).copy())


def wet_mask(c=3):
    m = torch.full((S, S), 255, dtype=torch.int64)
    m[ZONE] = c
    return m


def wet_batch(files, n, c=3):
    """files: 경로 목록. 발 앞 칸만 클래스 c, 나머지 무시."""
    xs = []
    for f in random.choices(files, k=n):
        im = upright(f).resize((S, S), Image.BILINEAR)
        if random.random() < 0.5:
            im = im.transpose(Image.FLIP_LEFT_RIGHT)  # 앞 칸이 좌우 대칭이라 마스크는 그대로
        im = ImageEnhance.Brightness(im).enhance(random.uniform(0.7, 1.3))
        im = ImageEnhance.Contrast(im).enhance(random.uniform(0.7, 1.3))
        xs.append(norm(im))
    return torch.stack(xs), wet_mask(c).expand(n, S, S).clone()


def front(model, path):
    """앱과 같은 입력으로 발 앞 칸의 클래스 비율 (차도, 횡단보도, 인도)."""
    x = norm(upright(path).resize((S, S), Image.NEAREST))[None]
    with torch.no_grad():
        z = model(x).argmax(1)[0][ZONE]
    return {k: round(float((z == c).float().mean()), 3) for k, c in (("road", 2), ("cw", 3), ("side", 1))}


def load(pt):
    m = T.LRASPPSmall(T.N_CLS, pretrained=False)
    m.load_state_dict(torch.load(DATA / pt))
    return m.eval()


def aihub_split():
    rows = list(csv.DictReader(open(Path(T.CACHE) / "index.csv", encoding="utf-8")))
    return rows, T.split_folders(rows)


def do_eval(pt, name):
    torch.set_num_threads(4)
    model = load(pt)
    _, sp = aihub_split()
    res = {"model": pt}
    for k in ("val", "test"):
        keys = sp[k] if not VAL_MAX else random.Random(196).sample(sp[k], VAL_MAX)
        t0 = time.time()
        iou, _, fr = T.evaluate(model, DataLoader(T.SegSet(keys, False), batch_size=32, num_workers=0))
        res[k] = {"n": len(keys), "miou": round(float(iou.mean()), 4), "iou": [round(float(v), 4) for v in iou],
                  "front": {T.NAMES[c]: v for c, v in fr.items()}, "sec": round(time.time() - t0)}
        print(k, res[k]["n"], "mIoU", res[k]["miou"], res[k]["iou"], res[k]["sec"], "s", flush=True)
    model.eval()
    wr = wet_rows()
    res["wet_eval"] = {wr[i]["file"]: front(model, FRAMES / wr[i]["file"]) for i in WET_EVAL if wr[i]["final_label"] == "crosswalk"}
    res["wet_train"] = {wr[i]["file"]: front(model, FRAMES / wr[i]["file"]) for i in WET_TRAIN}
    res["mistake"] = {k: front(model, FRAMES / f) for k, f in MISTAKE.items()}
    t193 = list(csv.DictReader(open(HERE / "t193_truth_no1118.csv", encoding="utf-8-sig")))
    res["t193"] = {r["file"]: dict(label=r["label"], cond=r["cond"], **front(model, DATA / r["file"])) for r in t193}
    for k in ("wet_eval", "wet_train"):
        v = res[k]
        print(k, len(v), "차도 판정", sum(x["road"] >= 0.5 for x in v.values()),
              "평균 차도", round(np.mean([x["road"] for x in v.values()]), 3), "평균 cw", round(np.mean([x["cw"] for x in v.values()]), 3))
    print("오안내", res["mistake"])
    for lb in ("road", "on", "approach", "sidewalk"):
        v = [x for x in res["t193"].values() if x["label"] == lb]
        print("t193", lb, len(v), "차도 판정", sum(x["road"] >= 0.5 for x in v))
    json.dump(res, open(HERE / f"eval_{name}.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)


def do_train():
    random.seed(196); torch.manual_seed(196); torch.set_num_threads(4)
    rows, sp = aihub_split()
    cw, _ = T.class_weights(rows, sp["train"])
    model = load("model/crosswalk_surface_t105.pt").train()  # 2차도 T105에서 시작 (1차 모델 이어 학습 아님)
    wr = wet_rows()
    wet_files = [FRAMES / wr[i]["file"] for i in WET_TRAIN]
    assert len(wet_files) == 17 and all(wr[i]["final_label"] == "crosswalk" for i in WET_TRAIN)
    road_files = sorted(p for p in ROAD_DIR.glob("f_*.jpg") if in_spans(p.name, ROAD_SPANS)) if ROAD_W else []
    assert not ROAD_W or len(road_files) == 19, len(road_files)
    print(f"{TAG}: wet_w {WET_W} road_w {ROAD_W} road {len(road_files)}장", flush=True)
    tr = DataLoader(T.SegSet(sp["train"], True), batch_size=12, shuffle=True, drop_last=True, num_workers=0)
    opt = torch.optim.AdamW(model.parameters(), lr=1e-4, weight_decay=1e-4)
    lossf = nn.CrossEntropyLoss(weight=cw, ignore_index=255)
    t0, n, la, lw, lr_ = time.time(), 0, 0.0, 0.0, 0.0
    for x, y in tr:
        xw, yw = wet_batch(wet_files, 4, 3)
        xs, ys = [x, xw], [y, yw]
        if ROAD_W:
            xr, yr = wet_batch(road_files, 4, 2)
            xs.append(xr); ys.append(yr)
        out = model(torch.cat(xs))
        # 젖은·차도 쪽은 각자 유효 픽셀 평균 (앞 칸만이라 섞으면 묻힌다)
        a, w = lossf(out[:12], y), lossf(out[12:16], ys[1])
        r = lossf(out[16:20], ys[2]) if ROAD_W else torch.zeros(())
        loss = a + WET_W * w + ROAD_W * r
        opt.zero_grad(); loss.backward(); opt.step()
        n += 1; la += a.item(); lw += w.item(); lr_ += r.item()
        if n % 20 == 0:
            print(f"step {n}/{STEPS} aihub {la / n:.4f} wet {lw / n:.4f} road {lr_ / n:.4f} "
                  f"({(time.time() - t0) / n:.2f}s/step)", flush=True)
        if n >= STEPS:
            break
    torch.save(model.state_dict(), DATA / "model" / f"crosswalk_surface_{TAG}.pt")
    print(f"저장 model/crosswalk_surface_{TAG}.pt", round(time.time() - t0), "s")


def do_export(pt):
    model = load(pt)
    T.ONNX_OUT = str(DATA / Path(pt).with_suffix(".onnx"))
    T.export_onnx(model)
    print("ONNX", T.ONNX_OUT)


if __name__ == "__main__":
    m = wet_mask()
    assert int((m == 3).sum()) == (S - S // 2) * (2 * S // 3 - S // 3) and m[0, 0] == 255 and m[S - 1, S // 3] == 3
    assert not set(WET_TRAIN) & set(WET_EVAL) and wet_rows()[20]["final_label"] == "exclude"
    cmd = sys.argv[1]
    if cmd == "eval":
        do_eval(sys.argv[2], sys.argv[3])
    elif cmd == "train":
        do_train()
    elif cmd == "export":
        do_export(sys.argv[2])
