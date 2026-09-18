#!/usr/bin/env python3
"""生成 iOS App 图标 AppIcon.png（1024x1024，纯标准库）。

设计：扁平的橙色底 + 白色舞者剪影（双臂上举、双腿叉开）。
用带符号距离场(SDF)画圆角和胶囊线段，边缘自带 1px 羽化，缩到 60px 也不会毛糙。

iOS 图标的硬性要求（踩过坑所以写在这）：
  - 必须是**正方形**，且**不能有透明通道**，也不能自己画圆角 —— 系统会统一裁形；
    自带圆角或透明边缘的图标在桌面上会露出难看的白边。
  - 文件名必须与 Assets.xcassets/AppIcon.appiconset/Contents.json 里引用的名字一致，
    否则 actool 会因为「找不到匹配的 App 图标」直接构建失败。
"""

import os
import struct
import zlib

SIZE = 1024

BG = (0xFF, 0x6B, 0x35)   # 品牌橙 #FF6B35
FG = (0xFF, 0xFF, 0xFF)

OUT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "DanceAlarm", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png",
)

# 画面缓冲：RGB 三通道，先铺底色
canvas = bytearray()
for _ in range(SIZE * SIZE):
    canvas += bytes(BG)


def blend_pixel(x, y, color, alpha):
    """把 color 以 alpha(0..1) 混合到 (x, y)。"""
    if alpha <= 0:
        return
    if alpha > 1:
        alpha = 1.0
    i = (y * SIZE + x) * 3
    inv = 1.0 - alpha
    canvas[i] = int(canvas[i] * inv + color[0] * alpha + 0.5)
    canvas[i + 1] = int(canvas[i + 1] * inv + color[1] * alpha + 0.5)
    canvas[i + 2] = int(canvas[i + 2] * inv + color[2] * alpha + 0.5)


def draw_capsule(ax, ay, bx, by, half_thickness, color=FG):
    """画一条圆头线段（胶囊），带 1px 羽化。"""
    min_x = int(max(0, min(ax, bx) - half_thickness - 2))
    max_x = int(min(SIZE - 1, max(ax, bx) + half_thickness + 2))
    min_y = int(max(0, min(ay, by) - half_thickness - 2))
    max_y = int(min(SIZE - 1, max(ay, by) + half_thickness + 2))

    vx, vy = bx - ax, by - ay
    denom = vx * vx + vy * vy
    if denom == 0:
        denom = 1e-9

    for y in range(min_y, max_y + 1):
        for x in range(min_x, max_x + 1):
            wx, wy = x - ax, y - ay
            t = (wx * vx + wy * vy) / denom
            if t < 0.0:
                t = 0.0
            elif t > 1.0:
                t = 1.0
            dx, dy = wx - t * vx, wy - t * vy
            dist = (dx * dx + dy * dy) ** 0.5
            alpha = half_thickness - dist + 0.5
            if alpha > 0:
                blend_pixel(x, y, color, alpha)


def draw_circle(cx, cy, radius, color=FG):
    draw_capsule(cx, cy, cx, cy, radius, color)


# --- 舞者剪影 ---
# 头
draw_circle(500, 292, 92)

# 躯干
draw_capsule(500, 392, 500, 628, 46)

# 左臂（画面左侧，屈肘上举）
draw_capsule(500, 420, 352, 336, 40)
draw_capsule(352, 336, 268, 214, 40)

# 右臂（举得更高，形成动势）
draw_capsule(500, 420, 668, 330, 40)
draw_capsule(668, 330, 760, 196, 40)

# 左腿（屈膝外展）
draw_capsule(500, 628, 400, 762, 46)
draw_capsule(400, 762, 352, 918, 46)

# 右腿
draw_capsule(500, 628, 626, 748, 46)
draw_capsule(626, 748, 700, 898, 46)


# --- 写出 PNG ---
def chunk(tag, data):
    return (
        struct.pack(">I", len(data))
        + tag
        + data
        + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    )


raw = bytearray()
for y in range(SIZE):
    raw.append(0)                                   # 每行的 filter 字节
    raw += canvas[y * SIZE * 3:(y + 1) * SIZE * 3]

png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))  # 8bit 真彩色 RGB
png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
png += chunk(b"IEND", b"")

target = os.path.abspath(OUT)
os.makedirs(os.path.dirname(target), exist_ok=True)
with open(target, "wb") as f:
    f.write(png)

print("已生成 %s" % target)
print("%dx%d / 真彩色无透明通道 / %d 字节 (%.0f KB)"
      % (SIZE, SIZE, len(png), len(png) / 1024.0))
