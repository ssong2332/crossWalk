import os
import random
import shutil
from pathlib import Path
import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import DataLoader, WeightedRandomSampler
from torchvision import transforms, datasets
from torchvision.models import mobilenet_v3_small, MobileNet_V3_Small_Weights
from sklearn.metrics import classification_report, confusion_matrix
import matplotlib.pyplot as plt

SEED = 42
random.seed(SEED)
np.random.seed(SEED)
torch.manual_seed(SEED)

REPO_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = REPO_ROOT / "image"
PREPARED_DIR = REPO_ROOT / "train" / "data_prepared"
MODEL_OUT = REPO_ROOT / "model" / "crosswalk_model.pt"
ONNX_OUT = REPO_ROOT / "model" / "crosswalk_model.onnx"
CONFUSION_MATRIX_OUT = REPO_ROOT / "model" / "confusion_matrix.png"
TFLITE_OUT_DIR = REPO_ROOT / "model" / "tflite_out"
FRONT_SAMPLE = 500
IMG_SIZE = 224
BATCH_SIZE = 32
EPOCHS_FROZEN = 10
EPOCHS_FINETUNE = 10
LR_FROZEN = 1e-3
LR_FINETUNE = 1e-4

# T51: 4-class -> 5-class. `approach`(인도 위인데 앞에 진입할 횡단보도가 보임) 신설.
#
# 파일시스템 경로와 의미 라벨을 분리한다. torchvision ImageFolder는 하위 폴더명을
# 알파벳순으로 정렬해 class_to_idx를 부여하므로, 폴더명에 숫자 접두사를 붙여
# 알파벳순 = 의도한 인덱스순이 되도록 image/ 를 재구성했다.
# 실측값: ImageFolder(...).class_to_idx ==
#   {'0_none': 0, '1_approach': 1, '2_front': 2, '3_left': 3, '4_right': 4}
# CLASS_DIRS[i] 와 LABELS[i] 는 반드시 같은 인덱스를 가리켜야 하며,
# LABELS 순서는 crosswalk_app/lib/services/classifier.dart 의 `_labels` 와
# 정확히 일치해야 한다. 어긋나면 에러 없이 조용히 오작동한다(T42 전례).
CLASS_DIRS = ["0_none", "1_approach", "2_front", "3_left", "4_right"]
LABELS = ["none", "approach", "front", "left", "right"]
assert len(CLASS_DIRS) == len(LABELS)
assert CLASS_DIRS == sorted(CLASS_DIRS), "폴더명 알파벳순 == 인덱스순이어야 한다"

# `CLASSES`는 이 스크립트 내부에서 "클래스 폴더 목록"으로 쓰이던 이름이므로
# CLASS_DIRS의 별칭으로 유지한다(경로 기반 사용처와 의미를 맞춤).
CLASSES = CLASS_DIRS

# 상한 샘플링 대상 폴더. 과거 front가 압도적 다수 클래스였을 때 도입된 상한이며,
# 현재(T51 재라벨링 후) front는 130장으로 이 상한에 걸리지 않는다.
FRONT_DIR = "2_front"


# ── 1. 데이터 준비 ──────────────────────────────────────────────────
def prepare_data():
    if os.path.exists(PREPARED_DIR):
        shutil.rmtree(PREPARED_DIR)

    for split in ["train", "val", "test"]:
        for cls in CLASSES:
            os.makedirs(os.path.join(PREPARED_DIR, split, cls), exist_ok=True)

    for cls in CLASSES:
        src = os.path.join(DATA_DIR, cls)
        files = [f for f in os.listdir(src) if f.lower().endswith((".jpg", ".jpeg", ".png"))]
        random.shuffle(files)

        if cls == FRONT_DIR:
            files = files[:FRONT_SAMPLE]

        n = len(files)
        n_train = int(n * 0.8)
        n_val = int(n * 0.1)
        splits = {
            "train": files[:n_train],
            "val":   files[n_train:n_train + n_val],
            "test":  files[n_train + n_val:],
        }

        for split, flist in splits.items():
            for fname in flist:
                shutil.copy(
                    os.path.join(src, fname),
                    os.path.join(PREPARED_DIR, split, cls, fname)
                )

    for split in ["train", "val", "test"]:
        counts = {cls: len(os.listdir(os.path.join(PREPARED_DIR, split, cls))) for cls in CLASSES}
        print(f"[{split}] {counts}")


# ── 2. DataLoader ───────────────────────────────────────────────────
def get_loaders():
    train_tf = transforms.Compose([
        transforms.Resize((IMG_SIZE, IMG_SIZE)),
        transforms.RandomHorizontalFlip(),
        transforms.RandomRotation(15),
        transforms.ColorJitter(brightness=0.3, contrast=0.3, saturation=0.2, hue=0.05),
        transforms.ToTensor(),
        transforms.Normalize([0.485, 0.456, 0.406], [0.229, 0.224, 0.225]),
    ])
    val_tf = transforms.Compose([
        transforms.Resize((IMG_SIZE, IMG_SIZE)),
        transforms.ToTensor(),
        transforms.Normalize([0.485, 0.456, 0.406], [0.229, 0.224, 0.225]),
    ])

    train_ds = datasets.ImageFolder(os.path.join(PREPARED_DIR, "train"), transform=train_tf)
    val_ds   = datasets.ImageFolder(os.path.join(PREPARED_DIR, "val"),   transform=val_tf)
    test_ds  = datasets.ImageFolder(os.path.join(PREPARED_DIR, "test"),  transform=val_tf)

    # 클래스 가중치 기반 WeightedRandomSampler
    class_counts = [len(os.listdir(os.path.join(PREPARED_DIR, "train", cls))) for cls in train_ds.classes]
    weights = [1.0 / class_counts[label] for _, label in train_ds.samples]
    sampler = WeightedRandomSampler(weights, num_samples=len(weights), replacement=True)

    train_loader = DataLoader(train_ds, batch_size=BATCH_SIZE, sampler=sampler, num_workers=0)
    val_loader   = DataLoader(val_ds,   batch_size=BATCH_SIZE, shuffle=False,   num_workers=0)
    test_loader  = DataLoader(test_ds,  batch_size=BATCH_SIZE, shuffle=False,   num_workers=0)

    # T51 필수 검증: ImageFolder가 실제로 부여한 인덱스가 CLASS_DIRS 순서와
    # 일치하지 않으면 로짓이 엉뚱한 라벨에 매핑된다(에러 없이 조용히 오작동).
    # 학습을 시작하기 전에 여기서 즉시 중단시킨다.
    print("클래스 매핑(class_to_idx):", train_ds.class_to_idx)
    print("기대 순서(CLASS_DIRS):", CLASS_DIRS)
    print("의미 라벨(LABELS, classifier.dart의 _labels와 동일해야 함):", LABELS)
    expected = {d: i for i, d in enumerate(CLASS_DIRS)}
    if train_ds.class_to_idx != expected:
        raise AssertionError(
            "class_to_idx 불일치 — 학습 중단.\n"
            f"  실제 : {train_ds.class_to_idx}\n"
            f"  기대 : {expected}\n"
            "  image/ 폴더명 또는 CLASS_DIRS를 확인할 것."
        )
    for split, ds in (("val", val_ds), ("test", test_ds)):
        if ds.class_to_idx != expected:
            raise AssertionError(
                f"{split} split의 class_to_idx가 train과 다름 — 학습 중단.\n"
                f"  실제 : {ds.class_to_idx}\n  기대 : {expected}"
            )

    return train_loader, val_loader, test_loader, train_ds.class_to_idx


# ── 3. 모델 구성 ────────────────────────────────────────────────────
def build_model():
    model = mobilenet_v3_small(weights=MobileNet_V3_Small_Weights.DEFAULT)
    in_features = model.classifier[3].in_features
    model.classifier[3] = nn.Linear(in_features, len(CLASSES))
    return model


# ── 4. 학습 루프 ────────────────────────────────────────────────────
def train_epoch(model, loader, optimizer, criterion, device):
    model.train()
    total_loss, correct, total = 0.0, 0, 0
    for imgs, labels in loader:
        imgs, labels = imgs.to(device), labels.to(device)
        optimizer.zero_grad()
        out = model(imgs)
        loss = criterion(out, labels)
        loss.backward()
        optimizer.step()
        total_loss += loss.item() * imgs.size(0)
        correct += (out.argmax(1) == labels).sum().item()
        total += imgs.size(0)
    return total_loss / total, correct / total


def eval_epoch(model, loader, criterion, device):
    model.eval()
    total_loss, correct, total = 0.0, 0, 0
    with torch.no_grad():
        for imgs, labels in loader:
            imgs, labels = imgs.to(device), labels.to(device)
            out = model(imgs)
            loss = criterion(out, labels)
            total_loss += loss.item() * imgs.size(0)
            correct += (out.argmax(1) == labels).sum().item()
            total += imgs.size(0)
    return total_loss / total, correct / total


def run_training(model, train_loader, val_loader, device, class_to_idx):
    # 클래스 가중치: 다수 클래스 대비 역빈도 가중치.
    # T42 이전에는 {"front":1.0,"left":10.0,"right":20.0}로 하드코딩되어 있었으나,
    # 이는 당시 train split 개수(front~400,left~37,right~19)의 front/count 비율과
    # 거의 일치한다 (400/37≈10.8, 400/19≈21). "none" 클래스 추가로 개수가 매번
    # 바뀌므로, 매직 넘버 대신 실제 train split 개수로부터 그 비율을 재계산했다.
    #
    # T51 변경: 기준을 하드코딩된 "front"에서 **최다 클래스**로 일반화했다.
    # 이유 — 5-class 재라벨링 후 front는 더 이상 다수 클래스가 아니다
    # (none 229 > front 130). 기준이 최다 클래스가 아니면 일부 가중치가 1 미만이
    # 되어 "역빈도 가중치"라는 원래 의도와 읽는 사람의 기대가 어긋난다.
    # 학습 결과는 바뀌지 않는다: nn.CrossEntropyLoss(reduction="mean")는
    # sum(w_i * l_i) / sum(w_i)를 계산하므로 가중치 전체에 상수배를 해도 값이
    # 동일하다. front 기준 -> 최다 클래스 기준은 정확히 상수배(max/front)이다.
    idx_to_cls = {v: k for k, v in class_to_idx.items()}
    train_counts = {
        cls: len(os.listdir(os.path.join(PREPARED_DIR, "train", cls))) for cls in CLASSES
    }
    max_count = max(train_counts.values())
    weights_map = {cls: max_count / train_counts[cls] for cls in CLASSES}
    print("클래스별 train 개수:", train_counts)
    print("클래스 가중치 (max_count/count):", weights_map)
    class_weights = torch.tensor(
        [weights_map[idx_to_cls[i]] for i in range(len(CLASSES))],
        dtype=torch.float
    ).to(device)
    criterion = nn.CrossEntropyLoss(weight=class_weights)

    # 1차: backbone frozen
    for param in model.features.parameters():
        param.requires_grad = False
    optimizer = optim.Adam(filter(lambda p: p.requires_grad, model.parameters()), lr=LR_FROZEN)

    print("\n=== 1차 학습 (backbone frozen) ===")
    for epoch in range(EPOCHS_FROZEN):
        tr_loss, tr_acc = train_epoch(model, train_loader, optimizer, criterion, device)
        vl_loss, vl_acc = eval_epoch(model, val_loader, criterion, device)
        print(f"Epoch {epoch+1:02d} | train loss={tr_loss:.4f} acc={tr_acc:.4f} | val loss={vl_loss:.4f} acc={vl_acc:.4f}")

    # 2차: 전체 unfreeze fine-tuning
    for param in model.parameters():
        param.requires_grad = True
    optimizer = optim.Adam(model.parameters(), lr=LR_FINETUNE)
    scheduler = optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=EPOCHS_FINETUNE)

    print("\n=== 2차 학습 (fine-tuning) ===")
    best_val_acc = 0.0
    for epoch in range(EPOCHS_FINETUNE):
        tr_loss, tr_acc = train_epoch(model, train_loader, optimizer, criterion, device)
        vl_loss, vl_acc = eval_epoch(model, val_loader, criterion, device)
        scheduler.step()
        print(f"Epoch {epoch+1:02d} | train loss={tr_loss:.4f} acc={tr_acc:.4f} | val loss={vl_loss:.4f} acc={vl_acc:.4f}")
        if vl_acc > best_val_acc:
            best_val_acc = vl_acc
            torch.save(model.state_dict(), MODEL_OUT)
            print(f"  -> Best model saved (val_acc={best_val_acc:.4f})")

    return model


# ── 5. 평가 ─────────────────────────────────────────────────────────
def evaluate(model, test_loader, device, class_to_idx):
    idx_to_cls = {v: k for k, v in class_to_idx.items()}
    model.eval()
    all_preds, all_labels = [], []
    with torch.no_grad():
        for imgs, labels in test_loader:
            imgs = imgs.to(device)
            out = model(imgs)
            preds = out.argmax(1).cpu().numpy()
            all_preds.extend(preds)
            all_labels.extend(labels.numpy())

    target_names = [idx_to_cls[i] for i in range(len(CLASSES))]
    print("\n=== Test Set 평가 ===")
    print(classification_report(all_labels, all_preds, target_names=target_names))

    cm = confusion_matrix(all_labels, all_preds)
    fig, ax = plt.subplots()
    im = ax.imshow(cm, cmap="Blues")
    ax.set_xticks(range(len(target_names)))
    ax.set_yticks(range(len(target_names)))
    ax.set_xticklabels(target_names)
    ax.set_yticklabels(target_names)
    ax.set_xlabel("Predicted")
    ax.set_ylabel("True")
    plt.colorbar(im)
    plt.tight_layout()
    plt.savefig(CONFUSION_MATRIX_OUT)
    print(f"혼동행렬 저장: {CONFUSION_MATRIX_OUT}")


# ── 6. ONNX 변환 ────────────────────────────────────────────────────
def export_onnx(model, device):
    model.eval()
    dummy = torch.randn(1, 3, IMG_SIZE, IMG_SIZE).to(device)
    torch.onnx.export(
        model, dummy, ONNX_OUT,
        input_names=["input"],
        output_names=["output"],
        dynamic_axes={"input": {0: "batch"}, "output": {0: "batch"}},
        opset_version=17,
    )
    print(f"ONNX 모델 저장: {ONNX_OUT}")
    print("\n다음 명령으로 TFLite 변환:")
    print(f"  pip install onnx2tf")
    print(f"  onnx2tf -i {ONNX_OUT} -o {TFLITE_OUT_DIR}")
    print("  -> crosswalk_model.tflite 생성됨")


# ── Main ─────────────────────────────────────────────────────────────
if __name__ == "__main__":
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"Device: {device}")

    print("\n[1] 데이터 준비 중...")
    prepare_data()

    print("\n[2] DataLoader 구성 중...")
    train_loader, val_loader, test_loader, class_to_idx = get_loaders()

    print("\n[3] 모델 구성 중...")
    model = build_model().to(device)

    print("\n[4] 학습 시작...")
    model = run_training(model, train_loader, val_loader, device, class_to_idx)

    print("\n[5] 최적 모델 로드 후 평가...")
    model.load_state_dict(torch.load(MODEL_OUT, map_location=device))
    evaluate(model, test_loader, device, class_to_idx)

    print("\n[6] ONNX 변환...")
    export_onnx(model, device)

    print("\n완료!")
