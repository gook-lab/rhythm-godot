#!/usr/bin/env python3
"""
MIDI -> 곡(wav) + 채보(.tres). AI 음악 경로의 본선.

  python3 tools/midi2song.py assets/test_song.mid
  python3 tools/midi2song.py foo.mid --name mysong --title "제목" --melody-track 2

왜 이 경로인가 (2026-08 조사 결론):
  AI 오디오 생성은 전부 미세 템포 드리프트가 있고(0.5% 면 3분에 ~900ms),
  온셋 검출(madmom)은 120bpm 초과에서 정확도 11% 로 붕괴한다.
  반면 MIDI 틱은 '이미 박자 도메인'(tick/PPQ = 박)이라
  드리프트 0 · 온셋 검출 불필요. AI 에겐 작곡(MIDI)만 시키고
  오디오는 여기서 샘플 단위 정확하게 렌더한다.

게임 제약과의 정합 (전부 이 파일이 강제한다):
  1. 온셋은 1/12 박 격자 위 -> 양자화 + 오차 보고
  2. 타일 간격 (0, 2] 박 -> 2박 걸음으로 채움 타일 삽입(로그)
  3. 코드(동시 노트) -> 온셋 1개로
  4. MIDI 템포 변경 = 토끼/달팽이 타일. 단 게임은 '홉당 상수 배속'이라
     변경 지점에 타일이 반드시 있어야 한다 -> 없으면 강제 삽입
  5. 첫 온셋 앞에 카운트인 4박 확보 -> 부족하면 전체를 시프트(오디오도 같이)

검증 2단:
  - Python: 템포 맵 정답 벽시계 vs .tres 를 읽어 되계산한 히트타임 (< 0.01ms)
  - GDScript(tests/verify_chart.gd): 실제 엔진 ChartRuntime.hit_times_ms 와 대조
"""
import argparse
import json
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(HERE, "tools"))

from midilib import parse_smf, TempoMap
from make_song import square, triangle, midi_hz, noise, normalize
from make_click import write_wav
import make_charts

SR = 48000
GRID = 12          # 1/12 박 격자 (15도 단위)
LEAD_BEATS = 4.0   # 카운트인
MAX_HOP = 2.0      # 한 타일이 표현 가능한 최대 대기 (sweep <= 360도)


def q12(beat):
    return round(beat * GRID) / GRID


# ---------------------------------------------------------------- 렌더 (초 도메인)
# make_song 은 상수 SPB(박 도메인)로 렌더하지만, 여기는 템포가 변하므로
# 모든 이벤트를 템포 맵으로 초에 사상한 뒤 초 도메인에서 합성한다.
def _env(i, n, attack=0.005, release=0.06):
    t = i / SR
    if t < attack:
        return t / attack
    tail = (n - i) / SR
    return max(0.0, min(1.0, tail / release))


def render_tone(buf, t0, dur_s, pitch, wave, amp, duty=0.5):
    start = int(round(t0 * SR))
    n = max(1, int(round(dur_s * SR)))
    f = midi_hz(pitch)
    for i in range(n):
        j = start + i
        if j >= len(buf):
            break
        t = i / SR
        v = square(t, f, duty) if wave == "sq" else triangle(t, f)
        buf[j] += v * amp * _env(i, n)


def render_kick(buf, t0, amp=0.85):
    start = int(round(t0 * SR))
    n = int(0.13 * SR)
    for i in range(n):
        j = start + i
        if j >= len(buf):
            break
        t = i / SR
        f = 130.0 * math.exp(-t * 32.0) + 45.0
        buf[j] += math.sin(2 * math.pi * f * t) * math.exp(-t * 22.0) * amp


def render_snare(buf, t0, amp=0.5):
    start = int(round(t0 * SR))
    n = int(0.11 * SR)
    for i in range(n):
        j = start + i
        if j >= len(buf):
            break
        t = i / SR
        e = math.exp(-t * 30.0)
        buf[j] += (noise() * 0.75 + math.sin(2 * math.pi * 190.0 * t) * 0.25) * e * amp


def render_hat(buf, t0, amp=0.22, open_=False):
    start = int(round(t0 * SR))
    n = int((0.09 if open_ else 0.03) * SR)
    for i in range(n):
        j = start + i
        if j >= len(buf):
            break
        buf[j] += noise() * math.exp(-(i / SR) * (26.0 if open_ else 90.0)) * amp


# GM 드럼 -> 우리 신스
def render_drum(buf, t0, pitch, vel):
    a = vel / 100.0
    if pitch in (35, 36):
        render_kick(buf, t0, 0.85 * a)
    elif pitch in (38, 40):
        render_snare(buf, t0, 0.5 * a)
    elif pitch == 46:
        render_hat(buf, t0, 0.22 * a, open_=True)
    else:
        render_hat(buf, t0, 0.22 * a)


# ---------------------------------------------------------------- 파이프라인
def pick_melody(tracks, override):
    """멜로디 트랙 선택: 지정 없으면 '드럼 아닌 트랙 중 평균 음높이 최고'.

    리드가 보통 최상성부라는 관행에 기댄 휴리스틱이다. 틀리면 --melody-track 으로.
    """
    if override is not None:
        return override
    best, best_key = None, None
    for i, tr in enumerate(tracks):
        pitched = [n for n in tr["notes"] if n.ch != 9]
        if not pitched:
            continue
        key = (sum(n.pitch for n in pitched) / len(pitched), len(pitched))
        if best_key is None or key > best_key:
            best, best_key = i, key
    assert best is not None, "음정 트랙이 하나도 없다"
    return best


def replay_hit_times_from_tres(tres_path):
    """생성된 .tres 를 읽어 ChartRuntime.hit_times_ms 를 그대로 되계산한다.

    메모리의 중간값이 아니라 '파일'을 검증한다 — fmt 잘림, 필드 누락,
    타일 매핑 실수가 전부 여기서 걸린다.
    스핀(twirl)·배속(pivot 타일 기준) 의미론은 ChartRuntime 과 자구까지 같아야 한다.
    """
    t = open(tres_path, encoding="utf-8").read()
    ang = [float(x) for x in re.search(r"angles = PackedFloat32Array\(([^)]*)\)", t).group(1).split(",")]
    bpm = float(re.search(r"\nbpm = ([\d.eE+-]+)", t).group(1))
    so = float(re.search(r"start_offset_ms = ([\d.eE+-]+)", t).group(1))
    m = re.search(r"twirl_tiles = PackedInt32Array\(([^)]*)\)", t)
    twirls = [int(x) for x in m.group(1).split(",")] if m else []
    m = re.search(r"speed_changes = PackedVector2Array\(([^)]*)\)", t)
    sc = []
    if m:
        vals = [float(x) for x in m.group(1).split(",")]
        sc = list(zip([int(v) for v in vals[0::2]], vals[1::2]))

    def mult_at(tile):
        v = 1.0
        for x, y in sc:
            if x <= tile and y > 0:
                v = y
        return v

    hops = make_charts.hops_of(ang, twirls)
    out = [so]
    spb = 60000.0 / bpm
    for i in range(1, len(ang)):
        out.append(out[-1] + hops[i - 1] * spb / mult_at(i - 1))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("midi")
    ap.add_argument("--name", default=None)
    ap.add_argument("--title", default=None)
    ap.add_argument("--melody-track", type=int, default=None)
    ap.add_argument("--no-fill", action="store_true",
                    help="2박 초과 공백을 채우지 않고 에러로 처리")
    args = ap.parse_args()

    name = args.name or os.path.splitext(os.path.basename(args.midi))[0]
    title = args.title or name

    data = parse_smf(args.midi)
    ppq = data["ppq"]
    mel_i = pick_melody(data["tracks"], args.melody_track)
    print("MIDI: %s · PPQ %d · 트랙 %d개 · 멜로디 = 트랙 %d (%s)"
          % (args.midi, ppq, len(data["tracks"]), mel_i,
             data["tracks"][mel_i]["name"] or "이름 없음"))

    # ── 온셋: 양자화 + 코드 합침 ─────────────────────────────────
    mel_notes = [n for n in data["tracks"][mel_i]["notes"] if n.ch != 9]
    raw = sorted(n.tick / ppq for n in mel_notes)
    quant_err = max((abs(b - q12(b)) for b in raw), default=0.0)
    onsets = sorted(set(q12(b) for b in raw))
    if quant_err > 1e-9:
        print("  양자화: 최대 오차 %.4f박 (1/12 격자로 스냅)" % quant_err)
    if len(onsets) < len(raw):
        print("  코드 합침: 노트 %d -> 온셋 %d" % (len(raw), len(onsets)))

    # ── 카운트인 시프트 (오디오·템포·온셋을 전부 같이 민다) ─────
    shift = max(0.0, LEAD_BEATS - onsets[0])
    tempos = [(0.0, data["tempos"][0][1])] + [
        (t / ppq + shift, bpm) for t, bpm in data["tempos"] if t > 0]
    if shift > 0:
        onsets = [q12(o + shift) for o in onsets]
        print("  카운트인: 전체 +%.4g박 시프트 (첫 온셋 %.4g박)" % (shift, onsets[0]))
    tmap = TempoMap(tempos)
    base_bpm = tmap.bpm_at(onsets[0])

    # ── 템포 변경 지점에 타일 강제 삽입 ──────────────────────────
    # 게임은 홉당 상수 배속이라, 변경이 홉 '중간'에 오면 표현이 안 된다.
    # 얼불춤도 속도 타일이 '타일'인 이유가 이것이다.
    inserted = []
    for beat, _bpm in tempos:
        qb = q12(beat)
        if onsets[0] < qb < onsets[-1] and not any(abs(o - qb) < 1e-9 for o in onsets):
            onsets.append(qb)
            inserted.append(qb)
    onsets.sort()
    for qb in inserted:
        print("  속도 타일 삽입: %.4g박 (템포 변경 지점에 노트가 없었다)" % qb)

    # ── 2박 초과 공백 채움 ──────────────────────────────────────
    filled = []
    out = [onsets[0]]
    for o in onsets[1:]:
        while o - out[-1] > MAX_HOP + 1e-9:
            if args.no_fill:
                raise SystemExit("공백 %.4g박 @ %.4g박 — 한 타일 최대 2박 (--no-fill)"
                                 % (o - out[-1], out[-1]))
            nxt = q12(out[-1] + MAX_HOP)
            out.append(nxt)
            filled.append(nxt)
        out.append(o)
    onsets = out
    for f in filled:
        print("  채움 타일: %.4g박 (2박 초과 공백 — 지속음 위를 밟는다)" % f)

    gaps = [onsets[i] - onsets[i - 1] for i in range(1, len(onsets))]
    assert all(0 < g <= MAX_HOP + 1e-9 for g in gaps), "간격 위반: %s" % [g for g in gaps if not (0 < g <= MAX_HOP + 1e-9)]
    assert all(abs(g * GRID - round(g * GRID)) < 1e-6 for g in gaps), "격자 위반"

    # ── 속도 표시 + 시작점 (전부 벽시계는 템포 맵이 정답) ────────
    speed_marks = []
    prev_mult = 1.0
    for beat, bpm in tempos:
        if beat < onsets[0] - 1e-9 or beat > onsets[-1] + 1e-9:
            continue
        mult = bpm / base_bpm
        if abs(mult - prev_mult) > 1e-9:
            speed_marks.append([q12(beat), mult])
            prev_mult = mult
    start_offset_ms = (tmap.sec_at(onsets[0]) - 60.0 / base_bpm) * 1000.0
    # 실전 발견(위키피디아 샘플): 멀티트랙 MIDI 는 멜로디가 곡 한참 뒤에
    # 진입하기도 한다(기타가 176박 = 87.5초). 변환은 정확하지만 그 동안
    # 플레이어가 할 게 없다. 자동으로 자르는 건 월권이라 경고만 한다.
    if tmap.sec_at(onsets[0]) > 12.0:
        print("  !! 첫 타일이 %.1f초 — 인트로가 길다. 다른 트랙을 멜로디로 쓰거나"
              % tmap.sec_at(onsets[0]))
        print("     (--melody-track N) MIDI 를 잘라서 다시 뽑는 것을 고려하라.")

    # ── 렌더 ────────────────────────────────────────────────────
    end_beat = max(
        max((n.tick + n.dur) / ppq for tr in data["tracks"] for n in tr["notes"]) + shift,
        onsets[-1])
    total = int((tmap.sec_at(end_beat) + 1.0) * SR)
    buf = [0.0] * total
    for i, tr in enumerate(data["tracks"]):
        for n in tr["notes"]:
            t0 = tmap.sec_at(n.tick / ppq + shift)
            if n.ch == 9:
                render_drum(buf, t0, n.pitch, n.vel)
            else:
                dur_s = tmap.sec_at((n.tick + n.dur) / ppq + shift) - t0
                if i == mel_i:
                    render_tone(buf, t0, dur_s, n.pitch, "sq", 0.24 * n.vel / 96.0)
                else:
                    render_tone(buf, t0, dur_s, n.pitch, "tri", 0.30 * n.vel / 96.0)
    buf = normalize(buf)

    os.makedirs(os.path.join(HERE, "assets"), exist_ok=True)
    wav = os.path.join(HERE, "assets", "%s.wav" % name)
    write_wav(wav, buf)

    meta = {
        "bpm": base_bpm,
        "sample_rate": SR,
        "duration_s": len(buf) / SR,
        "source_midi": os.path.basename(args.midi),
        "melody_onsets_beats": onsets,
        "speed_marks_beats": speed_marks,
        "start_offset_ms": start_offset_ms,
        "quant_max_err_beats": quant_err,
        "inserted_speed_tiles": inserted,
        "filled_gap_tiles": filled,
    }
    meta_path = os.path.join(HERE, "assets", "%s.json" % name)
    json.dump(meta, open(meta_path, "w"), indent=1)

    # 정답 벽시계 (템포 맵 직접 적분) — 검증의 기준
    expected = [start_offset_ms] + [tmap.sec_at(o) * 1000.0 for o in onsets]
    json.dump({"hit_times_ms": expected, "chart": "res://charts/%s.tres" % name},
              open(os.path.join(HERE, "assets", "%s.expected.json" % name), "w"), indent=1)

    print("%s.wav  %.1fs · 기준 %g bpm · 온셋 %d · 속도표시 %d"
          % (name, len(buf) / SR, base_bpm, len(onsets), len(speed_marks)))

    # ── 채보 생성 ───────────────────────────────────────────────
    make_charts.chart_from_song(meta_path, name, title, "res://assets/%s.wav" % name)

    # ── 검증 1: 파일을 읽어 되계산한 히트타임 vs 템포 맵 정답 ────
    replay = replay_hit_times_from_tres(os.path.join(HERE, "charts", "%s.tres" % name))
    assert len(replay) == len(expected), "타일 수 불일치 %d != %d" % (len(replay), len(expected))
    worst = max(abs(a - b) for a, b in zip(replay, expected))
    print("검증(Python): .tres 되계산 vs 템포맵 정답 — 최대 오차 %.6f ms  %s"
          % (worst, "PASS" if worst < 0.01 else "FAIL"))
    if worst >= 0.01:
        raise SystemExit(1)
    print("다음: godot --headless --script res://tests/verify_chart.gd -- "
          "--chart=res://charts/%s.tres" % name)


if __name__ == "__main__":
    main()
