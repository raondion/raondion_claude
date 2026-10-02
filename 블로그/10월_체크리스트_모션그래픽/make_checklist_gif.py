"""10월 체크리스트 모션그래픽 GIF 생성 스크립트.

체크박스 5개에 3초 간격으로 차례대로 체크 표시가 그려지고,
현재 항목을 가리키는 하이라이트가 아래로 이동한다.

실행: FONT_DIR=<Pretendard otf 폴더> python3 make_checklist_gif.py
"""
import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONT_DIR = os.environ.get("FONT_DIR", os.path.join(HERE, "fonts"))
OUT = os.path.join(HERE, "10월_체크리스트.gif")

W = H = 1080
SS = 2  # 슈퍼샘플링 배율 (부드러운 선)
FPS = 25

# DESIGN.md 브랜드 컬러
NAVY = (27, 42, 107)
GREEN = (76, 140, 60)
INK = (0, 0, 0)
MUTED = (107, 107, 107)

TITLE_POINT = "10월"
TITLE_REST = " 라온디온 체크리스트"
EYEBROW = "RAONDION  ·  OCTOBER TO-DO"
ITEMS = [
    "스마트스토어 오픈",
    "캔버스액자 3종 판매 시작",
    "스마트스토어 추가 상품 기획",
    "16일~18일 잇다장터 샘마루공원 부스참여",
    "28일~30일 특별휴가-엄마와 이모들 여행 가이드",
]

# 타임라인(초)
START = 1.0        # 첫 체크 시점
INTERVAL = 3.0     # 체크 간격
MOVE = 0.45        # 하이라이트 이동 시간
DRAW = 0.45        # 체크 그리기 시간
END_HOLD = 3.5     # 마지막 체크 후 유지 시간
TOTAL = START + INTERVAL * (len(ITEMS) - 1) + MOVE + DRAW + END_HOLD


def font(weight, size):
    return ImageFont.truetype(os.path.join(FONT_DIR, f"Pretendard-{weight}.otf"), size * SS)


def ease(t):
    t = max(0.0, min(1.0, t))
    return 1 - (1 - t) ** 3


def back_out(t):
    t = max(0.0, min(1.0, t))
    c = 1.9
    return 1 + (c + 1) * (t - 1) ** 3 + c * (t - 1) ** 2


# ---------------------------------------------------------------- 배경
def make_background():
    """웜 크림 그라데이션 + 창가 빛 + 은은한 가을 낙엽 일러스트."""
    w, h = W * SS, H * SS
    bg = Image.new("RGB", (w, h))
    px = bg.load()
    top, bottom = (250, 245, 236), (238, 228, 212)
    for y in range(h):
        k = y / h
        row = tuple(int(top[i] + (bottom[i] - top[i]) * k) for i in range(3))
        for x in range(w):
            px[x, y] = row
    bg = bg.convert("RGBA")

    # 창가 빛줄기 (대각선, 아주 옅게)
    light = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ld = ImageDraw.Draw(light)
    for i, off in enumerate((-300, 120, 520, 930)):
        o = off * SS
        bw = (150 if i % 2 == 0 else 90) * SS
        ld.polygon([(o, 0), (o + bw, 0), (o + bw - 700 * SS, h), (o - 700 * SS, h)],
                   fill=(255, 252, 240, 70))
    light = light.filter(ImageFilter.GaussianBlur(40 * SS))
    bg = Image.alpha_composite(bg, light)

    # 낙엽 (채도 낮은 톤, 가장자리에만)
    rnd = random.Random(7)
    palette = [(196, 140, 92), (176, 112, 78), (190, 160, 96), (140, 146, 98), (205, 170, 120)]
    leaves = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    spots = [(70, 60), (980, 110), (1030, 330), (40, 980), (160, 1040), (1000, 990), (880, 1050),
             (30, 420), (1050, 690), (260, 30), (620, 1060), (1060, 40)]
    for (cx, cy) in spots:
        size = rnd.uniform(60, 120)
        ang = rnd.uniform(0, 360)
        col = rnd.choice(palette)
        draw_leaf(leaves, cx * SS, cy * SS, size * SS, ang, col + (150,))
    shadow = leaves.copy().filter(ImageFilter.GaussianBlur(8 * SS))
    sh = Image.new("RGBA", (w, h), (90, 60, 30, 0))
    sh.putalpha(shadow.getchannel("A").point(lambda a: a * 0.25))
    bg = Image.alpha_composite(bg, sh.transform(sh.size, Image.AFFINE, (1, 0, -6 * SS, 0, 1, -8 * SS)))
    bg = Image.alpha_composite(bg, leaves.filter(ImageFilter.GaussianBlur(1.2 * SS)))

    # 텍스트 영역만 국소적으로 밝게
    glow = Image.new("L", (w, h), 0)
    ImageDraw.Draw(glow).rounded_rectangle([110 * SS, 120 * SS, 970 * SS, 960 * SS], 120 * SS, fill=150)
    glow = glow.filter(ImageFilter.GaussianBlur(70 * SS))
    white = Image.new("RGBA", (w, h), (255, 253, 248, 255))
    white.putalpha(glow)
    bg = Image.alpha_composite(bg, white)
    return bg


def draw_leaf(layer, cx, cy, size, angle, color):
    leaf = Image.new("RGBA", (int(size * 2.4), int(size * 2.4)), (0, 0, 0, 0))
    d = ImageDraw.Draw(leaf)
    c = size * 1.2

    def half_width(t):  # t: 0(잎끝) ~ pi(잎자루) — 양 끝이 뾰족하고 아랫부분이 넓은 잎
        return 0.40 * math.sin(t) ** 1.4 * (1 + 0.35 * math.cos(t - math.pi))

    top = [(c + math.cos(t) * size, c - half_width(t) * size)
           for t in (i / 59 * math.pi for i in range(60))]
    bottom = [(x, 2 * c - y) for x, y in reversed(top)]
    d.polygon(top + bottom, fill=color)
    vein = tuple(min(255, v + 40) for v in color[:3]) + (170,)
    d.line([(c - size * 1.35, c), (c + size * 0.95, c)], fill=color[:3] + (200,), width=max(2, int(size / 22)))
    d.line([(c - size, c), (c + size * 0.9, c)], fill=vein, width=max(2, int(size / 28)))
    for k in (-0.55, -0.15, 0.25, 0.6):
        x0 = c + k * size
        for sgn in (-1, 1):
            d.line([(x0, c), (x0 + size * 0.22, c + sgn * size * 0.24)], fill=vein, width=max(1, int(size / 45)))
    leaf = leaf.rotate(angle, resample=Image.BICUBIC, expand=False)
    layer.alpha_composite(leaf, (int(cx - c), int(cy - c)))


# ---------------------------------------------------------------- 레이아웃
TITLE_Y = 196
EYEBROW_Y = 150
ROW_Y0 = 400
ROW_GAP = 112
BOX_X = 128
BOX = 54
TEXT_X = BOX_X + BOX + 30
PROG_Y = 300
PROG_X0, PROG_X1 = 128, 952


def fit_item_font():
    limit = (W - 80 - TEXT_X) * SS
    for size in range(40, 20, -1):
        f = font("Bold", size)
        if max(f.getlength(t) for t in ITEMS) <= limit:
            return f, size
    return font("Bold", 20), 20


ITEM_FONT, ITEM_SIZE = fit_item_font()


def row_center(i):
    return ROW_Y0 + i * ROW_GAP


def render(t, bg):
    s = SS
    img = bg.copy()
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    # 상태 계산
    step_times = [START + INTERVAL * k for k in range(len(ITEMS))]
    # 하이라이트 위치
    cur = -1
    for k, st in enumerate(step_times):
        if t >= st:
            cur = k
    if cur < 0:
        hl_y = row_center(0) - ROW_GAP * 0.6
        hl_alpha = ease(t / START)
    else:
        prev_y = row_center(cur - 1) if cur > 0 else row_center(0) - ROW_GAP * 0.6
        hl_y = prev_y + (row_center(cur) - prev_y) * ease((t - step_times[cur]) / MOVE)
        hl_alpha = 1.0
    final_t = step_times[-1] + MOVE + DRAW
    if t > final_t:
        hl_alpha = 1 - ease((t - final_t) / 0.6)

    # 이동하는 하이라이트 (부드러운 빛 띠 + 네이비 포인트 바)
    if hl_alpha > 0:
        band = Image.new("L", img.size, 0)
        ImageDraw.Draw(band).rounded_rectangle(
            [(BOX_X - 34) * s, (hl_y - 46) * s, (W - 70) * s, (hl_y + 46) * s], 46 * s,
            fill=int(255 * hl_alpha))
        band = band.filter(ImageFilter.GaussianBlur(10 * s))
        wl = Image.new("RGBA", img.size, (255, 255, 255, 255))
        wl.putalpha(band)
        img = Image.alpha_composite(img, wl)
        d.rounded_rectangle([(BOX_X - 30) * s, (hl_y - 26) * s, (BOX_X - 24) * s, (hl_y + 26) * s],
                            3 * s, fill=NAVY + (int(255 * hl_alpha),))

    # 상단 문구
    f_eye = font("SemiBold", 20)
    d.text((PROG_X0 * s, EYEBROW_Y * s), EYEBROW, font=f_eye, fill=GREEN + (255,), anchor="lm")
    f_title = font("ExtraBold", 58)
    d.text((PROG_X0 * s, TITLE_Y * s), TITLE_POINT, font=f_title, fill=NAVY + (255,), anchor="lm")
    d.text((PROG_X0 * s + f_title.getlength(TITLE_POINT), TITLE_Y * s), TITLE_REST,
           font=f_title, fill=INK + (255,), anchor="lm")

    # 진행 바 + 카운터
    done = 0.0
    for st in step_times:
        done += ease((t - st - MOVE) / DRAW)
    frac = done / len(ITEMS)
    d.rounded_rectangle([PROG_X0 * s, (PROG_Y - 4) * s, (PROG_X1 - 110) * s, (PROG_Y + 4) * s], 4 * s,
                        fill=(0, 0, 0, 28))
    if frac > 0:
        x1 = PROG_X0 + (PROG_X1 - 110 - PROG_X0) * frac
        d.rounded_rectangle([PROG_X0 * s, (PROG_Y - 4) * s, max(PROG_X0 + 8, x1) * s, (PROG_Y + 4) * s],
                            4 * s, fill=GREEN + (255,))
    count = sum(1 for st in step_times if t >= st + MOVE + DRAW * 0.5)
    f_cnt = font("Bold", 30)
    f_cnt_l = font("Medium", 30)
    tail = f" / {len(ITEMS)}"
    d.text((PROG_X1 * s, PROG_Y * s), tail, font=f_cnt_l, fill=MUTED + (255,), anchor="rm")
    d.text((PROG_X1 * s - f_cnt_l.getlength(tail), PROG_Y * s), str(count), font=f_cnt,
           fill=NAVY + (255,), anchor="rm")

    # 체크리스트
    for i, label in enumerate(ITEMS):
        cy = row_center(i)
        p = (t - step_times[i] - MOVE) / DRAW  # 체크 진행도
        checked = p > 0
        pop = 1.0
        if 0 < p < 1.6:
            pop = 1 + 0.14 * math.sin(min(1.0, p / 1.6) * math.pi)
        half = BOX / 2 * pop
        x0, y0, x1, y1 = (BOX_X + BOX / 2 - half), (cy - half), (BOX_X + BOX / 2 + half), (cy + half)
        if checked:
            fill_a = ease(p * 2)
            d.rounded_rectangle([x0 * s, y0 * s, x1 * s, y1 * s], 12 * s,
                                fill=GREEN + (int(255 * fill_a),), outline=GREEN + (255,), width=3 * s)
            draw_check(d, BOX_X + BOX / 2, cy, BOX * pop, min(1.0, p))
        else:
            d.rounded_rectangle([x0 * s, y0 * s, x1 * s, y1 * s], 12 * s,
                                fill=(255, 255, 255, 220), outline=(40, 40, 40, 255), width=3 * s)
        is_cur = (i == cur) and hl_alpha > 0.5
        color = INK if (is_cur or not checked) else (60, 60, 60)
        d.text((TEXT_X * s, cy * s), label, font=ITEM_FONT, fill=color + (255,), anchor="lm")

    # 마무리 문구
    if t > final_t + 0.2:
        a = ease((t - final_t - 0.2) / 0.7)
        f_end = font("Bold", 30)
        msg = "10월도 꼼꼼하게, 한 칸씩 채워갑니다"
        oy = (1 - a) * 14
        d.text((W / 2 * s, (958 + oy) * s), msg, font=f_end, fill=NAVY + (int(255 * a),), anchor="mm")

    img = Image.alpha_composite(img, layer)
    return img.resize((W, H), Image.LANCZOS).convert("RGB")


def draw_check(d, cx, cy, size, p):
    s = SS
    a = (cx - size * 0.26, cy + size * 0.01)
    b = (cx - size * 0.07, cy + size * 0.20)
    c = (cx + size * 0.28, cy - size * 0.19)
    l1 = math.dist(a, b)
    l2 = math.dist(b, c)
    L = (l1 + l2) * p
    pts = [a]
    if L <= l1:
        k = L / l1
        pts.append((a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k))
    else:
        k = (L - l1) / l2
        pts += [b, (b[0] + (c[0] - b[0]) * k, b[1] + (c[1] - b[1]) * k)]
    width = int(size * 0.13 * s)
    d.line([(x * s, y * s) for x, y in pts], fill=(255, 255, 255, 255), width=width, joint="curve")
    r = width / 2
    for x, y in (pts[0], pts[-1]):
        d.ellipse([x * s - r, y * s - r, x * s + r, y * s + r], fill=(255, 255, 255, 255))


def main():
    bg = make_background()
    n = int(TOTAL * FPS)
    frames, durations = [], []
    palette_src = render(TOTAL - 0.01, bg)
    pal = palette_src.quantize(colors=255, method=Image.MEDIANCUT)
    for f in range(n):
        t = f / FPS
        im = render(t, bg).quantize(palette=pal, dither=Image.NONE)
        if frames and im.tobytes() == frames[-1].tobytes():
            durations[-1] += 1000 // FPS
            continue
        frames.append(im)
        durations.append(1000 // FPS)
    frames[0].save(OUT, save_all=True, append_images=frames[1:], duration=durations,
                   loop=0, optimize=False, disposal=1)
    print(f"{OUT}: {len(frames)} frames, {TOTAL:.1f}s, item font {ITEM_SIZE}px, "
          f"{os.path.getsize(OUT) / 1024:.0f} KB")


if __name__ == "__main__":
    main()
