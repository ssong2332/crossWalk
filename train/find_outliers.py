"""T80 — 누수 없는 CV로 학습에 방해되는 이미지(오분류/이상치)를 찾아 정리한다.

방법 (추측 없이 실측):
  각 이미지는 그 이미지가 **학습에서 제외된 fold**의 모델이 예측한 확률을
  가진다(groupkfold_cv.py의 all_probs.json). 이건 그 이미지를 한 번도 보지
  않은 모델의 일반화 성능이므로, 모델이 자신 있게 다른 클래스라고 말하면
  세 가지 중 하나다:
    (a) 라벨이 실제로 틀렸다 (오분류)
    (b) 사진이 그 클래스의 전형에서 크게 벗어난다 (이상치 — 틀린 건 아니지만
        학습 분포를 흐린다)
    (c) 모델이 아직 그 패턴을 배우지 못했다 (정상적인 어려운 샘플)

  (a)(b)와 (c)를 코드로 완벽히 가를 수는 없으므로, 이 스크립트는 **후보만
  뽑아 사람이 보게** 정리한다 — 자동으로 삭제·재라벨링하지 않는다.

기준 (미리 고정):
  - 정답 클래스 확률 < 0.05 이고 1위 예측 확률 > 0.80  (확신에 찬 오답)
  - 근사중복 클러스터 안에서 클래스가 섞인 경우 (같은 장면, 다른 라벨)
  - 세션 안에서 같은 클래스인데 확률이 극단적으로 갈리는 경우는 여기서
    다루지 않는다 — 흔들림(T72)과 겹치므로 별도 분석이 필요하다.

산출물: train/review_outliers/<원인>/<클래스>/<파일> 로 사본을 모으고
        train/review_outliers/manifest.csv 에 근거(확률, fold)를 남긴다.
        원본은 건드리지 않는다 — 삭제·이동이 아니라 복사다.
"""
import csv
import json
import shutil
from collections import defaultdict
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps

REPO = Path(__file__).resolve().parent.parent
IMAGE_ROOT = REPO / "image"
OUT_DIR = REPO / "train" / "review_outliers"
CV_JSON = REPO / "train" / "groupkfold_5class_out" / "all_probs.json"

CLASS_DIRS = ["0_none", "1_approach", "2_front", "3_left", "4_right"]
LABELS = ["none", "approach", "front", "left", "right"]

CONFIDENT_WRONG_TRUE_MAX = 0.05
CONFIDENT_WRONG_PRED_MIN = 0.80


def find_confident_wrong(cv):
    out = []
    for r in cv:
        true = r["true"]
        probs = r["probs"]
        true_p = probs[true]
        pred_label = max(probs, key=probs.get)
        pred_p = probs[pred_label]
        if pred_label == true:
            continue
        if true_p < CONFIDENT_WRONG_TRUE_MAX and pred_p > CONFIDENT_WRONG_PRED_MIN:
            out.append((r["file"], true, pred_label, true_p, pred_p, r.get("fold")))
    return out


def find_mixed_dup_clusters(cv):
    """근사중복(픽셀차<10, 세션 내부) 클러스터 안에 클래스가 섞인 경우.

    groupkfold_cv.py와 같은 정의를 그대로 재현한다(세션 60초, 픽셀차<10).
    """
    from datetime import datetime
    import PIL.ExifTags as ExifTags

    items = []
    for cd, cls in zip(CLASS_DIRS, LABELS):
        for f in sorted((IMAGE_ROOT / cd).iterdir()):
            if f.suffix.lower() not in (".jpg", ".jpeg", ".png"):
                continue
            ex = Image.open(f)._getexif() or {}
            dt = None
            for k, v in ex.items():
                if ExifTags.TAGS.get(k) == "DateTimeOriginal":
                    dt = datetime.strptime(v, "%Y:%m:%d %H:%M:%S")
            items.append({"path": f, "cls": cls, "file": f.name, "dt": dt})

    items.sort(key=lambda r: r["dt"])
    sid, prev = 0, None
    for r in items:
        if prev is not None and (r["dt"] - prev).total_seconds() > 60:
            sid += 1
        r["session"] = sid
        prev = r["dt"]

    sig = {}
    for r in items:
        im = ImageOps.exif_transpose(Image.open(r["path"])).convert("L").resize((64, 64))
        sig[r["file"]] = np.asarray(im, dtype=np.float32)

    by_sess = defaultdict(list)
    for r in items:
        by_sess[r["session"]].append(r)

    parent = {r["file"]: r["file"] for r in items}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb

    for _, lst in by_sess.items():
        for i in range(len(lst)):
            for j in range(i + 1, len(lst)):
                d = float(np.abs(sig[lst[i]["file"]] - sig[lst[j]["file"]]).mean())
                if d < 10.0:
                    union(lst[i]["file"], lst[j]["file"])

    clusters = defaultdict(list)
    by_file = {r["file"]: r for r in items}
    for r in items:
        clusters[find(r["file"])].append(r["file"])

    mixed = []
    for files in clusters.values():
        if len(files) < 2:
            continue
        classes_in = set(by_file[f]["cls"] for f in files)
        if len(classes_in) > 1:
            mixed.append((files, classes_in))
    return mixed, by_file


def copy_out(reason, cls, filename, manifest_row, manifest):
    src = None
    for cd, lab in zip(CLASS_DIRS, LABELS):
        p = IMAGE_ROOT / cd / filename
        if p.exists():
            src = p
            break
    if src is None:
        return
    dst_dir = OUT_DIR / reason / cls
    dst_dir.mkdir(parents=True, exist_ok=True)
    dst = dst_dir / filename
    if not dst.exists():
        shutil.copy2(src, dst)
    manifest.append(manifest_row)


def main():
    if OUT_DIR.exists():
        shutil.rmtree(OUT_DIR)
    OUT_DIR.mkdir(parents=True)

    cv = json.load(open(CV_JSON, encoding="utf-8"))
    print(f"CV 표본 수: {len(cv)}")

    manifest = []

    confident_wrong = find_confident_wrong(cv)
    print(f"\n확신에 찬 오답 (정답확률<{CONFIDENT_WRONG_TRUE_MAX}, "
          f"예측확률>{CONFIDENT_WRONG_PRED_MIN}): {len(confident_wrong)}건")
    for name, true, pred, true_p, pred_p, fold in sorted(
            confident_wrong, key=lambda r: -r[4]):
        print(f"  {name:32} 정답={true:8} -> 예측={pred:8} "
              f"(정답확률 {true_p:.3f}, 예측확률 {pred_p:.3f}, fold{fold})")
        copy_out("confident_wrong", true, name, {
            "reason": "confident_wrong", "file": name, "true": true,
            "pred": pred, "true_prob": f"{true_p:.4f}",
            "pred_prob": f"{pred_p:.4f}", "fold": fold,
        }, manifest)

    mixed, by_file = find_mixed_dup_clusters(cv)
    print(f"\n근사중복인데 클래스가 섞인 클러스터: {len(mixed)}건")
    for files, classes_in in mixed:
        print(f"  클래스={classes_in}  파일={files}")
        for f in files:
            copy_out("mixed_duplicate_cluster", by_file[f]["cls"], f, {
                "reason": "mixed_duplicate_cluster", "file": f,
                "true": by_file[f]["cls"], "pred": "", "true_prob": "",
                "pred_prob": "", "fold": "",
            }, manifest)

    if manifest:
        with open(OUT_DIR / "manifest.csv", "w", encoding="utf-8", newline="") as f:
            w = csv.DictWriter(f, fieldnames=[
                "reason", "file", "true", "pred", "true_prob", "pred_prob", "fold"])
            w.writeheader()
            w.writerows(manifest)
        print(f"\n정리 완료: {OUT_DIR} (사본 {len(manifest)}장, manifest.csv 포함)")
    else:
        print("\n후보 없음 — 정리할 파일이 없습니다.")


if __name__ == "__main__":
    main()
