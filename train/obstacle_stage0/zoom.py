# 의심 구간 0.5초 간격 확대 시트 (추론 없음)
import cv2, sys, os, numpy as np
def wr(p, im): open(p, 'wb').write(cv2.imencode('.jpg', im, [cv2.IMWRITE_JPEG_QUALITY, 85])[1].tobytes())
def zoom(path, t0, t1, step=0.5, cols=8, tag=''):
    cap = cv2.VideoCapture(path); cap.set(cv2.CAP_PROP_POS_MSEC, max(t0 - 1.5, 0) * 1000)
    nxt = t0; tiles = []
    while nxt <= t1:
        ok, f = cap.read()
        if not ok: break
        ms = cap.get(cv2.CAP_PROP_POS_MSEC)
        if ms / 1000 < nxt: continue
        h, w = f.shape[:2]; tw = 270 if h > w else 400; th = int(h * tw / w)
        if h > w: f = f[:int(h * 0.78)]; th = int(f.shape[0] * tw / w)  # 아래 정보 패널 제외
        im = cv2.resize(f, (tw, th), interpolation=cv2.INTER_AREA)
        cv2.line(im, (tw // 3, 0), (tw // 3, th), (0, 255, 255), 1); cv2.line(im, (2 * tw // 3, 0), (2 * tw // 3, th), (0, 255, 255), 1)
        cv2.rectangle(im, (0, 0), (tw, 22), (0, 0, 0), -1); cv2.putText(im, f'{ms/1000:.1f}s', (3, 16), 0, 0.55, (255, 255, 255), 1)
        tiles.append(im); nxt += step
    while len(tiles) % cols: tiles.append(np.zeros_like(tiles[0]))
    grid = np.vstack([np.hstack(tiles[r * cols:(r + 1) * cols]) for r in range(len(tiles) // cols)])
    name = os.path.splitext(os.path.basename(path))[0]
    out = f'train/obstacle_stage0/sheets/zoom_{name}_{t0:g}-{t1:g}.jpg'; wr(out, grid); print(out)
if __name__ == '__main__':
    for spec in sys.argv[1:]:
        p, a, b = spec.split(','); zoom(p, float(a), float(b))
