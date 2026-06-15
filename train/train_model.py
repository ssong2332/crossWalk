import os
import random
import shutil
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

DATA_DIR = r"C:\crossWalk\image"
PREPARED_DIR = r"C:\crossWalk\train\data_prepared"
MODEL_OUT = r"C:\crossWalk\model\crosswalk_model.pt"
ONNX_OUT = r"C:\crossWalk\model\crosswalk_model.onnx"
FRONT_SAMPLE = 500
IMG_SIZE = 224
BATCH_SIZE = 32
EPOCHS_FROZEN = 10
EPOCHS_FINETUNE = 10
LR_FROZEN = 1e-3
LR_FINETUNE = 1e-4
CLASSES = ["front", "left", "right"]


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

        if cls == "front":
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

    print("클래스 매핑:", train_ds.class_to_idx)
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
    # 클래스 가중치: left/right에 더 높은 가중치
    idx_to_cls = {v: k for k, v in class_to_idx.items()}
    weights_map = {"front": 1.0, "left": 10.0, "right": 20.0}
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
    plt.savefig(r"C:\crossWalk\model\confusion_matrix.png")
    print("혼동행렬 저장: C:\\crossWalk\\model\\confusion_matrix.png")


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
    print(f"  onnx2tf -i {ONNX_OUT} -o C:\\crossWalk\\model\\tflite_out")
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
