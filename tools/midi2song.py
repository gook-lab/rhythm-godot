#!/usr/bin/env python3
"""
MIDI -> 곡(wav) + 채보(.tres). AI 음악 경로의 본선.

  python3 tools/midi2song.py assets/test_song.mid
  python3 tools/midi2song.py ~/Downloads/midis/*.mid --name aisong --melody vocal

단일 파일도, '스템 묶음'(악기별 MIDI 여러 개)도 받는다 — AI 서비스(Mureka 등)의
MIDI 내보내기는 보통 후자다(bass/drums/guitar/piano/synth/vocal, PPQ 제각각).
파일·PPQ 가 몇 개든 '박 도메인' 모델 하나로 통일한 뒤 같은 파이프라인을 태운다.

왜 이 경로인가 (2026-08 조사 결론):
  AI 오디오 생성은 전부 미세 템포 드리프트가 있고(0.5% 면 3분에 ~900ms),
  온셋 검출(madmom)은 120bpm 초과에서 정확도 11% 로 붕괴한다.
  반면 MIDI 틱은 '이미 박자 도메인'(tick/PPQ = 박)이라
  드리프트 0 · 온셋 검출 불필요. AI 에겐 작곡(MIDI)만 시키고
  오디오는 여기서 샘플 단위 정확하게 렌더한다.

전사(오디오→MIDI) 스템에서 배운 것 (전부 여기서 처리한다):
  - 템포가 '박마다' 찍혀 있다(실측 317엔트리, 20ms 격자 반올림 잡음).
    -> midilib.dejitter_tempos 가 시간 보존으로 걷어낸다 (--tempo-tol).
  - 노트가 격자 밖이다(연주 전사). 채보만 양자화하면 오디오와 어긋나므로
    '렌더할 노트 자체'를 같은 1/12 격자로 스냅한다. 둘은 정의상 일치한다.
  - 드럼은 ch9 이지만 파일명(drums.mid)으로도 판별한다.
  - 멜로디가 곡 한참 뒤에 진입하기도 한다(보컬 48박 등).
    -> 채보는 항상 카운트인 직후(4박)에 시작하고, 첫 멜로디까지는
       2박 걸음 채움 타일로 잇는다. 죽은 인트로가 없다.

게임 제약과의 정합:
  1/12 격자 · 간격 (0,2] 박(채움 타일) · 코드 합침 · 카운트인 시프트 ·
  템포 변경 지점 타일 강제 삽입(홉당 상수 배속이라 필수).

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

from midilib import parse_smf, TempoMap, dejitter_tempos
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


def track_voice(label, is_melody):
    """라벨 -> (파형, 진폭, 듀티). 스템 파일명 관행을 그대로 쓴다."""
    l = label.lower()
    if is_melody:
        return ("sq", 0.24, 0.5)
    if "bass" in l:
        return ("tri", 0.30, 0.5)
    if "guitar" in l:
        return ("sq", 0.13, 0.25)
    if "piano" in l:
        return ("tri", 0.20, 0.5)
    return ("tri", 0.15, 0.5)


# ---------------------------------------------------------------- 모델
def load_model(paths):
    """N개 MIDI(PPQ 제각각) -> 박 도메인 통합 모델.

    track: {label, drums, notes: [(beat, dur_beats, pitch, vel)]}
    템포는 첫 파일 기준. 나머지 파일과 박 도메인에서 대조해 다르면 경고한다
    (스템 실측: 6파일 전부 일치했다 — 같은 곡의 내보내기니까 당연해야 한다).
    """
    tracks = []
    tempo_ref, tempo_src = None, ""
    for path in paths:
        d = parse_smf(path)
        ppq = float(d["ppq"])
        base = os.path.splitext(os.path.basename(path))[0]
        tmap = [(t / ppq, round(b, 3)) for t, b in d["tempos"]]
        if tempo_ref is None:
            tempo_ref, tempo_src = tmap, base
        elif tmap[:64] != tempo_ref[:64]:
            print("  !! %s 의 템포 맵이 %s 와 다르다 — %s 것을 쓴다"
                  % (base, tempo_src, tempo_src))
        for tr in d["tracks"]:
            if not tr["notes"]:
                continue
            ch9 = sum(1 for n in tr["notes"] if n.ch == 9)
            drums = ch9 > len(tr["notes"]) // 2 or "drum" in base.lower()
            label = base if not tr["name"] else "%s:%s" % (base, tr["name"])
            tracks.append({
                "label": label,
                "drums": drums,
                "notes": [(n.tick / ppq, n.dur / ppq, n.pitch, n.vel)
                          for n in tr["notes"]],
            })
    assert tracks, "노트가 있는 트랙이 하나도 없다"
    tempos_beats = [(b, v) for b, v in tempo_ref]
    return tracks, tempos_beats


TIGHT_MS = 120.0    # 이보다 촘촘하면 판정창(±110ms)이 이웃과 붙어 사실상 못 친다
IDEAL_RATE = 1.5    # 초당 타일 수의 이상점. 얼불춤 체감 밀도가 대략 이 근처다


def dominant_bpm(tempos, lo_beat, hi_beat):
    """채보 구간에서 '가장 오래 유지되는' 템포. Chart.bpm 의 기준이 된다.

    첫 온셋의 템포를 쓰면 안 된다는 걸 실측이 보여줬다 (Mureka 곡 2번):
    곡 맨 앞에 300bpm 짜리 짧은 구간이 잡혀 있어서, 그걸 기준으로 삼자
    나머지 전곡이 x0.393312 달팽이 타일 하나로 표현됐다. 의미가 거꾸로고
    (118bpm 곡인데 '300bpm에서 계속 느려진 곡'이 된다), 288개 타일이 전부
    그 반올림된 배율을 곱해 히트타임 오차가 0.157ms 로 벌어졌다.

    가장 오래 가는 템포를 기준으로 삼으면 대다수 타일의 배율이 정확히 1.0 이
    되어 오차가 사라지고, 짧은 구간만 토끼/달팽이 타일이 된다.
    """
    held = {}
    for k, (beat, bpm) in enumerate(tempos):
        nxt = tempos[k + 1][0] if k + 1 < len(tempos) else hi_beat
        span = min(nxt, hi_beat) - max(beat, lo_beat)
        if span > 0:
            held[bpm] = held.get(bpm, 0.0) + span / bpm  # 박이 아니라 '시간'으로 센다
    if not held:
        return tempos[0][1]
    return max(held.items(), key=lambda kv: kv[1])[0]


def track_stats(tr, tmap, dur):
    """트랙 하나를 '채보로 썼을 때' 어떤 물건이 나오는지 (0~1 지표들)."""
    ons = sorted(set(q12(n[0]) for n in tr["notes"]))
    if len(ons) < 2:
        return None
    sec = [tmap.sec_at(o) for o in ons]
    gaps = [sec[i] - sec[i - 1] for i in range(1, len(sec))]
    return {
        "onsets": len(ons),
        "span": (sec[-1] - sec[0]) / dur,                            # 곡을 덮는 비율
        "tight": sum(1 for g in gaps if g * 1000.0 < TIGHT_MS) / len(gaps),
        "rate": len(ons) / dur,
    }


def melody_score(st):
    """채보로서의 점수. 높을수록 좋다.

    라벨('vocal')만 믿으면 안 된다는 걸 실측이 보여줬다 (2026-08-07, Mureka 11곡):
    전사기가 보컬을 거의 못 잡은 곡이 있어 vocal 스템의 span 이 0.00~0.05 였다.
    그걸 고르면 172초 곡에 타일 10개짜리 채보가 나온다. 반대로 synth 리드는
    간격의 68%가 120ms 미만이라 사람이 칠 수 없었다.

    그래서 이름이 아니라 '나올 채보'로 고른다:
      span   곡 전체를 덮어야 한다. 반쯤 덮으면 나머지는 죽은 시간이다.
      tight  못 치는 간격의 비율만큼 그대로 깎는다.
      rate   너무 성기면 지루하고 너무 빽빽하면 못 친다. 로그 대칭으로 본다
             (0.75/s 와 3.0/s 가 1.5/s 에서 같은 거리).
    """
    density = math.exp(-((math.log(st["rate"] / IDEAL_RATE)) ** 2) / (2 * 0.7 ** 2))
    return st["span"] * (1.0 - st["tight"]) * density


def pick_melody(tracks, want, tmap, dur, verbose=True):
    """멜로디 트랙 선택. --melody 로 라벨 부분일치 또는 인덱스, 없으면 점수 최고."""
    if want is not None:
        if want.isdigit():
            return int(want)
        for i, tr in enumerate(tracks):
            if want.lower() in tr["label"].lower():
                return i
        raise SystemExit("--melody %r 에 맞는 트랙이 없다. 목록: %s"
                         % (want, [t["label"] for t in tracks]))

    scored = []
    for i, tr in enumerate(tracks):
        st = track_stats(tr, tmap, dur)
        # 드럼은 멜로디가 아니다. 리듬은 이미 모든 타일이 표현하고 있다.
        scored.append((i, st, 0.0 if (st is None or tr["drums"]) else melody_score(st)))
    best = max(scored, key=lambda s: s[2])
    assert best[2] > 0.0, "채보로 쓸 만한 트랙이 없다"
    if verbose:
        for i, st, sc in scored:
            mark = "▶" if i == best[0] else " "
            if st is None:
                print("    %s[%d] %-24s 노트 부족" % (mark, i, tracks[i]["label"][:24]))
            else:
                print("    %s[%d] %-24s %s점수 %.3f (온셋 %d · 덮음 %.2f · 촘촘 %.2f · %.2f타/초)"
                      % (mark, i, tracks[i]["label"][:24],
                         "드럼 " if tracks[i]["drums"] else "", sc,
                         st["onsets"], st["span"], st["tight"], st["rate"]))
    return best[0]


# ---------------------------------------------------------------- 검증
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
    ap.add_argument("midi", nargs="+")
    ap.add_argument("--name", default=None)
    ap.add_argument("--title", default=None)
    ap.add_argument("--melody", "--melody-track", dest="melody", default=None,
                    help="멜로디 트랙: 라벨 부분일치 또는 인덱스 "
                         "(기본: vocal 라벨, 없으면 최고 성부)")
    ap.add_argument("--no-fill", action="store_true",
                    help="2박 초과 공백을 채우지 않고 에러로 처리")
    ap.add_argument("--tempo-tol", type=float, default=0.10,
                    help="이 비율 안쪽의 템포 변화는 측정 잡음으로 보고 합친다 "
                         "(전사 MIDI 대응, 0 이면 원본 템포맵 그대로)")
    args = ap.parse_args()

    name = args.name or os.path.splitext(os.path.basename(args.midi[0]))[0]
    title = args.title or name

    tracks, tempos_raw = load_model(args.midi)
    src_end_beat = max(n[0] + n[1] for tr in tracks for n in tr["notes"])

    # ── 템포 잡음 제거 (전사 MIDI 대응) ─────────────────────────
    tempos_clean, drift_s = dejitter_tempos(tempos_raw, src_end_beat, args.tempo_tol)
    if len(tempos_clean) < len(tempos_raw):
        print("  템포 정리: 이벤트 %d개 -> %d개 (측정 잡음 · 전사 대비 최대 %.1fms)"
              % (len(tempos_raw), len(tempos_clean), drift_s * 1000.0))
        print("     오디오도 같은 템포맵으로 렌더하므로 채보-오디오 오차는 0이다.")

    tmap_pick = TempoMap(tempos_clean)
    print("입력 %d파일 -> 트랙 %d개" % (len(args.midi), len(tracks)))
    mel_i = pick_melody(tracks, args.melody, tmap_pick, tmap_pick.sec_at(src_end_beat))
    print("  멜로디 = %s" % tracks[mel_i]["label"])

    # ── 렌더-채보 동시 양자화 ────────────────────────────────────
    # 연주 전사는 노트가 격자 밖이다. 채보만 양자화하면 오디오와 어긋나므로
    # '렌더할 노트 자체'를 같은 격자로 스냅한다. 둘은 정의상 일치하게 된다.
    snap_max = 0.0
    for tr in tracks:
        snapped = []
        for b, d, p, v in tr["notes"]:
            qb = q12(b)
            snap_max = max(snap_max, abs(b - qb))
            snapped.append((qb, d, p, v))
        tr["notes"] = snapped
    if snap_max > 1e-9:
        print("  양자화: 전 트랙 1/12 격자 스냅, 최대 이동 %.4f박" % snap_max)

    raw_n = len(tracks[mel_i]["notes"])
    onsets = sorted(set(n[0] for n in tracks[mel_i]["notes"]))
    if len(onsets) < raw_n:
        print("  코드 합침: 노트 %d -> 온셋 %d" % (raw_n, len(onsets)))

    # ── 카운트인 시프트 (오디오·템포·온셋을 전부 같이 민다) ─────
    shift = max(0.0, LEAD_BEATS - onsets[0])
    tempos = [(0.0, tempos_clean[0][1])] + [
        (b + shift, bpm) for b, bpm in tempos_clean if b > 0]
    if shift > 0:
        onsets = [q12(o + shift) for o in onsets]
        for tr in tracks:
            tr["notes"] = [(b + shift, d, p, v) for b, d, p, v in tr["notes"]]
        print("  카운트인: 전체 +%.4g박 시프트 (첫 온셋 %.4g박)" % (shift, onsets[0]))
    tmap = TempoMap(tempos)

    # ── 채보는 항상 카운트인 직후(4박)에 시작한다 ────────────────
    # 멜로디가 곡 한참 뒤에 진입해도(보컬 스템 실측 48박 = 22초) 죽은
    # 인트로를 만들지 않는다 — 첫 멜로디까지 2박 걸음 채움 타일이 아래
    # 공백 채움 루프에서 자동으로 놓인다.
    intro_fills = 0
    if onsets[0] > LEAD_BEATS + 1e-9:
        intro_fills = 1  # 실제 개수는 공백 채움 루프가 센다 — 시드만 기록
        onsets.insert(0, LEAD_BEATS)
    base_bpm = dominant_bpm(tempos, onsets[0], onsets[-1])

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
    if filled:
        print("  채움 타일 %d개 (2박 초과 공백%s — 지속음/반주 위를 밟는다)"
              % (len(filled), " · 인트로 포함" if intro_fills else ""))

    gaps = [onsets[i] - onsets[i - 1] for i in range(1, len(onsets))]
    assert all(0 < g <= MAX_HOP + 1e-9 for g in gaps), \
        "간격 위반: %s" % [g for g in gaps if not (0 < g <= MAX_HOP + 1e-9)]
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

    # ── 렌더 ────────────────────────────────────────────────────
    end_beat = max(onsets[-1],
                   max(n[0] + n[1] for tr in tracks for n in tr["notes"]))
    total = int((tmap.sec_at(end_beat) + 1.0) * SR)
    n_notes = sum(len(tr["notes"]) for tr in tracks)
    print("  렌더: %.1f초 · %d트랙 %d노트 (순수 파이썬 — 긴 곡은 수십 초 걸린다)"
          % (total / SR, len(tracks), n_notes))
    buf = [0.0] * total
    for i, tr in enumerate(tracks):
        wave, amp, duty = track_voice(tr["label"], i == mel_i)
        for b, d, p, v in tr["notes"]:
            t0 = tmap.sec_at(b)
            if tr["drums"]:
                render_drum(buf, t0, p, v)
            else:
                dur_s = tmap.sec_at(b + d) - t0
                render_tone(buf, t0, dur_s, p, wave, amp * v / 96.0, duty)
    buf = normalize(buf)

    os.makedirs(os.path.join(HERE, "assets"), exist_ok=True)
    write_wav(os.path.join(HERE, "assets", "%s.wav" % name), buf)

    meta = {
        "bpm": base_bpm,
        "sample_rate": SR,
        "duration_s": len(buf) / SR,
        "source_midi": [os.path.basename(p) for p in args.midi],
        "melody_onsets_beats": onsets,
        "speed_marks_beats": speed_marks,
        "start_offset_ms": start_offset_ms,
        "quant_max_err_beats": snap_max,
        "inserted_speed_tiles": inserted,
        "filled_gap_tiles": filled,
    }
    meta_path = os.path.join(HERE, "assets", "%s.json" % name)
    json.dump(meta, open(meta_path, "w"), indent=1)

    # 정답 벽시계 (템포 맵 직접 적분) — 검증의 기준
    expected = [start_offset_ms] + [tmap.sec_at(o) * 1000.0 for o in onsets]
    json.dump({"hit_times_ms": expected, "chart": "res://charts/%s.tres" % name},
              open(os.path.join(HERE, "assets", "%s.expected.json" % name), "w"),
              indent=1)

    print("%s.wav  %.1fs · 기준 %.6g bpm · 온셋 %d · 속도표시 %d"
          % (name, len(buf) / SR, base_bpm, len(onsets), len(speed_marks)))

    # ── 채보 생성 ───────────────────────────────────────────────
    make_charts.chart_from_song(meta_path, name, title, "res://assets/%s.wav" % name)

    # ── 검증 1: 파일을 읽어 되계산한 히트타임 vs 템포 맵 정답 ────
    replay = replay_hit_times_from_tres(os.path.join(HERE, "charts", "%s.tres" % name))
    assert len(replay) == len(expected), \
        "타일 수 불일치 %d != %d" % (len(replay), len(expected))
    worst = max(abs(a - b) for a, b in zip(replay, expected))
    print("검증(Python): .tres 되계산 vs 템포맵 정답 — 최대 오차 %.6f ms  %s"
          % (worst, "PASS" if worst < 0.01 else "FAIL"))
    if worst >= 0.01:
        raise SystemExit(1)
    print("다음: godot --headless --script res://tests/verify_chart.gd -- "
          "--chart=res://charts/%s.tres" % name)


if __name__ == "__main__":
    main()
