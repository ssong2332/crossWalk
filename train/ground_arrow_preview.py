"""3D(바닥 투영) 화살표 프로토타입 — 앱을 고치기 전에 실제 사진으로 먼저 확인한다.

문제 (사용자, 2026-09-05): 화살표가 화면에서 **평면 회전**만 하므로 원근이 없다.
바닥에 그려진 것처럼 보이려면 횡단보도와 **같은 소실점**으로 수렴해야 한다.

이 스크립트는 두 가지를 같은 사진 위에 나란히 그려 비교한다:
  (좌) 현재 방식 — 화면 중앙에서 각도만큼 평면 회전한 화살표
  (우) 제안 방식 — 지면 평면에 누운 화살표를 핀홀 카메라로 투영

지면 투영 수식 (카메라 원점, Y 위, +Z 전방, 아래로 pitch φ, 높이 h):
    지면점 (X, Z)  ->  Yc = -h·cos φ + Z·sin φ ,  Zc = h·sin φ + Z·cos φ
    화면 u = cx + f·X/Zc ,  v = cy - f·Yc/Zc      (v는 아래가 +)
  Z -> 무한대에서 v -> cy - f·tan φ = **수평선**, u -> cx + f·tan(yaw) = **소실점**.
  즉 같은 yaw를 가진 모든 지면 직선은 한 점으로 모인다 — 이게 "일치"의 조건이다.

각도(yaw)를 어디서 얻는가:
  횡단보도 줄무늬의 **긴 모서리**(보행 방향으로 뻗는 선)들은 보행 방향 소실점에서
  만난다. 그 교점을 RANSAC 비슷하게 중앙값으로 뽑아 yaw = atan((u_vp - cx)/f)로
  환산한다. 화면과 거의 수평인 선(줄무늬의 띠 자체)은 제외한다.

한계(정직하게): 카메라 내부값(화각·높이·pitch)은 **가정값**이다. 실기기에서는
  camera 패키지가 주는 화각을 쓰고 자세는 온보딩 안내("가슴 정면, 살짝 아래")를
  전제한다. 이 미리보기는 그 가정 아래에서 기하가 맞는지 눈으로 확인하기 위한 것이다.
"""
import math
import sys
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageOps

REPO = Path(__file__).resolve().parent.parent
IMAGE_ROOT = REPO / "image"
OUT_DIR = REPO / "train" / "sheets" / "ground_arrow"

# --- 카메라 가정값 -----------------------------------------------------------
FOV_W_DEG = 51.0     # 세로 표시 기준 가로 화각(4:3 센서의 짧은 변)
CAM_H_M = 1.30       # 가슴 높이
PITCH_DEG = 12.0     # "살짝 아래"

# --- 화살표 형상(월드 단위, 미터) --------------------------------------------
TAIL_Z = 1.8         # 발 앞 1.8 m에서 시작(화면 안에 들어오게)
SHAFT_LEN = 2.6
SHAFT_W = 0.42
HEAD_LEN = 1.0
HEAD_W = 1.05

COLOR_NEW = (242, 177, 74)     # 앱의 주황
COLOR_OLD = (120, 200, 255)    # 비교용 하늘색


def project(X, Z, w, h_img):
    f = (w / 2) / math.tan(math.radians(FOV_W_DEG) / 2)
    cx, cy = w / 2, h_img / 2
    phi = math.radians(PITCH_DEG)
    Yc = -CAM_H_M * math.cos(phi) + Z * math.sin(phi)
    Zc = CAM_H_M * math.sin(phi) + Z * math.cos(phi)
    if Zc <= 1e-6:
        return None
    return (cx + f * X / Zc, cy - f * Yc / Zc)


def ground_arrow_polys(yaw_deg, w, h_img):
    """지면에 누운 화살표를 이루는 폴리곤들을 화면 좌표로 돌려준다."""
    yaw = math.radians(yaw_deg)
    ux, uz = math.sin(yaw), math.cos(yaw)      # 진행 방향
    px, pz = math.cos(yaw), -math.sin(yaw)     # 좌우(수직) 방향

    def pt(t, s):
        return project(ux * t + px * s, TAIL_Z + uz * t + pz * s, w, h_img)

    shaft = [pt(0, -SHAFT_W / 2), pt(SHAFT_LEN, -SHAFT_W / 2),
             pt(SHAFT_LEN, SHAFT_W / 2), pt(0, SHAFT_W / 2)]
    head = [pt(SHAFT_LEN, -HEAD_W / 2), pt(SHAFT_LEN + HEAD_LEN, 0),
            pt(SHAFT_LEN, HEAD_W / 2)]
    if any(p is None for p in shaft + head):
        return None
    return shaft, head


def unproject(u, v, w, h_img):
    """화면점을 지면 평면 위의 (X, Z)로 역투영한다. 수평선 위면 None."""
    f = (w / 2) / math.tan(math.radians(FOV_W_DEG) / 2)
    cx, cy = w / 2, h_img / 2
    phi = math.radians(PITCH_DEG)
    k = (cy - v) / f
    den = math.sin(phi) - k * math.cos(phi)
    if den <= 1e-6:                      # 수평선 위 = 지면이 아님
        return None
    Z = CAM_H_M * (k * math.sin(phi) + math.cos(phi)) / den
    Zc = CAM_H_M * math.sin(phi) + Z * math.cos(phi)
    X = (u - cx) * Zc / f
    return X, Z


def estimate_yaw(im_gray, w, h_img):
    """줄무늬 선분을 **지면으로 역투영**해 실제 방향을 재고 yaw(도)를 추정한다.

    소실점 교점 방식은 다른 횡단보도·연석·차선이 섞이면 중앙값이 끌려가 실패했다
    (실측: 20260828_104042에서 좌상단으로 뻗는 횡단보도를 +11.4도로 오판).
    지면 역투영은 각 선분이 **바닥에서 실제로 몇 도인지**를 직접 주므로 섞인
    구조물이 있어도 길이 가중 히스토그램에서 횡단보도가 우세하게 남는다.

    횡단보도 흰 띠의 긴 모서리는 보행 방향과 **수직**이므로, 우세 방향에 90도를
    더한 것이 보행 방향이다.
    """
    g = cv2.GaussianBlur(np.asarray(im_gray), (5, 5), 0)
    edges = cv2.Canny(g, 50, 150)
    lines = cv2.HoughLinesP(edges, 1, np.pi / 180, threshold=60,
                            minLineLength=int(min(w, h_img) * 0.10), maxLineGap=20)
    if lines is None:
        return None, 0

    hist = np.zeros(180, dtype=np.float64)
    used = 0
    for x1, y1, x2, y2 in lines[:, 0]:
        a = unproject(float(x1), float(y1), w, h_img)
        b = unproject(float(x2), float(y2), w, h_img)
        if a is None or b is None:
            continue
        dX, dZ = b[0] - a[0], b[1] - a[1]
        ln = math.hypot(dX, dZ)
        if ln < 0.3 or ln > 60:          # 너무 짧거나 비현실적으로 긴 것은 버린다
            continue
        # 지면 방향각: 전방(+Z)을 0도, 오른쪽(+X)을 +로 두고 180도 주기로 접는다
        ang = int(round(math.degrees(math.atan2(dX, dZ)))) % 180
        hist[ang] += ln
        used += 1
    if used < 6 or hist.max() <= 0:
        return None, used

    k = np.array([1, 2, 3, 4, 5, 4, 3, 2, 1], dtype=np.float64)
    sm = np.convolve(np.r_[hist, hist, hist], k, mode="same")[180:360]
    dom = int(np.argmax(sm))             # 띠(줄무늬)의 지면 방향
    yaw = dom + 90                       # 보행 방향은 수직
    while yaw > 90:
        yaw -= 180
    while yaw <= -90:
        yaw += 180
    return float(yaw), used


def screen_angle_of_yaw(yaw_deg, w, h_img):
    """지면 yaw로 그린 화살표가 **화면에서** 몇 도로 보이는지 돌려준다."""
    yaw = math.radians(yaw_deg)
    tail = project(0.0, TAIL_Z, w, h_img)
    tip = project(math.sin(yaw) * (SHAFT_LEN + HEAD_LEN),
                  TAIL_Z + math.cos(yaw) * (SHAFT_LEN + HEAD_LEN), w, h_img)
    if tail is None or tip is None:
        return None
    return math.degrees(math.atan2(tip[0] - tail[0], -(tip[1] - tail[1])))


def yaw_for_screen_angle(target_deg, w, h_img):
    """화면에서 target_deg로 보이게 하는 지면 yaw를 이분법으로 찾는다.

    라벨(`train/label_angles.py`)은 사람이 **사진 위에 그은 화면 각도**다.
    그러므로 모델 출력을 그대로 평면 회전에 쓰면 원근이 빠지고,
    여기서 yaw로 환산해 지면에 눕히면 같은 방향을 원근에 맞게 그릴 수 있다.
    화면각은 yaw에 대해 단조증가라 이분법으로 안전하게 풀린다.
    """
    lo, hi = -80.0, 80.0
    for _ in range(60):
        mid = (lo + hi) / 2
        a = screen_angle_of_yaw(mid, w, h_img)
        if a is None:
            return None
        if a < target_deg:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2


def flat_arrow(draw, w, h_img, angle_deg, color):
    """현재 앱 방식 — 화면 중앙에서 평면 회전만 한 화살표."""
    cx, cy = w / 2, h_img / 2
    unit = min(w, h_img) * 0.22
    a = math.radians(angle_deg)
    dx, dy = math.sin(a), -math.cos(a)
    tail = (cx - dx * unit, cy - dy * unit)
    tip = (cx + dx * unit, cy + dy * unit)
    lw = max(6, int(min(w, h_img) * 0.018))
    draw.line([tail, tip], fill=color, width=lw)
    for s in (+1, -1):
        b = a + math.pi + s * math.radians(30)
        draw.line([tip, (tip[0] + math.sin(b) * unit * 0.45,
                         tip[1] - math.cos(b) * unit * 0.45)], fill=color, width=lw)


def render(path, out_path, label_deg=None):
    im = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    W, H = im.size
    scale = 900 / W
    im = im.resize((900, int(H * scale)), Image.BILINEAR)
    W, H = im.size

    if label_deg is None:
        yaw, nseg = estimate_yaw(im.convert("L"), W, H)
        screen_deg = yaw if yaw is not None else 0.0
    else:
        screen_deg, nseg = label_deg, -1

    left = im.copy()
    right = im.copy()
    dl = ImageDraw.Draw(left, "RGBA")
    dr = ImageDraw.Draw(right, "RGBA")

    flat_arrow(dl, W, H, screen_deg, COLOR_OLD + (235,))
    yaw_for_draw = yaw_for_screen_angle(screen_deg, W, H) or 0.0
    polys = ground_arrow_polys(yaw_for_draw, W, H)
    if polys:
        shaft, head = polys
        dr.polygon(shaft, fill=COLOR_NEW + (215,))
        dr.polygon(head, fill=COLOR_NEW + (245,))
        # 수평선(소실점 높이) 참고선
        f = (W / 2) / math.tan(math.radians(FOV_W_DEG) / 2)
        vy = H / 2 - f * math.tan(math.radians(PITCH_DEG))
        dr.line([(0, vy), (W, vy)], fill=(255, 255, 255, 90), width=2)

    canvas = Image.new("RGB", (W * 2 + 24, H), (18, 18, 20))
    canvas.paste(left, (0, 0))
    canvas.paste(right, (W + 24, 0))
    d = ImageDraw.Draw(canvas)
    d.text((12, 10), f"BEFORE  flat rotation   screen={screen_deg:+.1f}deg",
           fill=(255, 255, 255))
    d.text((W + 36, 10), f"AFTER  ground-projected   same screen dir, yaw={yaw_for_draw:+.1f}deg",
           fill=(255, 255, 255))
    canvas.save(out_path, quality=90)
    return screen_deg


def load_labels():
    import csv
    out = {}
    with open(REPO / "train/angle_labels.csv", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            if r["status"] == "ok":
                out[r["filename"]] = float(r["angle_deg"])
    return out


def main():
    labels = load_labels()
    names = sys.argv[1:] or [
        "20260828_104042.jpg", "20260828_104621.jpg", "20260828_104040.jpg",
        "20260828_104642.jpg", "20260708_203305.jpg", "20251119_154949.jpg",
    ]
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for n in names:
        src = None
        for d in ("0_none", "1_approach", "2_front", "3_left", "4_right"):
            if (IMAGE_ROOT / d / n).exists():
                src = IMAGE_ROOT / d / n
                break
        if src is None:
            print(f"[없음] {n}")
            continue
        out = OUT_DIR / f"cmp_{Path(n).stem}.jpg"
        lab = labels.get(n)
        shown = render(src, out, label_deg=lab)
        src_txt = "사람 라벨" if lab is not None else "기하 추정"
        print(f"{n:32} {src_txt} {shown:+6.1f}도  -> {out.name}")


if __name__ == "__main__":
    main()
