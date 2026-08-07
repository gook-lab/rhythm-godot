#!/usr/bin/env python3
"""
칩튠 곡 생성기. 140bpm 4/4, 약 69초.

왜 곡을 만들어 쓰나 (make_click.py 와 같은 이유가 더 강하게 적용된다):
  남의 곡은 BPM 이 정확히 알려져 있지 않거나, 변속이 있거나, 그루브(스윙)가 있다.
  판정이 어긋났을 때 원인이 내 코드인지 곡인지 구분이 안 된다.
  직접 만들면 온셋이 샘플 단위로 정확하고 저작권도 안 걸린다.

가장 중요한 산출물은 WAV 가 아니라 **melody_onsets.json** 이다.
채보 생성기가 그걸 읽어서 타일 리듬을 만든다 —
곡과 채보가 같은 소스에서 나와야 둘이 갈라지지 않는다.

!! 게임의 물리적 제약: 한 타일이 표현할 수 있는 대기는 (0, 2] 박이다.
   sweep 이 (0, 360] 이고 beats = sweep/180 이기 때문이다.
   그래서 멜로디 온셋 간격이 2박을 넘으면 안 된다. 아래 verify 가 막는다.
"""
import json
import math
import os
import struct
import subprocess
import sys

SR = 48000
BPM = 140.0
SPB = 60.0 / BPM          # 초/박
BEATS_PER_BAR = 4

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def midi_hz(n):
    return 440.0 * (2.0 ** ((n - 69) / 12.0))


# ─────────────────────────────────────────────────────────── 음색
def square(t, freq, duty=0.5):
    ph = (t * freq) % 1.0
    return 1.0 if ph < duty else -1.0


def triangle(t, freq):
    ph = (t * freq) % 1.0
    return 4.0 * abs(ph - 0.5) - 1.0


def env_ad(i, n, attack=0.005, release=0.06):
    """간단한 어택-감쇠 엔벌로프. 어택이 뚜렷해야 박자가 잡힌다."""
    t = i / SR
    total = n / SR
    if t < attack:
        return t / attack
    tail = total - t
    if tail < release:
        return max(0.0, tail / release)
    return 1.0


def render_note(buf, start_beat, dur_beats, midi, wave, amp, duty=0.5):
    start = int(round(start_beat * SPB * SR))
    n = int(round(dur_beats * SPB * SR))
    f = midi_hz(midi)
    for i in range(n):
        j = start + i
        if j >= len(buf):
            break
        t = i / SR
        v = square(t, f, duty) if wave == "sq" else triangle(t, f)
        buf[j] += v * amp * env_ad(i, n)


# ─────────────────────────────────────────────────────────── 드럼
_noise_state = 12345


def noise():
    global _noise_state
    _noise_state = (_noise_state * 1103515245 + 12345) & 0x7FFFFFFF
    return (_noise_state / 0x3FFFFFFF) - 1.0


def render_kick(buf, start_beat, amp=0.85):
    start = int(round(start_beat * SPB * SR))
    n = int(0.13 * SR)
    for i in range(n):
        j = start + i
        if j >= len(buf):
            break
        t = i / SR
        f = 130.0 * math.exp(-t * 32.0) + 45.0      # 피치 스윕
        e = math.exp(-t * 22.0)
        buf[j] += math.sin(2 * math.pi * f * t) * e * amp


def render_snare(buf, start_beat, amp=0.5):
    start = int(round(start_beat * SPB * SR))
    n = int(0.11 * SR)
    for i in range(n):
        j = start + i
        if j >= len(buf):
            break
        t = i / SR
        e = math.exp(-t * 30.0)
        buf[j] += (noise() * 0.75 + math.sin(2 * math.pi * 190.0 * t) * 0.25) * e * amp


def render_hat(buf, start_beat, amp=0.22, open_=False):
    start = int(round(start_beat * SPB * SR))
    n = int((0.09 if open_ else 0.03) * SR)
    for i in range(n):
        j = start + i
        if j >= len(buf):
            break
        e = math.exp(-(i / SR) * (26.0 if open_ else 90.0))
        buf[j] += noise() * e * amp


# ─────────────────────────────────────────────────────────── 곡 구성
# A 단조. 리드는 A4~A5 대역.
A, B, C, D, E, F, G = 69, 71, 72, 74, 76, 77, 79
A5, C6, D6, E6 = 81, 84, 86, 88

# (박 오프셋, 길이, 음) — 마디 내 상대 위치
MOTIF_A = [
    (0.0, 1.0, A), (1.0, 1.0, C), (2.0, 0.5, E), (2.5, 0.5, D), (3.0, 1.0, C),
]
MOTIF_A2 = [
    (0.0, 1.0, G), (1.0, 1.0, E), (2.0, 1.0, D), (3.0, 1.0, C),
]
MOTIF_B = [
    (0.0, 0.5, E), (0.5, 0.5, F), (1.0, 1.0, G), (2.0, 0.5, A5), (2.5, 0.5, G),
    (3.0, 0.5, E), (3.5, 0.5, D),
]
MOTIF_B2 = [
    (0.0, 1.0, C), (1.0, 0.5, D), (1.5, 0.5, E), (2.0, 2.0, A),
]
MOTIF_C = [
    (0.0, 0.5, A5), (0.5, 0.5, G), (1.0, 0.5, E), (1.5, 0.5, D),
    (2.0, 0.5, E), (2.5, 0.5, G), (3.0, 1.0, A5),
]
MOTIF_C2 = [
    (0.0, 0.5, C6), (0.5, 0.5, A5), (1.0, 1.0, G), (2.0, 1.0, E), (3.0, 1.0, A5),
]

BASS_ROOTS = [A - 24, A - 24, F - 24, F - 24, C - 24, C - 24, G - 24, G - 24]


def build():
    bars = 40
    total_beats = bars * BEATS_PER_BAR
    total_samples = int(round((total_beats * SPB + 1.0) * SR))
    buf = [0.0] * total_samples
    onsets = []   # 리드 멜로디의 온셋(박). 채보의 진실 소스.

    def lead(bar, motif, amp=0.24, duty=0.5):
        base = bar * BEATS_PER_BAR
        for off, dur, note in motif:
            render_note(buf, base + off, dur, note, "sq", amp, duty)
            onsets.append(base + off)

    def bass(bar, root, pattern="pulse"):
        base = bar * BEATS_PER_BAR
        if pattern == "pulse":
            for k in range(8):
                render_note(buf, base + k * 0.5, 0.45, root, "tri", 0.30)
        else:
            render_note(buf, base, 2.0, root, "tri", 0.32)
            render_note(buf, base + 2.0, 2.0, root + 7, "tri", 0.28)

    def drums(bar, fill=False, hats=True):
        base = bar * BEATS_PER_BAR
        render_kick(buf, base)
        render_kick(buf, base + 2.0)
        render_snare(buf, base + 1.0)
        render_snare(buf, base + 3.0)
        if hats:
            for k in range(8):
                render_hat(buf, base + k * 0.5, open_=(k == 7 and fill))
        if fill:
            for k in range(4):
                render_snare(buf, base + 3.0 + k * 0.25, amp=0.32 + k * 0.06)

    # ── intro 0-3 : 드럼 -> 베이스 순으로 쌓는다
    for b in range(0, 4):
        drums(b, fill=(b == 3), hats=(b >= 1))
        if b >= 2:
            bass(b, BASS_ROOTS[b % 8])

    # ── A 4-11
    for i, b in enumerate(range(4, 12)):
        drums(b, fill=(i == 7))
        bass(b, BASS_ROOTS[i % 8])
        lead(b, MOTIF_A if i % 2 == 0 else MOTIF_A2)

    # ── B 12-19 : 8분음 밀도 올림
    for i, b in enumerate(range(12, 20)):
        drums(b, fill=(i == 7))
        bass(b, BASS_ROOTS[i % 8])
        lead(b, MOTIF_B if i % 2 == 0 else MOTIF_B2, duty=0.25)

    # ── A' 20-27
    for i, b in enumerate(range(20, 28)):
        drums(b, fill=(i == 7))
        bass(b, BASS_ROOTS[i % 8])
        lead(b, MOTIF_A if i % 2 == 0 else MOTIF_A2)

    # ── C 28-35 : 클라이맥스
    for i, b in enumerate(range(28, 36)):
        drums(b, fill=(i == 7))
        bass(b, BASS_ROOTS[i % 8], pattern="pulse")
        lead(b, MOTIF_C if i % 2 == 0 else MOTIF_C2, amp=0.26, duty=0.375)

    # ── outro 36-39
    # 여기서 원래 9박 공백이 났다. 한 타일이 표현할 수 있는 대기는 (0,2] 박이라
    # 그 구간은 채보로 못 만든다(verify 가 잡았다).
    # 아웃트로를 2박짜리 롱톤으로 채워서 간격을 2박 이하로 유지한다.
    OUTRO_HALF = [(0.0, 1.8, E), (2.0, 1.8, C)]
    OUTRO_HALF2 = [(0.0, 1.8, D), (2.0, 1.8, A)]
    for i, b in enumerate(range(36, 40)):
        drums(b, hats=(i < 2))
        bass(b, BASS_ROOTS[i % 8], pattern="hold")
        if i == 0:
            lead(b, MOTIF_A2, amp=0.20)
        elif i == 1:
            lead(b, OUTRO_HALF, amp=0.20)
        elif i == 2:
            lead(b, OUTRO_HALF2, amp=0.18)
        else:
            render_note(buf, b * BEATS_PER_BAR, 3.2, A, "sq", 0.22)
            onsets.append(b * BEATS_PER_BAR)

    onsets = sorted(set(round(o, 6) for o in onsets))
    return buf, onsets, total_beats


# ─────────────────────────────────────────────────────────── 검증 · 출력
def verify(onsets):
    """게임이 표현 가능한 리듬인지 확인한다.

    한 타일의 대기는 (0, 2] 박이다 — sweep 이 (0, 360] 이고 beats = sweep/180.
    간격이 2박을 넘으면 그 구간은 한 타일로 못 만든다.
    그리고 1/12박 격자(15도 단위) 위에 있어야 각도로 깔끔히 역산된다.
    """
    gaps = [round(onsets[i] - onsets[i - 1], 6) for i in range(1, len(onsets))]
    bad_long = [g for g in gaps if g > 2.0 + 1e-9]
    bad_grid = [g for g in gaps if abs(g * 12 - round(g * 12)) > 1e-6]
    assert not bad_long, "2박 초과 간격(한 타일로 표현 불가): %s" % sorted(set(bad_long))
    assert not bad_grid, "1/12박 격자 밖: %s" % sorted(set(bad_grid))
    return gaps


def normalize(buf, peak=0.89):
    m = max(abs(v) for v in buf) or 1.0
    k = peak / m
    return [v * k for v in buf]


def write_wav(path, samples):
    data = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in samples)
    with open(path, "wb") as f:
        f.write(b"RIFF")
        f.write(struct.pack("<I", 36 + len(data)))
        f.write(b"WAVEfmt ")
        f.write(struct.pack("<IHHIIHH", 16, 1, 1, SR, SR * 2, 2, 16))
        f.write(b"data")
        f.write(struct.pack("<I", len(data)))
        f.write(data)


def main():
    buf, onsets, total_beats = build()
    gaps = verify(onsets)
    buf = normalize(buf)

    os.makedirs(os.path.join(HERE, "assets"), exist_ok=True)
    wav = os.path.join(HERE, "assets", "song_140.wav")
    write_wav(wav, buf)

    meta = {
        "bpm": BPM,
        "sample_rate": SR,
        "bars": int(total_beats // BEATS_PER_BAR),
        "duration_s": len(buf) / SR,
        "melody_onsets_beats": onsets,
        "gaps_beats": gaps,
    }
    with open(os.path.join(HERE, "assets", "song_140.json"), "w") as f:
        json.dump(meta, f, indent=1)

    from collections import Counter
    c = Counter(gaps)
    print("song_140.wav  %.1fs · %d마디 · %g bpm" % (len(buf) / SR, meta["bars"], BPM))
    print("멜로디 온셋 %d개 · 타일 간격 분포:" % len(onsets))
    for g, n in sorted(c.items()):
        print("   %5.3f박  x%-4d" % (g, n))
    print("검증 통과 — 전부 (0,2] 박 · 1/12 격자")
    print("meta: assets/song_140.json  (채보 생성기가 이걸 읽는다)")


if __name__ == "__main__":
    main()
