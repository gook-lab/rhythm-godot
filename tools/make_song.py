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


# ------------------------------------------------------- 라우드니스 정규화
# song_140.wav 의 실측 RMS. 판정 효과음(hit/miss)의 볼륨이 이 크기에 맞춰
# 튜닝되어 있으므로, 모든 곡을 여기에 맞추면 효과음 균형이 곡마다 흔들리지 않는다.
TARGET_RMS = 0.1778   # -15.0 dBFS
LIMIT_BLOCK = 64      # 게인 포락선 계산 단위(샘플). 48kHz 에서 1.33ms
LIMIT_LOOKAHEAD = 4   # 블록. 피크보다 먼저 게인을 내리기 위한 앞보기(~5ms)


def _gain_and_limit(buf, target_rms, ceiling):
    """RMS 를 target 으로 올리고, 그러다 천장을 넘는 피크만 리미터로 눌러 앉힌다.

    리미터는 블록 최대값 -> 앞보기 최소 -> 릴리스 평활 -> 샘플별 보간으로 건다.
    앞보기가 있어야 게인이 피크보다 '먼저' 내려가 트랜지언트가 안 깨진다.

    주의: 이 한 패스만으로는 target 에 못 닿는다. 리미터가 누른 만큼 RMS 가
    다시 내려가기 때문이다 — 그 보상은 loudness_normalize 가 반복으로 한다.
    """
    n = len(buf)
    if n == 0:
        return buf
    rms = math.sqrt(sum(v * v for v in buf) / n)
    if rms <= 0.0:
        return buf
    g0 = target_rms / rms
    buf = [v * g0 for v in buf]

    # 블록 최대 -> 그 블록에 필요한 게인
    nb = (n + LIMIT_BLOCK - 1) // LIMIT_BLOCK
    need = [1.0] * nb
    for b in range(nb):
        seg = buf[b * LIMIT_BLOCK:(b + 1) * LIMIT_BLOCK]
        pk = max(map(abs, seg)) if seg else 0.0
        if pk > ceiling:
            need[b] = ceiling / pk
    if min(need) >= 1.0:
        return buf   # 누를 게 없다

    # 앞보기 최소: 피크가 오기 전에 이미 내려가 있게 한다
    look = [min(need[b:b + LIMIT_LOOKAHEAD + 1]) for b in range(nb)]
    # 릴리스 평활: 급히 내리고 천천히 올린다 (펌핑·지퍼 잡음 방지)
    rel = 0.9971  # 블록당. 48kHz/64 기준 시상수 ~0.46s
    g = 1.0
    env = [1.0] * nb
    for b in range(nb):
        g = look[b] if look[b] < g else g * rel + look[b] * (1.0 - rel)
        env[b] = g

    out = [0.0] * n
    for b in range(nb):
        lo = b * LIMIT_BLOCK
        hi = min(lo + LIMIT_BLOCK, n)
        ga, gb = env[b], env[b + 1] if b + 1 < nb else env[b]
        span = max(1, hi - lo)
        cap = need[b]   # 게인이 올라가는 구간에서도 이 블록의 피크는 못 넘게
        for i in range(lo, hi):
            t = (i - lo) / span
            out[i] = buf[i] * min(cap, ga + (gb - ga) * t)   # 블록 사이 선형 보간
    return out



def loudness_normalize(buf, target_rms=TARGET_RMS, ceiling=0.89,
                       passes=4, tol_db=0.25, max_extra_db=6.0):
    """체감 크기(RMS)를 target 에 맞춘다. 곡의 '들리는 크기' 단일 진실 소스.

    피크 정규화만 하면 곡마다 체감 크기가 달라진다. 스템을 여러 개 합치면
    가끔 우연히 정렬되는 피크 하나가 전체 게인을 결정해버리기 때문이다 —
    실측(2026-08-07): 6스템 합성곡은 크레스트 18~20dB 에 RMS -19~-21dB 인데
    단일 트랙 song_140 은 크레스트 14dB 에 RMS -15dB 였다. 그래서 같은 판정음이
    새 곡에서만 6dB 더 튀어나왔다.

    한 번만 걸면 부족하다. 게인을 올려 target 에 맞춰도 리미터가 피크를 누르면서
    RMS 가 다시 내려가기 때문이다 — 실측(2026-08-10, 온셋 보강 뒤 밀도가 오른
    14곡): 목표 -15.0dB 인데 -16.1 ~ -18.7dB 로 앉아 판정음 여유가 3.7dB 폭으로
    다시 벌어졌다. 그래서 '재고 -> 모자란 만큼 더 밀고 -> 다시 리미터' 를 반복한다.

    무한정 밀지는 않는다(max_extra_db). 크레스트가 큰 곡을 target 까지 억지로
    끌어올리면 리미터가 상시 걸려 소리가 납작해진다 — 그런 곡은 조금 조용한 채로
    두는 쪽이 낫다.

    스테레오는 인터리브 버퍼를 그대로 받는다. RMS 는 양 채널 평균이 되고
    리미터 블록(64샘플 = 32프레임)의 게인이 L/R 에 같이 걸려 채널 연동이
    공짜로 성립한다 — 채널을 갈라 따로 걸면 이미지가 좌우로 흔들린다.
    다만 블록 '안'의 보간은 샘플 단위라 같은 프레임의 L 과 R 이 한 스텝만큼
    다른 게인을 받는다. 실측(L=R 인 신호를 넣어 벌어진 정도를 잼):
    최대 0.052dB · 평균 1e-5. 가청 한계(레벨차 ~1dB)의 20분의 1이라 그냥 둔다.
    블록을 키우거나 리미터를 더 세게 걸면 이 값이 커지므로 그때 다시 재라.

    또 하나: 블록이 '샘플' 단위(LIMIT_BLOCK)라 시간 길이가 채널 수에 따라
    달라진다 — 모노는 64샘플 = 1.33ms, 인터리브 스테레오는 32프레임 = 0.67ms 다.
    스테레오 쪽 리미터가 2배 빠르게 따라가므로 덜 누르고 조금 더 크게 앉는다
    (실측: 같은 소재로 모노 -27.31dB vs 스테레오 -26.44dB, 0.87dB 차).
    곡 간 편차(0.7dB)와 같은 급이라 지금은 문제가 안 된다 — 실제로 원곡
    스테레오 곡이 -15.02dB 로 목표에 가장 정확했다. 이 차이가 거슬리면
    블록을 프레임 단위로 바꾸면 된다(channels 인자를 받아 LIMIT_BLOCK*channels).
    """
    n = len(buf)
    if n == 0:
        return buf
    out = _gain_and_limit(buf, target_rms, ceiling)
    extra_db = 0.0
    for _ in range(passes - 1):
        rms = math.sqrt(sum(v * v for v in out) / n)
        if rms <= 0.0:
            break
        short_db = 20.0 * math.log10(target_rms / rms)
        if short_db <= tol_db:
            break
        step_db = min(short_db, max_extra_db - extra_db)
        if step_db <= 0.0:
            break
        extra_db += step_db
        out = _gain_and_limit(out, rms * (10.0 ** (step_db / 20.0)), ceiling)
    return out

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
    # 기준 곡도 다른 곡과 같은 경로를 탄다. 피크 정규화로 두면 TARGET_RMS 와
    # 맞는 게 '우연'이 된다 — 이 파일의 곡 내용이 바뀌는 순간 조용히 어긋나고,
    # 그러면 판정 효과음 균형의 기준선이 통째로 흔들린다.
    # (TARGET_RMS 를 원래 이 파일에서 땄으니 순환이지만, 그래서 오히려 맞다:
    #  상수는 '고른 크기'이고 기준 곡도 다른 곡처럼 거기에 맞춰지는 것이다.)
    buf = loudness_normalize(buf)

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
