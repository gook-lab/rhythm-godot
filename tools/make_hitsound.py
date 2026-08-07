#!/usr/bin/env python3
"""히트사운드 — 키를 누른 '그 순간'을 귀로 돌려준다.

곡의 클릭과 내 입력음의 어긋남이 곧 내 오차다. 화면 판정보다 빠른 피드백이라
손맛 캘리브레이션의 핵심 도구다(얼불춤도 hitsound 가 레벨 포맷 기본 항목이다).
짧고(28ms) 어택이 선명해야 하며, 곡을 가리지 않게 대역이 높다(2kHz).
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_click import write_wav, SR

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
n = int(0.028 * SR)
buf = []
for i in range(n):
    t = i / SR
    env = math.exp(-t * 220.0)
    v = math.sin(2 * math.pi * 2000.0 * t) * 0.7 + math.sin(2 * math.pi * 3100.0 * t) * 0.3
    buf.append(v * env * 0.5)
write_wav(os.path.join(HERE, "assets", "hit.wav"), buf)
print("assets/hit.wav  %.0fms" % (n * 1000.0 / SR))
