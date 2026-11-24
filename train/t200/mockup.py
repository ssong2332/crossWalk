"""T200: 횡단보도 경계 표시 시안 — 실기기 프레임에 후보 A/B/C(+C 저시력 색)를 덧그린다.
노면 모델은 앱과 같은 ONNX·전처리(scan.py). 이미지는 train/t200/img/ (커밋 금지, .gitignore).
실행(저장소/워크트리 루트): PYTHONIOENCODING=utf-8 python train/t200/mockup.py
자체 검증: python train/t200/mockup.py --selftest
"""
import sys
from pathlib import Path
import cv2, numpy as np, onnxruntime as ort
sys.path.insert(0, str(Path(__file__).parent))
from scan import MODEL, DATA, MEAN, STD, load_upright, seg, CW

FRAMES = [  # (id, 폴더, 파일, 설명) — scan.csv에서 골랐다
    ("center", "frames_1122", "f_1795341276884.jpg", "횡단보도 가운데"),
    ("onright", "frames_1110", "f_1794307978052.jpg", "횡단보도 오른쪽 끝 쪽(횡단보도가 화면 왼쪽으로 치우침)"),
    ("onleft", "frames_1122", "f_1795341235771.jpg", "횡단보도 왼쪽 끝 쪽(횡단보도가 화면 오른쪽으로 치우침)"),
    ("approach", "frames_1112", "f_1794459241738.jpg", "접근 중(횡단보도가 앞쪽 멀리)"),
]
OUT = Path(__file__).with_name("img")
# BGR. 경계색 보라(#B58CFF)는 앱 화살표 색(스틸 #A8CDE8·앰버 #F2B14A·심함 #FF5A5F·노란 면 #FFD60A)과 겹치지 않게 골랐다
YELLOW, BLACK, CYAN, RED = (10, 214, 255), (0, 0, 0), (255, 140, 181), (60, 60, 255)

def big_mask(m224, w, h):
    """224 격자 마스크 → 화면 크기. 선형 보간 후 0.5로 잘라 계단을 없앤다."""
    up = cv2.resize(m224.astype(np.float32), (w, h), interpolation=cv2.INTER_LINEAR)
    return (up > 0.5).astype(np.uint8)

def largest(m):
    n, lab, st, _ = cv2.connectedComponentsWithStats(m, 8)
    if n <= 1: return m * 0
    k = 1 + int(np.argmax(st[1:, cv2.CC_STAT_AREA]))
    return (lab == k).astype(np.uint8)

def edges(m224, min_rows=12):
    """후보 C: 행마다 횡단보도 픽셀의 왼쪽·오른쪽 끝 → 두 직선 x = a*y + b (224 격자).
    가장 큰 덩어리만 쓴다. 행이 모자라면 None. 반환 (left(a,b), right(a,b), y_top, y_bot)."""
    m = largest(m224.astype(np.uint8))
    ys = [y for y in range(224) if m[y].sum() >= 6]
    if len(ys) < min_rows: return None
    ys = np.array(ys)
    xl = np.array([np.nonzero(m[y])[0][0] for y in ys]); xr = np.array([np.nonzero(m[y])[0][-1] for y in ys])
    def fit(x):  # 1회 이상치 제거(잔차 상위 20%) 후 최소제곱
        p = np.polyfit(ys, x, 1); r = np.abs(np.polyval(p, ys) - x)
        keep = r <= np.quantile(r, 0.8); return tuple(np.polyfit(ys[keep], x[keep], 1))
    return fit(xl), fit(xr), int(ys.min()), int(ys.max())

def position(e):
    """발 앞(맨 아래 행)에서 화면 가운데(=사용자)가 두 선 사이 어디인지: 0=왼쪽 선, 1=오른쪽 선."""
    (la, lb), (ra, rb), _, _ = e
    xl, xr = la * 223 + lb, ra * 223 + rb
    return (111.5 - xl) / max(xr - xl, 1e-6)

def draw_A(img, m):
    o = img.copy(); o[m > 0] = (0.55 * o[m > 0] + 0.45 * np.array(CYAN)).astype(np.uint8); return o

def draw_B(img, m):
    o = img.copy(); c = largest(m)
    cs, _ = cv2.findContours(c, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    for k in cs:
        poly = cv2.approxPolyDP(k, 0.01 * cv2.arcLength(k, True), True)
        cv2.polylines(o, [poly], True, CYAN, 4, cv2.LINE_AA)
    return o

POS_MODEL = MODEL.with_name("crosswalk_position.onnx")
EDGE_POS = 1.0  # DirectionResolver.edgePosition (direction_resolver.dart:192)

def pos_model(sess, bgr):
    """앱과 같다: 화면 전체를 224로 누름(seg와 같은 입력) → 출력 * POS_SCALE(2.0). -2 왼쪽 끝 ~ +2 오른쪽 끝."""
    rgb = cv2.cvtColor(cv2.resize(bgr, (224, 224), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2RGB)
    x = ((rgb / 255.0 - MEAN) / STD).transpose(2, 0, 1)[None].astype(np.float32)
    return float(np.ravel(sess.run(None, {sess.get_inputs()[0].name: x})[0])[0]) * 2.0

def visible_sides(e, margin=4, reach=200):
    """화면 테두리에 붙은 선(=경계가 화면 밖)과, 발 앞까지 오지 않은 횡단보도(접근 중)는 그리지 않는다."""
    if e is None: return []
    (la, lb), (ra, rb), yt, yb = e
    if yb < reach: return []
    out = []
    xs_l = [la * y + lb for y in (yt, yb)]; xs_r = [ra * y + rb for y in (yt, yb)]
    if min(xs_l) > margin: out.append("left")
    if max(xs_r) < 223 - margin: out.append("right")
    return out

def draw_C(img, m, e, pos, low_vision=False):
    """후보 C: 칠하기(A, 옅게) + **보이는** 양 끝 경계선 + 아래 위치 막대(위치 모델)."""
    h, w = img.shape[:2]; sx, sy = w / 224, h / 224
    near = "left" if pos is not None and pos <= -EDGE_POS else ("right" if pos is not None and pos >= EDGE_POS else None)
    if low_vision:
        o = (img * 0.45).astype(np.uint8); o[m > 0] = img[m > 0]  # 밖을 어둡게 — 횡단보도만 밝다
    else:
        o = img.copy(); o[m > 0] = (0.75 * o[m > 0] + 0.25 * np.array(CYAN)).astype(np.uint8)
    if e is not None:
        (la, lb), (ra, rb), yt, yb = e
        for side in visible_sides(e):
            a, b = (la, lb) if side == "left" else (ra, rb)
            P = [(int((a * y + b) * sx), int(y * sy)) for y in (yt, yb)]
            hot = side == near
            if low_vision:
                t = 30 if hot else 18
                cv2.line(o, P[0], P[1], BLACK, t + 10, cv2.LINE_AA); cv2.line(o, P[0], P[1], YELLOW, t, cv2.LINE_AA)
            else:
                cv2.line(o, P[0], P[1], BLACK, 13 if hot else 9, cv2.LINE_AA)
                cv2.line(o, P[0], P[1], CYAN, 9 if hot else 5, cv2.LINE_AA)
                if hot: cv2.line(o, P[0], P[1], BLACK, 2, cv2.LINE_AA)  # 이중선
    if pos is not None:  # 위치 막대: 왼쪽 끝(-2) ~ 오른쪽 끝(+2), 끝 구간(|p|>=1)은 막대 양 끝 25%
        bx0, bx1, by = int(w * 0.15), int(w * 0.85), h - 40
        thick = 14 if low_vision else 6
        cv2.line(o, (bx0, by), (bx1, by), BLACK, thick + 6)
        cv2.line(o, (bx0, by), (bx1, by), YELLOW if low_vision else (255, 255, 255), thick)
        for f in (0.25, 0.75):
            x = int(bx0 + f * (bx1 - bx0)); cv2.line(o, (x, by - 14), (x, by + 14), BLACK, 4)
        px = int(bx0 + (np.clip(pos, -2, 2) + 2) / 4 * (bx1 - bx0))
        cv2.circle(o, (px, by), 22 if low_vision else 13, BLACK, -1)
        cv2.circle(o, (px, by), 16 if low_vision else 9, (255, 255, 255) if not low_vision else YELLOW, -1)
        if near: cv2.circle(o, (px, by), 24 if low_vision else 15, (255, 255, 255), 3)  # 끝 구간: 고리(색 아님)
    return o

def selftest():
    m = np.zeros((224, 224), np.uint8); m[60:224, 40:180] = 1  # 곧은 사각형 횡단보도
    e = edges(m); (la, lb), (ra, rb), yt, yb = e
    assert abs(la) < 1e-6 and abs(lb - 40) < 1e-6 and abs(rb - 179) < 1e-6 and yt == 60, e
    assert abs(position(e) - (111.5 - 40) / 139) < 1e-6
    assert edges(np.zeros((224, 224), np.uint8)) is None
    m2 = m.copy(); m2[0:5, 0:5] = 1  # 작은 오검출 덩어리는 무시
    assert edges(m2)[0][1] == e[0][1]
    assert visible_sides(e) == ["left", "right"]
    m3 = np.zeros((224, 224), np.uint8); m3[60:224, 0:150] = 1  # 왼쪽 경계가 화면 밖
    assert visible_sides(edges(m3)) == ["right"]
    m4 = np.zeros((224, 224), np.uint8); m4[40:120, 20:200] = 1  # 접근 중(발 앞까지 안 옴)
    assert visible_sides(edges(m4)) == []
    print("selftest ok")

if __name__ == "__main__":
    if "--selftest" in sys.argv: selftest(); sys.exit()
    OUT.mkdir(exist_ok=True)
    sess = ort.InferenceSession(str(MODEL), providers=["CPUExecutionProvider"])
    psess = ort.InferenceSession(str(POS_MODEL), providers=["CPUExecutionProvider"])
    for fid, d, f, _ in FRAMES:
        img = load_upright(DATA / d / f); h, w = img.shape[:2]
        m224 = (seg(sess, img) == CW).astype(np.uint8); m = big_mask(m224, w, h); e = edges(m224)
        pos = pos_model(psess, img) if e is not None and e[3] >= 200 else None  # 접근 중엔 위치 막대 없음
        cv2.imwrite(str(OUT / f"{fid}_0raw.jpg"), img)
        cv2.imwrite(str(OUT / f"{fid}_A.jpg"), draw_A(img, m))
        cv2.imwrite(str(OUT / f"{fid}_B.jpg"), draw_B(img, m))
        cv2.imwrite(str(OUT / f"{fid}_C.jpg"), draw_C(img, m, e, pos))
        cv2.imwrite(str(OUT / f"{fid}_Clv.jpg"), draw_C(img, m, e, pos, low_vision=True))
        print(fid, "pos_model=%s" % (None if pos is None else round(pos, 2)), "seg_pos=%s" % (round(position(e), 2) if e else None),
              "visible=%s" % visible_sides(e), "cw=%.2f" % m224.mean())
