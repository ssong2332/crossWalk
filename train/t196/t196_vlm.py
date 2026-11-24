"""T196: 11/18 젖은 야간 횡단보도 36장 -> 로컬 VLM 1차 분류 -> 사용자 확인표(review.html).

대상: train/field_1118/report.md 8-4절 39장 중 앞 2장(연석에서 내려섬)·끝 1장(되돌아섬)을 뺀 36장.
      사용자 확인으로 모두 '횡단보도 안'에 선 순간이다.
질문: 노면 모델(T105, 9클래스 분할)의 '발 앞 영역'(똑바로 세운 사진의 가로 가운데 1/3 x 아래 1/2)이
      어느 클래스여야 하는가. 이 장면에 나올 수 있는 클래스만 고른다:
        3 crosswalk(횡단보도) / 2 roadway(차도) / 1 sidewalk(인도) / 0 unclear(판단 불가)
      번호·이름은 train/seg_cache_t105.py CLASS_NAMES와 같다.
VLM: Qwen3-VL-4B Q4_K_M, llama-server 127.0.0.1:8193 전용 (T193 방식). 사진은 외부로 보내지 않는다.
확신: 답 글자의 토큰 확률(top_logprobs). 0.7 미만이면 '확신 낮음'.

실행 (워크트리 루트): PYTHONIOENCODING=utf-8 python train/t196/t196_vlm.py
출력: train/t196/vlm.csv (이어서 돌리기 가능), train/t196/review.html (사진은 file:// 경로로만 참조, 내장 안 함)
"""
import base64, csv, io, json, math, os, re, sys, time, urllib.request
from pathlib import Path
from PIL import Image

HERE = Path(__file__).resolve().parent
DATA = Path(os.environ.get("T196_DATA_ROOT", "C:/vibecoding/crossWalk"))
FRAMES = DATA / "train" / "frames_1118"
URL = "http://127.0.0.1:8193/v1/chat/completions"
SIDE = 512  # T193과 같은 긴 변
LOW = 0.7
CHOICES = {"A": "crosswalk", "B": "roadway", "C": "sidewalk", "D": "unclear"}
PROMPT = (
    "This photo was taken at night in the rain by a phone worn on the chest of a pedestrian, facing forward. "
    "The bottom of the image is the ground right at the pedestrian's feet.\n"
    "Look only at the ground in the bottom half of the image, middle third horizontally. "
    "What surface is that ground?\n"
    "A) part of a pedestrian crosswalk: white zebra stripes, or the asphalt between or beside the stripes inside the crosswalk\n"
    "B) a road for cars with no crosswalk markings there\n"
    "C) a sidewalk, curb or paving tiles\n"
    "D) cannot tell\n"
    "Answer with one letter."
)


def targets(report_text):
    """8-4절 코드 블록의 39장에서 앞 2장·끝 1장을 뺀 36장 (★ 표시 = '차도입니다' 순간 가장 가까운 장)."""
    sec = report_text.split("### 8-4.", 1)[1].split("### 8-5.", 1)[0]
    block = re.search(r"```\n(.*?)```", sec, re.S).group(1)
    names = re.findall(r"(★?)(f_\d+\.jpg)", block)
    assert len(names) == 39, len(names)
    return [(f, bool(s)) for s, f in names[2:-1]]


def pick(top):
    """top_logprobs -> (글자, 확률). 글자별 확률을 합친다(' A', 'A' 등)."""
    p = {}
    for t in top:
        k = t["token"].strip().rstrip(")").upper()
        if k in CHOICES:
            p[k] = p.get(k, 0.0) + math.exp(t["logprob"])
    if not p:
        return "D", 0.0
    k = max(p, key=p.get)
    return k, p[k]


def ask(path):
    im = Image.open(path).convert("RGB").transpose(Image.Transpose.ROTATE_270)  # 시계방향 90° = 똑바로 (T193과 같음)
    im.thumbnail((SIDE, SIDE))
    buf = io.BytesIO(); im.save(buf, "JPEG", quality=90)
    b64 = base64.b64encode(buf.getvalue()).decode()
    body = {"temperature": 0, "max_tokens": 1, "logprobs": True, "top_logprobs": 10,
            "messages": [{"role": "user", "content": [
                {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + b64}},
                {"type": "text", "text": PROMPT}]}]}
    req = urllib.request.Request(URL, json.dumps(body).encode(), {"Content-Type": "application/json"})
    ch = json.load(urllib.request.urlopen(req, timeout=600))["choices"][0]
    return ch["message"]["content"].strip(), pick(ch["logprobs"]["content"][0]["top_logprobs"])


def ts(f):
    ms = int(f[2:-4])
    return time.strftime("%H:%M:%S", time.localtime(ms / 1000)) + f".{ms % 1000 // 100}"


def html(rows):
    data = json.dumps([{"file": r["file"], "time": ts(r["file"]), "star": r["star"] == "1",
                        "vlm": r["vlm"], "conf": float(r["conf"]),
                        "src": (FRAMES / r["file"]).as_uri()} for r in rows], ensure_ascii=False)
    return (HERE / "review_template.html").read_text(encoding="utf-8").replace("/*DATA*/[]", data)


if __name__ == "__main__":
    assert pick([{"token": " A", "logprob": math.log(0.6)}, {"token": "A", "logprob": math.log(0.2)},
                 {"token": "B", "logprob": math.log(0.2)}]) == ("A", 0.8)
    assert pick([{"token": "x", "logprob": 0.0}]) == ("D", 0.0)
    tg = targets((DATA / "train" / "field_1118" / "report.md").read_text(encoding="utf-8"))
    assert len(tg) == 36 and tg[0][0] == "f_1794994786705.jpg" and tg[-1][0] == "f_1794994822811.jpg"
    assert sum(s for _, s in tg) == 4
    out_p = HERE / "vlm.csv"
    done = {r["file"]: r for r in csv.DictReader(open(out_p, encoding="utf-8-sig"))} if out_p.exists() else {}
    rows = []
    for i, (f, star) in enumerate(tg):
        if f not in done:
            t0 = time.perf_counter()
            raw, (k, p) = ask(FRAMES / f)
            done[f] = dict(file=f, star=int(star), raw=raw, vlm=CHOICES[k], conf=round(p, 3),
                           ms=round((time.perf_counter() - t0) * 1000))
            print(i, f, done[f]["vlm"], done[f]["conf"], done[f]["ms"], "ms", flush=True)
        rows.append(done[f])
        with open(out_p, "w", newline="", encoding="utf-8-sig") as fp:
            w = csv.DictWriter(fp, fieldnames=["file", "star", "raw", "vlm", "conf", "ms"]); w.writeheader(); w.writerows(rows)
    rows = list(csv.DictReader(open(out_p, encoding="utf-8-sig")))
    (HERE / "review.html").write_text(html(rows), encoding="utf-8")
    dist = {}
    for r in rows:
        dist[r["vlm"]] = dist.get(r["vlm"], 0) + 1
    print("분포", dist, "확신 낮음(<%.1f)" % LOW, sum(float(r["conf"]) < LOW for r in rows), "/", len(rows))
