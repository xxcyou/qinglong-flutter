"""青龙图标生成器：一条由菱形拼出来的龙，泛绿幽冷光，纯 SVG。

设计约束（图标最小要在 48px 下认得出来）：
  * 菱形要沿身体切线转向，才像一节节鳞甲，而不是撒了一地方块；
  * 数量宁少勿多，缩到 48px 时相邻菱形之间必须还留得下缝；
  * 光晕靠"放大的半透明同形"叠出来，不用 SVG filter——
    cairosvg / Android VectorDrawable / 浏览器对滤镜支持参差不齐，
    几何叠加在哪儿画出来都一模一样。
几何全部算出来再写进 SVG：手搓路径改一次尺寸就得全推一遍。
"""
import math

# ---------- 贝塞尔 ----------
def bez(p0, p1, p2, p3, t):
    u = 1 - t
    return (u**3*p0[0] + 3*u*u*t*p1[0] + 3*u*t*t*p2[0] + t**3*p3[0],
            u**3*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t**3*p3[1])

def bez_d(p0, p1, p2, p3, t):
    u = 1 - t
    return (3*u*u*(p1[0]-p0[0]) + 6*u*t*(p2[0]-p1[0]) + 3*t*t*(p3[0]-p2[0]),
            3*u*u*(p1[1]-p0[1]) + 6*u*t*(p2[1]-p1[1]) + 3*t*t*(p3[1]-p2[1]))

# 龙身走一个 S：尾巴左下 → 贴底右扫 → 回卷向左上 → 昂头到右上。
# S 形比 C 形耐看，也让"头"和"尾"分处两个对角，缩小后仍能看出朝向。
SEGS = [
    ((120, 430), (176, 474), (296, 452), (322, 356)),
    ((322, 356), (348, 262), (206, 292), (196, 214)),
    ((196, 214), (188, 150), (268, 108), (344, 140)),
]

def _flat(steps=600):
    """把三段贝塞尔压成一串点 + 累计弧长，用于等距重采样。"""
    pts = []
    for si, p in enumerate(SEGS):
        for i in range(steps):
            t = i / steps
            if si and i == 0:
                continue
            pts.append(bez(*p, t))
    pts.append(bez(*SEGS[-1], 1.0))
    acc = [0.0]
    for i in range(1, len(pts)):
        acc.append(acc[-1] + math.dist(pts[i - 1], pts[i]))
    return pts, acc


def sample(n):
    """沿曲线**等弧长**取 n 个点 → (x, y, 切线角)。

    不能按 t 均分：贝塞尔的 t 和弧长不成比例，均分 t 会让弯处的鳞片挤成一坨、
    直处又拉开一道缝，看起来就是"拼歪了"。等弧长取点才是均匀的一节节。
    """
    pts, acc = _flat()
    total = acc[-1]
    out = []
    j = 0
    for i in range(n):
        target = total * i / (n - 1)
        while j < len(acc) - 2 and acc[j + 1] < target:
            j += 1
        x, y = pts[j]
        k = min(j + 1, len(pts) - 1)
        dx, dy = pts[k][0] - pts[max(j - 1, 0)][0], pts[k][1] - pts[max(j - 1, 0)][1]
        out.append((x, y, math.atan2(dy, dx)))
    return out, total / (n - 1)


def dia(cx, cy, ang, rl, rs):
    """菱形四顶点：长轴顺 ang，短轴垂直。"""
    ca, sa = math.cos(ang), math.sin(ang)
    return [(cx + ca*rl, cy + sa*rl), (cx - sa*rs, cy + ca*rs),
            (cx - ca*rl, cy - sa*rl), (cx + sa*rs, cy - ca*rs)]

def girth(k, step):
    """身体半长轴：尾细头粗，且始终 ≥ 半个间距——相邻鳞片首尾相接。

    只按 k 定大小的话，尾巴那几节会被间距拉散成一串独立方块；
    绑定 step 之后，无论取多少节、曲线怎么改，龙身都是连着的。
    """
    return step * (0.62 + 0.42 * k**0.75)

# ---------- 拼装 ----------
def build():
    """→ (shapes, eye)。shapes 项 = (顶点表, 亮度 0..1, 描边基准)。"""
    body, step = sample(15)    # 15 节：48px 下每节约 3px，缝还看得见
    out = []

    for i, (x, y, a) in enumerate(body):
        k = i / (len(body) - 1)
        rl = girth(k, step)
        out.append((dia(x, y, a, rl, rl*0.66), 0.28 + 0.52*k, rl))

    # 背鳍：沿外法线挑一排小菱形，尖端朝外 —— 龙脊。
    for i in range(2, len(body) - 1, 2):
        x, y, a = body[i]
        k = i / (len(body) - 1)
        rl = girth(k, step)
        nx, ny = math.sin(a), -math.cos(a)
        d = rl * 1.42
        out.append((dia(x + nx*d, y + ny*d, a + math.pi/2, rl*0.66, rl*0.24),
                    0.5 + 0.4*k, rl*0.5))

    # 爪：腹侧两对，每对两颗。再多在 48px 下会和身子糊成一片。
    for i in (5, 11):
        x, y, a = body[i]
        k = i / (len(body) - 1)
        rl = girth(k, step)
        nx, ny = -math.sin(a), math.cos(a)
        for dd, sc in ((1.30, 0.52), (2.10, 0.30)):
            out.append((dia(x + nx*rl*dd, y + ny*rl*dd, a + math.pi/2,
                            rl*sc, rl*sc*0.52), 0.38 + 0.26*k, rl*sc))

    # 头：颅 + 吻 + 双角 + 颌。整体比脖子大一号，轮廓才立得住。
    hx, hy, ha = body[-1]
    ca, sa = math.cos(ha), math.sin(ha)
    nx, ny = math.sin(ha), -math.cos(ha)
    skull = (hx + ca*20, hy + sa*20)
    out.append((dia(*skull, ha, 56, 33), 1.0, 56))
    out.append((dia(skull[0] + ca*66, skull[1] + sa*66, ha, 26, 13), 0.9, 26))
    for side, lean in ((1, 0.30), (-1, 0.62)):
        bx = skull[0] - ca*26 + nx*24*side
        by = skull[1] - sa*26 + ny*24*side
        out.append((dia(bx, by, ha + math.pi - lean*side, 36, 9), 0.86, 36))
    out.append((dia(skull[0] + ca*34 - nx*26, skull[1] + sa*34 - ny*26,
                    ha, 25, 10), 0.66, 25))

    eye = dia(skull[0] + ca*12 + nx*3, skull[1] + sa*12 + ny*3,
              ha + math.pi/2, 12, 7)
    return out, eye

def fit(shapes, eye, box):
    """等比缩放 + 居中到 box=(x0,y0,x1,y1)。

    先摆几何再自适应装框：调曲线时不用手动重算每个坐标，
    也保证前景版（自适应图标要留安全区）和整图版用的是同一套形状。
    """
    pts = [p for s in shapes for p in s[0]] + list(eye)
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    x0, y0, x1, y1 = box
    k = min((x1-x0)/(max(xs)-min(xs)), (y1-y0)/(max(ys)-min(ys)))
    dx = x0 + ((x1-x0) - (max(xs)-min(xs))*k)/2 - min(xs)*k
    dy = y0 + ((y1-y0) - (max(ys)-min(ys))*k)/2 - min(ys)*k
    m = lambda ps: [(p[0]*k+dx, p[1]*k+dy) for p in ps]
    return [(m(s[0]), s[1], s[2]*k) for s in shapes], m(eye)

def poly(pts, f=1.0):
    cx = sum(p[0] for p in pts)/len(pts)
    cy = sum(p[1] for p in pts)/len(pts)
    return ' '.join(f'{cx+(x-cx)*f:.2f},{cy+(y-cy)*f:.2f}' for x, y in pts)

def svg(size=512, background=True, inset=0.055):
    shapes, eye = build()
    m = size * inset
    shapes, eye = fit(shapes, eye, (m, m, size-m, size-m))
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" '
         f'height="{size}" viewBox="0 0 {size} {size}">', '<defs>',
         # 冷光渐变：尾墨绿 → 头近白青绿，方向顺着龙身走。
         '<linearGradient id="s" x1="0.08" y1="0.95" x2="0.8" y2="0.08">',
         '<stop offset="0" stop-color="#0a5f47"/>',
         '<stop offset="0.4" stop-color="#10b481"/>',
         '<stop offset="0.78" stop-color="#4dffc6"/>',
         '<stop offset="1" stop-color="#d6fff2"/>', '</linearGradient>',
         '<linearGradient id="b" x1="0" y1="0" x2="0.4" y2="1">',
         '<stop offset="0" stop-color="#04150f"/>',
         '<stop offset="0.55" stop-color="#07241b"/>',
         '<stop offset="1" stop-color="#010b08"/>', '</linearGradient>',
         '<radialGradient id="h" cx="0.5" cy="0.48" r="0.5">',
         '<stop offset="0" stop-color="#25ffb5" stop-opacity="0.20"/>',
         '<stop offset="0.6" stop-color="#0fce8f" stop-opacity="0.07"/>',
         '<stop offset="1" stop-color="#00d89a" stop-opacity="0"/>',
         '</radialGradient>', '</defs>']
    if background:
        r = size*0.235
        o.append(f'<rect width="{size}" height="{size}" rx="{r:.2f}" '
                 f'ry="{r:.2f}" fill="url(#b)"/>')
        o.append(f'<rect width="{size}" height="{size}" rx="{r:.2f}" '
                 f'ry="{r:.2f}" fill="url(#h)"/>')
    else:
        o.append(f'<rect width="{size}" height="{size}" fill="url(#h)"/>')
    # 一层外扩光晕就够：叠两层会把整块画布糊成一片绿雾，菱形的棱就没了。
    for pts, lum, _w in shapes:
        o.append(f'<polygon points="{poly(pts, 1.26)}" fill="#2effbb" '
                 f'opacity="{0.07 + 0.07*lum:.3f}"/>')
    for pts, lum, w in shapes:
        o.append(f'<polygon points="{poly(pts)}" fill="url(#s)" '
                 f'opacity="{0.62 + 0.38*lum:.3f}" stroke="#e2fff7" '
                 f'stroke-opacity="{0.30 + 0.45*lum:.3f}" '
                 f'stroke-width="{max(1.0, w*0.05):.2f}" '
                 f'stroke-linejoin="round"/>')
    o.append(f'<polygon points="{poly(eye, 2.4)}" fill="#eafff9" opacity="0.25"/>')
    o.append(f'<polygon points="{poly(eye)}" fill="#f4fffc"/>')
    o.append('</svg>')
    return '\n'.join(o)

# ---------- Android 产物 ----------
def path_data(shapes, eye):
    """把菱形折线导成 VectorDrawable 的 path data（单色主题图标用）。"""
    out = []
    for pts, _lum, _w in shapes + [(eye, 1.0, 0.0)]:
        head = f'M{pts[0][0]:.1f},{pts[0][1]:.1f}'
        rest = ''.join(f'L{x:.1f},{y:.1f}' for x, y in pts[1:])
        out.append(f'{head}{rest}Z')
    return ' '.join(out)


def monochrome(size=108, inset=0.19):
    """Android 13 主题图标：系统只取形状，颜色由系统换。

    所以这里必须是纯色实心的菱形轮廓——渐变、光晕、描边全都会被丢掉，
    留着只会让形状变糊。
    """
    shapes, eye = build()
    m = size * inset
    shapes, eye = fit(shapes, eye, (m, m, size - m, size - m))
    return (
        f'<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
        f'    android:width="{size}dp" android:height="{size}dp"\n'
        f'    android:viewportWidth="{size}" android:viewportHeight="{size}">\n'
        f'  <path android:fillColor="#FFFFFFFF" android:fillType="nonZero"\n'
        f'      android:pathData="{path_data(shapes, eye)}"/>\n'
        f'</vector>\n'
    )


def background_vector(size=108):
    """自适应图标的背景层：墨绿渐变 + 一圈幽光。

    背景层会被系统裁成圆/圆角矩形，所以不能画任何有意义的形状，
    只铺颜色——形状全部交给前景层。
    """
    return (
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    xmlns:aapt="http://schemas.android.com/aapt"\n'
        f'    android:width="{size}dp" android:height="{size}dp"\n'
        f'    android:viewportWidth="{size}" android:viewportHeight="{size}">\n'
        f'  <path android:pathData="M0,0h{size}v{size}h-{size}z">\n'
        '    <aapt:attr name="android:fillColor">\n'
        f'      <gradient android:type="linear" android:startX="0" android:startY="0"\n'
        f'          android:endX="{size * 0.4:.1f}" android:endY="{size}">\n'
        '        <item android:offset="0" android:color="#FF04150F"/>\n'
        '        <item android:offset="0.55" android:color="#FF07241B"/>\n'
        '        <item android:offset="1" android:color="#FF010B08"/>\n'
        '      </gradient>\n'
        '    </aapt:attr>\n'
        '  </path>\n'
        f'  <path android:pathData="M0,0h{size}v{size}h-{size}z">\n'
        '    <aapt:attr name="android:fillColor">\n'
        f'      <gradient android:type="radial" android:centerX="{size / 2:.1f}"\n'
        f'          android:centerY="{size * 0.48:.1f}" android:gradientRadius="{size * 0.5:.1f}">\n'
        '        <item android:offset="0" android:color="#3325FFB5"/>\n'
        '        <item android:offset="0.6" android:color="#120FCE8F"/>\n'
        '        <item android:offset="1" android:color="#0000D89A"/>\n'
        '      </gradient>\n'
        '    </aapt:attr>\n'
        '  </path>\n'
        '</vector>\n'
    )


ADAPTIVE = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
    '  <background android:drawable="@drawable/ic_launcher_background"/>\n'
    '  <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
    '  <monochrome android:drawable="@drawable/ic_launcher_monochrome"/>\n'
    '</adaptive-icon>\n'
)

# 传统图标（mipmap-*/ic_launcher.png）与自适应前景层（108dp）的像素尺寸。
DENSITIES = {
    'mdpi': (48, 108),
    'hdpi': (72, 162),
    'xhdpi': (96, 216),
    'xxhdpi': (144, 324),
    'xxxhdpi': (192, 432),
}


def export(res_dir, art_dir, render):
    """写出全部产物。[render] = (svg_text, px, out_path) -> None，由调用方注入
    栅格化实现，这个模块本身不依赖任何图形库。"""
    import os

    os.makedirs(art_dir, exist_ok=True)
    full = svg(512, True, 0.055)
    fg = svg(512, False, 0.19)
    open(os.path.join(art_dir, 'app_icon.svg'), 'w', encoding='utf-8').write(full)
    open(os.path.join(art_dir, 'app_icon_foreground.svg'), 'w',
         encoding='utf-8').write(fg)

    drawable = os.path.join(res_dir, 'drawable')
    os.makedirs(drawable, exist_ok=True)
    open(os.path.join(drawable, 'ic_launcher_background.xml'), 'w',
         encoding='utf-8').write(background_vector())
    open(os.path.join(drawable, 'ic_launcher_monochrome.xml'), 'w',
         encoding='utf-8').write(monochrome())

    anydpi = os.path.join(res_dir, 'mipmap-anydpi-v26')
    os.makedirs(anydpi, exist_ok=True)
    for name in ('ic_launcher.xml', 'ic_launcher_round.xml'):
        open(os.path.join(anydpi, name), 'w', encoding='utf-8').write(ADAPTIVE)

    written = []
    for dpi, (legacy, fgpx) in DENSITIES.items():
        d = os.path.join(res_dir, f'mipmap-{dpi}')
        os.makedirs(d, exist_ok=True)
        for text, px, name in (
            (full, legacy, 'ic_launcher.png'),
            (full, legacy, 'ic_launcher_round.png'),
            (fg, fgpx, 'ic_launcher_foreground.png'),
        ):
            out = os.path.join(d, name)
            render(text, px, out)
            written.append(out)
    return written


def _render_with_cairosvg(text, px, out):
    import cairosvg

    cairosvg.svg2png(bytestring=text.encode('utf-8'), write_to=out,
                     output_width=px, output_height=px)


if __name__ == '__main__':
    import os
    import sys

    a = sys.argv[1] if len(sys.argv) > 1 else 'export'
    if a == 'full':
        print(svg(512, True, 0.055))
    elif a == 'fg':
        # 自适应前景：内容压到中间 ~62%，避开系统裁切的安全区。
        print(svg(512, False, 0.19))
    else:
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        files = export(
            os.path.join(root, 'android', 'app', 'src', 'main', 'res'),
            os.path.join(root, 'art'),
            _render_with_cairosvg,
        )
        print(f'wrote {len(files)} files')
