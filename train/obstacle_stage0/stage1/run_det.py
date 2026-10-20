# 1단계: T107 검출기 오프라인 추론 (학습 없음). criteria.md 규칙 그대로.
# 입력: crossings.csv(건너기 구간) + arrival_bollard.csv(볼라드 시각). 출력: dets.json
import csv, json, os, sys
import cv2, numpy as np, torch, torch.nn as nn
from torchvision.models.detection import ssdlite320_mobilenet_v3_large
from torchvision.models.detection.anchor_utils import DefaultBoxGenerator

ST = 'train/obstacle_stage0'; OUT = f'{ST}/stage1'
STEP = 0.25
torch.set_num_threads(4)


def build_model():
    # train_det_t107.py build_model과 같은 구조. 가중치는 곧바로 .pt로 덮으므로 COCO 다운로드 없이 만든다.
    m = ssdlite320_mobilenet_v3_large(weights=None, weights_backbone=None)
    ch = m.head.classification_head
    a_n = m.anchor_generator.num_anchors_per_location()
    for blk, na in zip(ch.module_list, a_n):
        conv = blk[-1]
        blk[-1] = nn.Conv2d(conv.in_channels, na * 3, kernel_size=conv.kernel_size, stride=conv.stride, padding=conv.padding)
    ch.num_columns = 3
    m.anchor_generator = DefaultBoxGenerator([[2, 3] for _ in range(6)], min_ratio=0.05, max_ratio=0.6)
    m.transform.fixed_size = (360, 480)
    m.load_state_dict(torch.load('model/obstacle_det_t107.pt', map_location='cpu'))
    return m.eval()


def to_input(f):
    """BGR 프레임 -> 360x480 RGB 텐서. 화면 녹화(세로)는 높이 맞춤+회색 패딩, h0(가로)는 853x480 후 가운데 자름."""
    h, w = f.shape[:2]
    rgb = cv2.cvtColor(f, cv2.COLOR_BGR2RGB)
    if h > w:
        nw = int(round(w * 480 / h))
        im = cv2.resize(rgb, (nw, 480), interpolation=cv2.INTER_AREA)
        can = np.full((480, 360, 3), 128, np.uint8); x0 = (360 - nw) // 2
        can[:, x0:x0 + nw] = im
    else:
        im = cv2.resize(rgb, (853, 480), interpolation=cv2.INTER_AREA)
        x0 = (853 - 360) // 2; can = im[:, x0:x0 + 360].copy()
    return torch.from_numpy(can).permute(2, 0, 1).float() / 255.0, can


def frames(path, t0, t1):
    cap = cv2.VideoCapture(path)
    if 'h0' not in path:
        cap.set(cv2.CAP_PROP_POS_MSEC, max(t0 - 1.5, 0) * 1000)
    nxt = t0
    while nxt <= t1:
        ok, f = cap.read()
        if not ok: break
        t = cap.get(cv2.CAP_PROP_POS_MSEC) / 1000
        if t < nxt: continue
        yield t, f
        nxt += STEP


def main():
    model = build_model()
    arr = {(r['영상'], r['건너기']): r for r in csv.DictReader(open(f'{ST}/arrival_bollard.csv', encoding='utf-8'))}
    res = []
    rows = [r for r in csv.DictReader(open(f'{ST}/crossings.csv', encoding='utf-8-sig')) if r['건너기 번호'] != '참고']
    for r in rows:
        v, n = r['영상'], r['건너기 번호']
        a, b = int(r['시작_ms']) / 1000, int(r['끝_ms']) / 1000
        ar = arr.get((v, n))
        if ar:
            try: b = max(b, float(ar['볼라드선도달_s']) + 0.5)
            except ValueError: pass
        fr = []
        for t, f in frames('videos/' + v, a, b):
            x, _ = to_input(f)
            with torch.no_grad():
                o = model([x])[0]
            keep = (o['labels'] == 1) & (o['scores'] >= 0.2)
            fr.append({'t': round(t, 3), 'det': [[*map(lambda z: round(float(z), 1), bx), round(float(s), 3)]
                                                 for bx, s in zip(o['boxes'][keep], o['scores'][keep])]})
        res.append({'video': v, 'n': n, 't0': a, 't1': b, 'frames': fr})
        print(v, n, len(fr), flush=True)
    json.dump(res, open(f'{OUT}/dets.json', 'w', encoding='utf-8'), ensure_ascii=False)


if __name__ == '__main__':
    main()
