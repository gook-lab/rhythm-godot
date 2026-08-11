#!/usr/bin/env python3
"""판정 사운드 2종.

hit.wav — 키를 누른 '그 순간'을 귀로 돌려준다. 곡의 박과 내 입력음의 어긋남이
  곧 내 오차라서 화면 판정보다 빠른 캘리브레이션 도구다.

  !! 처음엔 2kHz 사인 톤 28ms 로 만들었는데 곡에 파묻혔다 — 칩튠 구형파의
  배음이 1~8kHz 를 꽉 채우고 있어서다. 얼불춤 기본 히트사운드가 'Kick' 인
  이유가 이것: 저역 킥(55~160Hz 스윕)은 구형파 스펙트럼 아래로 뚫고 나온다.
  어택 정의를 위해 첫 4ms 에 노이즈 클릭을 얹는다.

miss.wav — 놓친 타일의 소리. 감시자 미스는 키 입력이 없어서 히트사운드가
  안 나고, 화면만 흔들리고 귀는 조용했다. 불협(단2도) 버즈라 '틀렸다'가
  즉각 읽힌다.
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_click import write_wav, SR

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

_seed = 987654


def _noise():
    global _seed
    _seed = (_seed * 1103515245 + 12345) & 0x7FFFFFFF
    return (_seed / 0x3FFFFFFF) - 1.0


def normalize(buf, peak):
    m = max(abs(v) for v in buf) or 1.0
    return [v * peak / m for v in buf]


# ── hit: 킥(주파수 스윕은 위상 적분으로 — sin(2πf(t)t) 는 처프가 뭉개진다) ──
n = int(0.07 * SR)
buf = []
phase = 0.0
for i in range(n):
    t = i / SR
    f = 55.0 + 105.0 * math.exp(-t * 45.0)
    phase += 2.0 * math.pi * f / SR
    v = math.sin(phase) * math.exp(-t * 30.0)
    if t < 0.004:                       # 어택 클릭
        # 0.5 는 '딱' 소리가 곡 위로 튀었다("곡이랑 안 맞는다" 피드백).
        # 절반이면 어택 정의는 남고 스냅은 죽는다.
        v += _noise() * math.exp(-t * 800.0) * 0.25
    buf.append(v)
# 피크도 0.9 -> 0.62: 곡 렌더가 피크 정규화라 같은 0.9 면 매 탭이 곡과
# 동급 크기다. 재생 트림(-4dB)과 합쳐 곡 밑에 깔리는 수준을 기본으로.
write_wav(os.path.join(HERE, "assets", "hit.wav"), normalize(buf, 0.62))

# ── miss: 단2도 불협 버즈 ──
n = int(0.14 * SR)
buf = []
for i in range(n):
    t = i / SR
    e = math.exp(-t * 18.0)
    a = 1.0 if (t * 220.0) % 1.0 < 0.5 else -1.0
    b = 1.0 if (t * 233.1) % 1.0 < 0.5 else -1.0
    buf.append((a * 0.55 + b * 0.45) * e)
write_wav(os.path.join(HERE, "assets", "miss.wav"), normalize(buf, 0.55))

print("assets/hit.wav (킥 70ms) · assets/miss.wav (불협 버즈 140ms)")
