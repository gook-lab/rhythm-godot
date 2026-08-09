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
import bisect
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import wave

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(HERE, "tools"))

from midilib import parse_smf, TempoMap, dejitter_tempos, resample_tempos_at_tiles
from make_song import loudness_normalize
import synth
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
#
# 합성 자체는 tools/synth.py 가 한다 — 밴드리미티드 웨이브테이블 + 역할별 ADSR.
# 예전엔 여기서 나이브 사각파를 평평한 엔벌로프로 찍었는데, 그게 "원곡처럼
# 안 들린다"의 원인이었다 (synth.py 머리말에 왜인지 적어 뒀다).


def track_role(label, is_melody):
    """스템 파일명 -> (역할, 진폭).

    역할이 파형·하모닉 상한·ADSR 을 통째로 정한다(synth.ROLES).
    진폭은 믹스 균형만 잡는다 — 리드가 반주에 묻히면 채보를 귀로 못 따라간다.
    """
    l = label.lower()
    if is_melody:
        return ("lead", 0.26)
    if "bass" in l:
        return ("bass", 0.30)
    if "guitar" in l:
        return ("pluck", 0.15)
    if "piano" in l:
        return ("pluck", 0.17)
    return ("pad", 0.14)


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


# ---------------------------------------------------------------- 밀도 보강
# 멜로디 한 성부만 채보로 쓰면 그 성부가 쉬는 동안 채보도 쉰다.
# 실측(2026-08-07, 17곡): 초당 1.43~3.16탭, 그중 mureka_07 은 홉의 67%가
# '2박 걸음 채움'이었다 — 841ms 에 한 번씩, 그것도 음악에 없는 자리를 밟는다.
# 채보가 심심한 게 아니라 곡의 2/3이 비어 있었던 것이다.
#
# 얼불춤 창작마당 채보는 한 성부만 따라가지 않는다. 보컬이 쉬면 드럼을,
# 드럼이 빠지면 신스를 밟는다 — '지금 들리는 것' 위에 타일이 있다.
# 그래서 공백을 메트로놈 걸음이 아니라 '실제 반주 온셋'으로 채운다.
#
# 층은 리듬적 현저성 순이다. 위 층으로 공백이 메워지면 아래 층은 안 쓴다 —
# 조용한 구간은 킥만, 꽉 찬 구간은 킥+베이스가 자연히 얹힌다.
BACKBEAT_PITCHES = (35, 36, 38, 40)   # 킥(35,36) · 스네어(38,40)

## 천장은 '박', 바닥은 'ms' 다 — 둘의 단위가 다른 게 핵심이다.
##
## 천장(FILL_ABOVE_BEATS): 심심함은 음악적 개념이다. 채보를 짜는 사람은
##   "한 박 넘게 비면 뭐라도 밟게 한다"고 생각하지 "340ms 넘으면"이라고
##   생각하지 않는다. 박으로 두면 느린 곡·빠른 곡이 알아서 같은 '음악적' 밀도가 된다.
## 바닥(MIN_ADD_GAP_MS): 못 치는 건 물리적 개념이다. 손가락과 판정창은
##   BPM 을 모른다. 130ms 면 판정창이 ±58ms 로 눌리는데(Judge.set_gaps),
##   실측 사람 산포가 20~30ms 라 아직 여유가 있다.
## 실측(2026-08-07, 14곡)으로 고른 값이다. 천장 1박 / 바닥 150ms 에서
## 보강이 만드는 '촘촘한 자리(<150ms)' 개수가 멜로디가 원래 가진 개수와
## 같아진다 — 즉 밀도는 두 배가 되는데 난이도의 하한은 안 건드린다.
## 바닥을 130 으로 낮추면 그 수가 3~5배로 튄다(mureka_09: 64 -> 296).
FILL_ABOVE_BEATS = 1.0
MIN_ADD_GAP_MS = 150.0

## 곡에 원래 있어도 참아주는 최소 간격. 이보다 좁으면 판정창이 ±45ms 밑으로
## 눌려(Judge.set_gaps) 둘 다 치는 게 불가능해진다 — 뒤엣것은 확정 미스다.
## MIN_ADD_GAP_MS 와 값이 다른 게 맞다: 저건 '새로 놓아도 되는 간격'이라
## 보수적이어야 하고, 이건 '지워버릴 간격'이라 관대해야 한다.
FLOOR_MS = 100.0


def support_layers(tracks, mel_i):
    """멜로디 외 트랙 -> 우선순위대로 정렬된 채움 후보 층 [(이름, 온셋들)]."""
    back, hats, bass, other = set(), set(), set(), set()
    for i, tr in enumerate(tracks):
        if i == mel_i:
            continue
        is_bass = "bass" in tr["label"].lower()
        for b, _d, p, _v in tr["notes"]:
            if tr["drums"]:
                (back if p in BACKBEAT_PITCHES else hats).add(b)
            elif is_bass:
                bass.add(b)
            else:
                other.add(b)
    return [("드럼 백비트", sorted(back)), ("베이스", sorted(bass)),
            ("그 외 성부", sorted(other)), ("하이햇", sorted(hats))]


def enrich_onsets(onsets, layers, tmap, fill_above_beats, min_gap_ms, verbose=True):
    """공백에 반주 온셋을 얹는다. 층을 순서대로 훑되 이미 메워진 공백은 건너뛴다.

    후보는 전부 이미 1/12 격자 위에 있다(전 트랙을 같은 격자로 스냅했으므로).
    따라서 격자·양자화 불변식은 여기서 깨질 수 없다.
    """
    # sec_at 은 템포 항목 수에 선형이라 수천 번 부르면 느리다. 격자 칸으로 메모한다.
    memo = {}

    def sec(beat):
        k = round(beat * GRID)
        if k not in memo:
            memo[k] = tmap.sec_at(beat)
        return memo[k]

    cur = list(onsets)
    for label, pool in layers:
        if not pool:
            continue
        added = []
        for k in range(len(cur) - 1):
            a, b = cur[k], cur[k + 1]
            if b - a <= fill_above_beats + 1e-9:
                continue
            lo = bisect.bisect_right(pool, a)
            hi = bisect.bisect_left(pool, b)
            last = a
            for c in pool[lo:hi]:
                if (sec(c) - sec(last)) * 1000.0 < min_gap_ms:
                    continue
                if (sec(b) - sec(c)) * 1000.0 < min_gap_ms:
                    continue
                added.append(c)
                last = c
        if added:
            cur = sorted(set(cur) | set(added))
            if verbose:
                print("    +%-10s 타일 %d개" % (label, len(added)))
    return cur


def drop_unhittable(onsets, protect, tmap, floor_ms, verbose=True):
    """물리적으로 칠 수 없는 간격을 없앤다. 전사 잡음 청소다.

    실측(2026-08-07): 전사 멜로디에 1/12박 간격으로 붙은 온셋 쌍이 있고,
    300~375bpm 구간이면 그게 17~33ms 다. 판정창은 이웃까지 거리의 45%로
    눌리므로(Judge.set_gaps) 17ms 간격이면 창이 ±7ms — 둘 다 치는 건 불가능하고
    뒤엣것은 확정 미스다. 난이도가 아니라 결함이다.

    보강 타일의 바닥(min_gap_ms)과 다른 값인 게 맞다. 저건 '우리가 새로
    놓아도 되는 최소 간격'이라 보수적이어야 하고, 이건 '곡에 원래 있어도
    참아주는 최소 간격'이라 관대해야 한다. 빠른 구간을 통째로 지우면 안 된다.

    protect 에 든 격자 칸(속도 변경 타일)은 절대 안 버린다 — 그 타일이 없으면
    그 구간의 배속이 통째로 틀리기 때문이다. 대신 그 옆엣것을 버린다.
    """
    memo = {}

    def sec(beat):
        k = round(beat * GRID)
        if k not in memo:
            memo[k] = tmap.sec_at(beat)
        return memo[k]

    def is_protected(o):
        return round(o * GRID) in protect

    kept = [onsets[0]]
    dropped = []
    stuck = 0
    for o in onsets[1:]:
        if (sec(o) - sec(kept[-1])) * 1000.0 >= floor_ms:
            kept.append(o)
            continue
        # 너무 붙었다. 하나는 버려야 한다.
        if is_protected(o) and not is_protected(kept[-1]) and (
                len(kept) == 1
                or (sec(o) - sec(kept[-2])) * 1000.0 >= floor_ms):
            dropped.append(kept[-1])   # 속도 타일이 이긴다
            kept[-1] = o
        elif is_protected(o) and is_protected(kept[-1]):
            kept.append(o)             # 둘 다 못 버린다 — 어쩔 수 없다
            stuck += 1
        else:
            dropped.append(o)
    if verbose and dropped:
        print("  못 치는 타일 정리: %d개 제거 (간격 < %.0fms · 전사 잡음)"
              % (len(dropped), floor_ms))
    if verbose and stuck:
        print("     !! 속도 타일끼리 %.0fms 안에 붙은 곳 %d군데 — 버릴 수 없다"
              % (floor_ms, stuck))
    return kept


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
    m = re.search(r"ghost_tiles = PackedInt32Array\(([^)]*)\)", t)
    ghosts = set(int(x) for x in m.group(1).split(",")) if m else set()
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
    # 고스트(자동 통과) 타일은 밟지 않으므로 정답(온셋 벽시계)과의 비교에서 뺀다.
    # 시간 누적에는 위에서 이미 기여했다 — 서브홉의 합이 원래 홉이다.
    return [v for i, v in enumerate(out) if i not in ghosts]


# ---------------------------------------------------------------- 원곡 오디오 채택
# GM 드럼: 킥 35/36 · 스네어 38/40 · 저탐 41/43. 정렬 계측에 이것만 쓴다 —
# hat 은 8분음표로 깔려 있어 어느 오프셋에나 겹치므로 판별력을 죽인다.
KICK_SNARE = frozenset((35, 36, 38, 40, 41, 43))

# 정렬 게이트. 구간별 국소 오프셋의 산포가 이걸 넘으면 원곡 채택을 거부한다.
# 근거(2026-08-10, 과부하 루프 실측): 원시 전사 맵은 잔차 σ 2.2ms · 범위 8ms 로
# 정렬됐고, dejitter 맵은 σ 7.8ms · 범위 48ms 로 어긋났다. 게이트는 그 사이 —
# '원시 맵 수준으로 붙어야 통과'이면서 측정 잡음(±5ms)에는 관대하게.
ALIGN_SD_GATE_MS = 8.0
ALIGN_RANGE_GATE_MS = 25.0


def _decode_audio_mono48k(path):
    """원곡(mp3 등) -> 48kHz 모노 float 리스트. macOS afconvert 를 쓴다."""
    fd, tmp = tempfile.mkstemp(suffix=".wav")
    os.close(fd)
    try:
        r = subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@%d" % SR,
                            "-c", "1", path, tmp], capture_output=True)
        if r.returncode != 0:
            raise SystemExit("afconvert 실패 (macOS 전용): %s"
                             % r.stderr.decode(errors="replace").strip())
        w = wave.open(tmp)
        n = w.getnframes()
        raw = w.readframes(n)
        w.close()
    finally:
        os.unlink(tmp)
    import struct as _s
    return [v / 32768.0 for v in _s.unpack("<%dh" % n, raw)]


def _flux(samples, hop=240):
    """에너지 플럭스 (프레임 RMS 의 양의 차분). 온셋이 여기서 피크로 선다."""
    rms = []
    for i in range(0, len(samples) - hop, hop):
        s = 0.0
        for v in samples[i:i + hop]:
            s += v * v
        rms.append(math.sqrt(s / hop))
    return [max(0.0, rms[i] - rms[i - 1]) for i in range(1, len(rms))], SR / hop


def _flux_score(flux, fps, onsets_s, off):
    s = 0.0
    for t in onsets_s:
        x = (t + off) * fps
        i = int(x)
        if 0 <= i < len(flux) - 1:
            s += flux[i] + (flux[i + 1] - flux[i]) * (x - i)
    return s / max(len(onsets_s), 1)


def adopt_original_audio(path, tmap, tracks, name):
    """원곡을 게임 타임라인에 정렬해 채택한다. 반환: (버퍼, 메타 필드).

    가정하지 않고 잰다: 킥·스네어의 채보 시각열을 원곡 플럭스에 상호상관해
    전역 오프셋을 찾고, 곡을 6구간으로 잘라 국소 오프셋의 산포를 계측한다.
    산포가 게이트를 넘으면 실패 처리 — 어긋난 원곡으로 게임이 만들어지는 것보다
    변환이 죽는 쪽이 낫다.
    """
    samples = _decode_audio_mono48k(path)
    flux, fps = _flux(samples)

    dr_beats = sorted(set(
        n[0] for tr in tracks if tr["drums"] for n in tr["notes"]
        if n[2] in KICK_SNARE))
    if len(dr_beats) < 30:   # 드럼이 없거나 빈약하면 전체 온셋으로 폴백
        dr_beats = sorted(set(n[0] for tr in tracks for n in tr["notes"]))
    dr_sec = [tmap.sec_at(b) for b in dr_beats]

    # 전역 오프셋: 5ms 성김 -> 1ms 정밀. 카운트인만큼 음수가 정상이다.
    best_s, best_o = -1.0, 0.0
    off = -6.0
    while off <= 1.0:
        s = _flux_score(flux, fps, dr_sec, off)
        if s > best_s:
            best_s, best_o = s, off
        off += 0.005
    for k in range(-10, 11):
        o = best_o + k * 0.001
        s = _flux_score(flux, fps, dr_sec, o)
        if s > best_s:
            best_s, best_o = s, o

    # 구간별 국소 오프셋 -> 산포. 드리프트가 있으면 여기서 드러난다.
    span = dr_sec[-1] - dr_sec[0]
    locals_ms = []
    for wnd in range(6):
        lo = dr_sec[0] + span * wnd / 6.0
        hi = dr_sec[0] + span * (wnd + 1) / 6.0
        seg = [t for t in dr_sec if lo <= t < hi]
        if len(seg) < 8:
            continue
        bs, bo = -1.0, best_o
        for k in range(-60, 61):
            o = best_o + k * 0.001
            s = _flux_score(flux, fps, seg, o)
            if s > bs:
                bs, bo = s, o
        locals_ms.append((bo - best_o) * 1000.0)
    mean = sum(locals_ms) / len(locals_ms)
    sd = math.sqrt(sum((v - mean) ** 2 for v in locals_ms) / len(locals_ms))
    rng = max(locals_ms) - min(locals_ms)
    print("  원곡 정렬: 오프셋 %+.1fms · 구간 산포 σ %.1fms · 범위 %.1fms  (%s)"
          % (best_o * 1000.0, sd, rng,
             " ".join("%+.0f" % v for v in locals_ms)))
    if sd > ALIGN_SD_GATE_MS or rng > ALIGN_RANGE_GATE_MS:
        raise SystemExit(
            "원곡 정렬 실패: σ %.1fms (게이트 %.0f) · 범위 %.1fms (게이트 %.0f)\n"
            "  이 오디오는 이 스템의 곡이 아니거나, 전사가 원곡을 따라가지 못한다."
            % (sd, ALIGN_SD_GATE_MS, rng, ALIGN_RANGE_GATE_MS))

    # 채보 시각 t 의 소리는 원곡 (t + off) 에 있다 -> 원곡을 -off 만큼 민다.
    lead = int(round(-best_o * SR))
    if lead >= 0:
        buf = [0.0] * lead + samples
    else:
        buf = samples[-lead:]
    return buf, {
        "original_audio": os.path.basename(path),
        "align_offset_ms": best_o * 1000.0,
        "align_local_ms": locals_ms,
        "align_sd_ms": sd,
    }


## 속도 표시: 템포 구간 -> (박, 배율) 목록. 채보의 배속 체계는 base_bpm 기준이다.
def speed_marks_from(tempos, tmap, onsets, base_bpm):
    marks = []
    # 첫 타일의 배율은 1.0 이 아닐 수 있다. base_bpm 은 '가장 오래 가는' 템포라
    # 곡 시작의 템포와 다를 수 있기 때문이다 (Mureka 2번: 앞 4박만 300bpm,
    # 나머지 118bpm). 1.0 으로 가정하면 그 앞구간이 통째로 누락돼
    # 히트타임이 25.7ms 어긋난다 — 타일 0 에 배율을 명시해 둔다.
    prev_mult = tmap.bpm_at(onsets[0]) / base_bpm
    if abs(prev_mult - 1.0) > 1e-9:
        marks.append([q12(onsets[0]), prev_mult])
    for beat, bpm in tempos:
        if beat < onsets[0] - 1e-9 or beat > onsets[-1] + 1e-9:
            continue
        mult = bpm / base_bpm
        if abs(mult - prev_mult) > 1e-9:
            marks.append([q12(beat), mult])
            prev_mult = mult
    return marks


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
    ap.add_argument("--fill-above-beats", type=float, default=FILL_ABOVE_BEATS,
                    help="이보다 긴 공백(박)은 반주(드럼·베이스·기타 성부) 온셋으로 "
                         "채운다. 0 이면 멜로디만 쓴다 (기본 %g)" % FILL_ABOVE_BEATS)
    ap.add_argument("--min-gap-ms", type=float, default=MIN_ADD_GAP_MS,
                    help="보강 타일이 만들 수 있는 최소 간격. 판정창이 이웃에 "
                         "닿지 않는 하한이다 (기본 %.0f)" % MIN_ADD_GAP_MS)
    ap.add_argument("--floor-ms", type=float, default=FLOOR_MS,
                    help="이보다 좁은 간격은 뒤 타일을 버려서 없앤다(전사 잡음 "
                         "청소). 0 이면 원본 그대로 (기본 %.0f)" % FLOOR_MS)
    ap.add_argument("--audio", default=None,
                    help="원곡 오디오(mp3 등)를 이 파일로 채택한다 — 신스 렌더 대신. "
                         "채보 시간축은 원시 전사 맵에 타일 해상도로 고정되고 "
                         "(midilib.resample_tempos_at_tiles), 킥·스네어 상호상관으로 "
                         "자동 정렬 후 산포 게이트(σ%.0fms·범위%.0fms)를 통과해야 한다"
                         % (ALIGN_SD_GATE_MS, ALIGN_RANGE_GATE_MS))
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
    # 템포 변경 지점도 1/12 격자 위로 스냅한다. 노트에 한 것과 같은 이유이자
    # 같은 원칙이다 — 게임은 속도를 '타일 단위'로만 바꿀 수 있고 타일은 격자
    # 위에만 놓이므로, 격자 밖 변경점은 채보로 표현할 방법이 아예 없다.
    # 스냅하지 않으면 채보는 반올림한 자리에서, 정답 시각은 원래 자리에서
    # 속도를 바꿔 그 타일 하나의 홉이 통째로 어긋난다(실측 15.1ms).
    # 여기서 스냅한 맵으로 오디오까지 렌더하므로 셋(채보·정답·오디오)이 일치한다.
    snapped = {}
    for b, bpm in tempos_clean:
        snapped[0.0 if b <= 0 else q12(b + shift)] = bpm  # 같은 칸이면 뒤가 이긴다
    tempos = sorted(snapped.items())
    if tempos[0][0] > 0.0:
        tempos.insert(0, (0.0, tempos_clean[0][1]))
    moved = sum(1 for b, _ in tempos_clean if b > 0 and abs(q12(b + shift) - (b + shift)) > 1e-9)
    if moved:
        print("  템포 변경점 %d개를 1/12 격자로 스냅 (타일 위에서만 속도가 바뀔 수 있다)"
              % moved)
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
    #
    # 밀도 보강보다 '먼저' 해야 한다. 속도 타일은 위치를 못 옮기지만(옮기면
    # 그 구간의 배속이 통째로 틀린다) 보강 타일은 얼마든지 안 놓을 수 있다.
    # 순서가 반대면 보강이 채워 둔 자리 바로 옆(1/12박 = 142bpm에서 35ms)에
    # 속도 타일이 끼어들어 물리적으로 못 치는 자리가 생긴다 — 실측 15개.
    # 지금 순서면 보강의 최소 간격 검사가 속도 타일까지 같이 피해 간다.
    #
    # 범위는 루프 '전에' 잡아 둔다. 안에서 onsets 에 append 하면 onsets[-1] 이
    # 방금 넣은 타일로 바뀌어, 그 뒤의 변경점이 전부 `qb < onsets[-1]` 에서
    # 탈락한다 — 실측(Mureka 7번) 16개 변경점 중 1개만 삽입되고 14개가 조용히
    # 누락돼 그 타일들의 홉이 통째로 어긋났다(최대 15.1ms).
    lo, hi = onsets[0], onsets[-1]
    have = set(round(o * GRID) for o in onsets)   # 격자 칸 번호로 비교한다
    inserted = []
    for beat, _bpm in tempos:
        qb = q12(beat)
        cell = round(qb * GRID)
        if lo < qb < hi and cell not in have:
            have.add(cell)
            onsets.append(qb)
            inserted.append(qb)
    onsets.sort()
    if inserted:
        print("  속도 타일 삽입 %d개 (템포 변경 지점에 노트가 없었다): %s%s"
              % (len(inserted), ["%.4g박" % b for b in inserted[:6]],
                 " ..." if len(inserted) > 6 else ""))

    # ── 밀도 보강: 공백을 반주 온셋으로 채운다 (걸음 타일보다 먼저) ──
    # 여기서 채워진 자리는 전부 '실제로 소리가 나는' 자리다.
    # 아래 2박 걸음 채움은 이제 진짜 무음 구간에만 남는다.
    mel_only = len(onsets)
    if args.fill_above_beats > 0:
        print("  밀도 보강 (공백 > %g박 을 반주로 채운다, 최소 간격 %.0fms):"
              % (args.fill_above_beats, args.min_gap_ms))
        onsets = enrich_onsets(onsets, support_layers(tracks, mel_i), tmap,
                               args.fill_above_beats, args.min_gap_ms)
        print("    타일 %d개 -> %d개 (초당 %.2f -> %.2f탭)"
              % (mel_only, len(onsets),
                 mel_only / tmap.sec_at(onsets[-1]),
                 len(onsets) / tmap.sec_at(onsets[-1])))

    # ── 못 치는 간격 정리 (전사 잡음) ───────────────────────────
    # 속도가 바뀌는 자리는 전부 보호한다. `inserted`(노트가 없어서 새로 넣은 것)
    # 만 넘기면 안 된다 — 원래 노트와 자리가 겹쳤던 변경점은 거기 없어서
    # 정리 단계가 지워버릴 수 있고, 그러면 아래 '속도 변경은 타일 위에'
    # 불변식이 깨진다. 템포 맵의 모든 변경점을 칸으로 넘긴다.
    if args.floor_ms > 0:
        onsets = drop_unhittable(
            onsets, set(round(q12(b) * GRID) for b, _ in tempos),
            tmap, args.floor_ms)

    # ── 2박 초과 공백 채움 (진짜 무음 구간에만 남는다) ──────────
    # 격자 '칸' 정수로만 계산한다. 박(float)으로 나누면 반올림이 마지막 조각을
    # 밀어 2박을 넘길 수 있다.
    #
    # 고르게 나눈다. 예전엔 2박씩 그리디로 놓았는데(a+2, a+4, ...), 그러면
    # 2와 1/12박 짜리 공백에서 마지막 조각이 1/12박만 남는다 — 172bpm 이면
    # 29ms 라 물리적으로 못 친다. 같은 공백을 반으로 나누면 두 조각 다 1과
    # 1/24박이라 편하다. 리듬적으로도 등분이 걸음답다.
    MAX_CELLS = int(round(MAX_HOP * GRID))
    filled = []
    out = [onsets[0]]
    for o in onsets[1:]:
        cells = int(round((o - out[-1]) * GRID))
        if cells > MAX_CELLS:
            if args.no_fill:
                raise SystemExit("공백 %.4g박 @ %.4g박 — 한 타일 최대 2박 (--no-fill)"
                                 % (o - out[-1], out[-1]))
            a = out[-1]
            n = -(-cells // MAX_CELLS)     # 조각 수 (올림)
            for k in range(1, n):
                t = q12(a + round(cells * k / n) / GRID)
                out.append(t)
                filled.append(t)
        out.append(o)
    onsets = out
    if filled:
        print("  채움 타일 %d개 (2박 초과 공백%s — 지속음/반주 위를 밟는다)"
              % (len(filled), " · 인트로 포함" if intro_fills else ""))

    gaps = [onsets[i] - onsets[i - 1] for i in range(1, len(onsets))]
    assert all(0 < g <= MAX_HOP + 1e-9 for g in gaps), \
        "간격 위반: %s" % [g for g in gaps if not (0 < g <= MAX_HOP + 1e-9)]
    assert all(abs(g * GRID - round(g * GRID)) < 1e-6 for g in gaps), "격자 위반"

    # ── 원곡 오디오 모드: 시간축을 원시 전사 맵에 '타일 해상도'로 고정 ──
    # dejitter 맵은 원시 맵에서 벽시계가 떠내려간다(실측 mureka_09: 최대 92.2ms,
    # 곡내 방황 -21~-69ms). 렌더 오디오는 같은 맵으로 만드니 문제가 없지만,
    # 원곡은 원시 타임라인 위에 있다(원시 맵 대비 실측 잔차 σ 2.2ms).
    # 경계를 타일 위에만 두는 시간 보존 리샘플(midilib)이면 타일 벽시계가
    # 원시 맵과 정확히 같아진다 — 남는 채보-원곡 오차는 격자 스냅분뿐이다.
    # 마커 '표시'는 의도된 변경(정리 맵)만 쓴다 — 홉 배율은 전사 잡음(±7%)이다.
    display_marks = speed_marks_from(tempos, tmap, onsets, base_bpm)
    if args.audio:
        raw_shifted = sorted((b + shift, v) for b, v in tempos_raw)
        if raw_shifted[0][0] > 1e-12:
            raw_shifted.insert(0, (0.0, raw_shifted[0][1]))
        tempos = resample_tempos_at_tiles(
            raw_shifted, onsets, max(onsets[-1], src_end_beat + shift))
        tmap = TempoMap(tempos)
        print("  원곡 모드: 템포를 타일 해상도로 리샘플 — 구간 %d개 (타일 벽시계 = 원시 전사 맵)"
              % len(tempos))

    # ── 밀도 보고 ───────────────────────────────────────────────
    # 채보가 심심한지/불가능한지는 박이 아니라 '초당 몇 번 누르나'로 결정된다.
    # 생성할 때마다 눈에 보이게 찍는다 — 곡을 넣고 나서야 알아채면 늦다.
    ms_gaps = sorted((tmap.sec_at(onsets[i]) - tmap.sec_at(onsets[i - 1])) * 1000.0
                     for i in range(1, len(onsets)))
    span_s = tmap.sec_at(onsets[-1]) - tmap.sec_at(onsets[0])
    tight_n = sum(1 for g in ms_gaps if g < TIGHT_MS)
    print("  밀도: 타일 %d · %.2f탭/초 · 간격 중앙 %.0fms (최소 %.0f · 최대 %.0f)"
          % (len(onsets), len(onsets) / span_s, ms_gaps[len(ms_gaps) // 2],
             ms_gaps[0], ms_gaps[-1]))
    if tight_n:
        print("     !! %.0fms 미만 간격 %d개 — 판정창이 이웃에 닿기 직전이다"
              % (TIGHT_MS, tight_n))

    # ── 속도 표시 + 시작점 (전부 벽시계는 템포 맵이 정답) ────────
    # 원곡 모드에선 tempos 가 홉 단위 리샘플이라 마크가 타일마다 붙을 수 있다 —
    # 그건 배속(기계)이고, 표시는 위의 display_marks 가 따로 담당한다.
    speed_marks = speed_marks_from(tempos, tmap, onsets, base_bpm)
    # 이 파일 전체에서 가장 중요한 불변식: 속도가 바뀌는 지점에는 반드시 타일이
    # 있어야 한다. 게임은 홉 하나를 상수 배속으로만 돌리므로, 홉 '중간'의 변경은
    # 표현할 방법이 없고 그 홉의 길이가 통째로 틀린다.
    # 위의 강제 삽입이 이걸 보장하는데, 한 번 조용히 깨진 적이 있다(순회 중
    # onsets 변경으로 16개 중 1개만 삽입 -> 15.1ms). 결과를 직접 잠근다.
    cells = set(round(o * GRID) for o in onsets)
    off_tile = [b for b, _ in speed_marks if round(b * GRID) not in cells]
    assert not off_tile, "속도 변경이 타일 위에 없다 (홉 중간 변경은 표현 불가): %s" % off_tile

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
        role, amp = track_role(tr["label"], i == mel_i)
        for b, d, p, v in tr["notes"]:
            t0 = tmap.sec_at(b)
            if tr["drums"]:
                synth.drum(buf, t0, p, v)
            else:
                dur_s = tmap.sec_at(b + d) - t0
                synth.render(buf, t0, dur_s, synth.midi_hz(p), role,
                             amp * v / 96.0)
    # 공간감. 마른 신호는 음색을 아무리 다듬어도 '음원'이 아니라 '테스트 톤'이다.
    synth.slapback(buf)
    # 피크가 아니라 '체감 크기'로 맞춘다. 스템을 여러 개 합치면 우연히 정렬된
    # 피크 하나가 전체 게인을 정해버려서 곡마다 체감 크기가 4~6dB 씩 벌어지고,
    # 그러면 같은 판정 효과음이 곡마다 다른 크기로 얹힌다.
    buf = loudness_normalize(buf)

    os.makedirs(os.path.join(HERE, "assets"), exist_ok=True)
    write_wav(os.path.join(HERE, "assets", "%s.wav" % name), buf)

    # ── 원곡 채택: 신스 렌더를 원곡으로 덮어쓴다 ─────────────────
    # 렌더 블록을 조건 분기로 감싸지 않은 이유: 신스 경로가 별도로 다듬어지는
    # 중이라 재들여쓰기는 충돌만 만든다. 낭비는 렌더 수십 초 — 곡당 1회다.
    audio_meta = {}
    if args.audio:
        buf, audio_meta = adopt_original_audio(args.audio, tmap, tracks, name)
        buf = loudness_normalize(buf)
        write_wav(os.path.join(HERE, "assets", "%s.wav" % name), buf)
        print("  원곡 채택: %s -> assets/%s.wav (신스 렌더 대체)"
              % (os.path.basename(args.audio), name))

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
        # 밀도 보강 이력. 'melody_onsets_beats' 는 이제 멜로디만이 아니라
        # 멜로디+반주라서, 순수 멜로디가 몇 개였는지를 따로 남긴다.
        "melody_only_count": mel_only,
        "fill_above_beats": args.fill_above_beats,
        "min_add_gap_ms": args.min_gap_ms,
        "taps_per_sec": len(onsets) / span_s,
        # 마커를 '표시할' 변경(정리 맵의 의도된 것). 원곡 모드에선
        # speed_marks_beats(홉 단위 보정)와 다르다 — Chart.speed_display 로 간다.
        "speed_display_beats": [b for b, _ in display_marks],
    }
    meta.update(audio_meta)
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
    # 누적 오차만 보면 안 된다. 긴 채보일수록 반올림이 쌓여 한계가 곡 길이에
    # 따라 달라지고, 그렇다고 느슨하게 잡으면 진짜 버그를 놓친다.
    #
    # '타일당 오차'가 훨씬 예리한 지표다. 의미론 버그(속도 변경이 타일 위에
    # 없다, 배율이 틀렸다, U턴이 뒤집혔다)는 그 타일 하나의 홉을 통째로 바꾸므로
    # 계단으로 나타난다. 부동소수점 잡음은 절대 계단을 만들지 않는다.
    # 실측 17곡: 잡음은 최대 0.0012ms/타일, 실제 버그는 1.45ms 와 11.8ms 였다.
    err = [a - b for a, b in zip(replay, expected)]
    worst = max(abs(e) for e in err)
    step = max(abs(err[i] - err[i - 1]) for i in range(1, len(err)))
    bad = step >= 0.01 or worst >= 0.5
    print("검증(Python): .tres 되계산 vs 템포맵 정답 — 타일당 %.6f ms · 누적 %.6f ms  %s"
          % (step, worst, "FAIL" if bad else "PASS"))
    if bad:
        raise SystemExit(1)
    print("다음: godot --headless --script res://tests/verify_chart.gd -- "
          "--chart=res://charts/%s.tres" % name)


if __name__ == "__main__":
    main()
