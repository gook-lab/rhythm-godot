#!/usr/bin/env python3
"""
메트로놈 클릭 트랙 생성기 (T11).

왜 음악이 아니라 클릭인가:
  M1 의 목적은 판정 정확도 검증이다. 음악은 BPM 이 정확히 알려져 있지 않거나
  변속이 있거나 그루브(스윙)가 있어서, 판정이 어긋났을 때 원인이
  내 코드인지 곡인지 구분이 안 된다. 클릭은 샘플 단위로 정확하다.

  BPM 을 120 으로 '반올림'하면 안 된다 — 3분이면 수백 ms 가 어긋난다.
  그래서 곡을 구해오지 않고 직접 만든다.

사용:
  python3 tools/make_click.py           # 기본 120bpm 60초
  python3 tools/make_click.py 175 90    # 175bpm 90초
"""
import math
import struct
import subprocess
import sys
import os

SR = 48000  # Godot 기본 믹스 레이트와 맞춘다


def click(freq, ms, amp):
    n = int(SR * ms / 1000.0)
    out = []
    for i in range(n):
        t = i / SR
        env = math.exp(-t * 55.0)  # 빠른 감쇠 — 어택이 뚜렷해야 박자가 잡힌다
        out.append(amp * env * math.sin(2 * math.pi * freq * t))
    return out


def build(bpm, seconds, accent_every=4):
    total = int(SR * seconds)
    buf = [0.0] * total
    spb = 60.0 / bpm
    downbeat = click(1600.0, 40.0, 0.9)
    upbeat = click(1000.0, 30.0, 0.55)
    beat = 0
    while True:
        # 샘플 인덱스를 float 누적이 아니라 매번 곱으로 구한다.
        # 누적하면 수천 박자 뒤에 반올림 오차가 쌓인다.
        start = int(round(beat * spb * SR))
        if start >= total:
            break
        src = downbeat if beat % accent_every == 0 else upbeat
        for i, v in enumerate(src):
            j = start + i
            if j >= total:
                break
            buf[j] += v
        beat += 1
    return buf, beat


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
    bpm = float(sys.argv[1]) if len(sys.argv) > 1 else 120.0
    seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 60.0
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    base = os.path.join(here, "assets", "click_%g" % bpm)
    samples, beats = build(bpm, seconds)
    write_wav(base + ".wav", samples)
    print("wav: %s.wav  (%g bpm, %g초, %d박)" % (base, bpm, seconds, beats))
    try:
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-i", base + ".wav",
             "-c:a", "libvorbis", "-q:a", "6", base + ".ogg"],
            check=True)
        os.remove(base + ".wav")
        print("ogg: %s.ogg" % base)
    except (FileNotFoundError, subprocess.CalledProcessError) as e:
        print("ffmpeg 없음/실패 — wav 를 그대로 쓴다 (Godot 은 wav 도 읽는다): %s" % e)


if __name__ == "__main__":
    main()
