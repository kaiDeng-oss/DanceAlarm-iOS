#!/usr/bin/env python3
"""生成闹铃音效 alarm.wav（纯标准库，无第三方依赖）。

App 必须在包里带一个音频文件才能响 —— 系统音效不保证可用，
并且 AVAudioSession 用 .playback 类别播放自带音频时才不受静音开关影响。

音色设计：880Hz + 1760Hz 泛音的三连短促蜂鸣，1 秒一个循环，共 6 秒。
每个音符带 8ms 淡入 / 45ms 淡出，避免波形突变产生"咔哒"爆音。
"""

import array
import math
import os
import wave

RATE = 44100
DURATION = 6.0
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "DanceAlarm", "Resources", "alarm.wav")


def tone(freq, seconds, gain=0.0):
    """返回一个音符的采样列表。gain 为额外增益（用于泛音）。"""
    n = int(RATE * seconds)
    attack = int(RATE * 0.008)
    release = int(RATE * 0.045)
    out = []
    for i in range(n):
        t = i / RATE
        # 基频 + 一个八度泛音，听起来更"穿透"但不刺耳
        v = math.sin(2 * math.pi * freq * t) + 0.28 * math.sin(2 * math.pi * freq * 2 * t)
        env = 1.0
        if i < attack:
            env = i / attack
        elif i > n - release:
            env = (n - i) / release
        out.append(v * env * (0.5 + gain))
    return out


def silence(seconds):
    return [0.0] * int(RATE * seconds)


# 一个 1.0 秒的循环：两个 880Hz + 一个 1174.7Hz（D6），构成"叮-叮-叮"三连音
CYCLE = (
    tone(880.0, 0.16)
    + silence(0.04)
    + tone(880.0, 0.16)
    + silence(0.04)
    + tone(1174.66, 0.16)
    + silence(0.44)
)

samples = []
while len(samples) < RATE * DURATION:
    samples.extend(CYCLE)
samples = samples[: int(RATE * DURATION)]

# 整体淡出 120ms，循环时衔接自然
fade = int(RATE * 0.12)
for i in range(fade):
    samples[len(samples) - fade + i] *= 1.0 - i / fade

# 归一化到 0.82 峰值，响度足够但留 headroom 防削波
peak = max(abs(v) for v in samples) or 1.0
scale = 0.82 / peak

pcm = array.array("h")
for v in samples:
    s = max(-1.0, min(1.0, v * scale))
    pcm.append(int(s * 32767))

os.makedirs(os.path.dirname(os.path.abspath(OUT)), exist_ok=True)
with wave.open(OUT, "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(RATE)
    w.writeframes(pcm.tobytes())

size = os.path.getsize(OUT)
print("已生成 %s" % os.path.abspath(OUT))
print("时长 %.1f 秒 / %d Hz / 单声道 16bit / %d 字节 (%.0f KB)"
      % (len(pcm) / RATE, RATE, size, size / 1024.0))
