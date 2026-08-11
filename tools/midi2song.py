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


## 스템 이름 -> (역할, 진폭).
##
## 여기서 한 번 크게 틀렸다(2026-08-10). 처음엔 '채보가 따라가는 성부'에게
## 가장 큰 소리를 줬는데, 그 둘은 같은 게 아니다:
##
##   채보 멜로디는 '칠 만한' 성부다 — 너무 촘촘하면 못 치므로 탈락한다.
##   곡의 주인공은 '들리는' 성부다 — 촘촘할수록 주인공인 경우가 많다.
##
## 실측 mureka_01: 채보는 베이스(노트 268개)를 따라가는데 곡을 이끄는 건
## synth lead(노트 2,487개)다. 그런데 리드가 pad 로 분류돼 amp 0.14 —
## 전체에서 제일 조용한 값이었다. 곡의 주인공이 배경으로 깔린 것이다.
## mureka_03(1,638) · mureka_07(1,335) 도 같았다. "노래가 잘 안 들린다"의 정체.
##
## 그래서 진폭은 **악기 이름**에서 정하고, 채보 멜로디에는 배수만 얹는다 —
## 플레이어가 자기가 치는 성부를 귀로 따라갈 수 있어야 하니까.
## 라벨은 "파일명:트랙명" 이라 둘 다에서 악기를 찾는다(vocal:Singing Voice 등).
MELODY_BOOST = 1.35   # 채보가 따라가는 성부에 얹는 배수
AMP_CEIL = 0.34       # 한 성부가 믹스를 독식하지 않게


def track_role(label, is_melody):
    l = label.lower()
    if "bass" in l:
        role, amp = "bass", 0.30
    elif "guitar" in l:
        role, amp = "pluck", 0.17
    elif "piano" in l or "keys" in l:
        role, amp = "pluck", 0.18
    elif "lead" in l or "synth" in l:
        # 전사 스템에서 곡을 이끄는 경우가 가장 많은 자리다.
        role, amp = "lead", 0.23
    elif "vocal" in l or "voice" in l or "sing" in l:
        role, amp = "lead", 0.21
    elif "brass" in l or "wind" in l or "sax" in l or "horn" in l:
        role, amp = "lead", 0.21
    elif "string" in l or "pad" in l or "pipe" in l or "organ" in l:
        role, amp = "pad", 0.16
    else:
        role, amp = "pad", 0.16
    if is_melody:
        amp *= MELODY_BOOST
    return role, min(amp, AMP_CEIL)


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


# ---------------------------------------------------------------- 홀드 자동 배치
## 한 바퀴 = 2박. 스윕이 정확히 360도라 착지가 안 바뀌는 이유이자 최소 단위인 이유.
HOLD_ORBIT_BEATS = 2.0


def place_holds(onsets, mel_notes, tmap, min_gap_ms):
    """멜로디 '지속음' 위에 홀드를 놓는다. 반환: [[온셋 박, 바퀴 수], ...].

    홀드는 히트타임을 뒤로 미는 유일한 타일이라(ChartRuntime 이 홉에 홀드박을
    더한다) 오디오에 이미 동기된 온셋의 절대 박은 못 건드린다. 대신 다음
    온셋까지의 '간격'에서 2n박을 대기 대신 홀드로 바꾼다 — 다음 타일의 시각은
    그대로다 (2n박 홀드 + (g-2n)박 이동 = g박).

    조건 세 개가 전부 음악에서 온다:
      1. 노트가 실제로 그만큼 끌린다(dur >= 2n, 다음 온셋 초과분은 무시) —
         지속음 위에서만. 짧은 노트를 홀드로 만들면 소리는 끝났는데 손만
         잡혀 있는 거짓 동작이 된다.
      2. 뗀 뒤 다음 탭까지 손을 옮길 시간(이동 구간 >= min_gap_ms) — 뗌도
         판정이라, 뗌-다음 누름 간격은 보강 타일의 최소 간격과 같은 물리다.
      3. 호출 시점이 속도 타일 강제 삽입 '뒤' — 템포 변경 지점은 이미 온셋이고
         간격 안에는 온셋이 없으므로, 홀드 구간이 변경을 가로지를 수 없다.
    """
    dur_at = {}
    for b, d, _p, _v in mel_notes:
        k = round(b * GRID)
        dur_at[k] = max(dur_at.get(k, 0.0), d)
    holds = []
    for i in range(len(onsets) - 1):
        g = onsets[i + 1] - onsets[i]
        dur = dur_at.get(round(onsets[i] * GRID), 0.0)
        n = int(min(dur, g) // HOLD_ORBIT_BEATS)
        while n > 0:
            release = onsets[i] + HOLD_ORBIT_BEATS * n
            travel_ms = (tmap.sec_at(onsets[i + 1]) - tmap.sec_at(release)) * 1000.0
            if onsets[i + 1] - release > 1e-9 and travel_ms >= min_gap_ms:
                break
            n -= 1
        if n > 0:
            holds.append([onsets[i], float(n)])
    return holds


## ── 곡의 세기 곡선 ──────────────────────────────────────────────
## 밀도 보강을 곡 전체에 똑같이 걸면 채보가 평평해진다. 실측(2026-08-10):
## 10초 구간별 탭/초가 mureka_01 3.1±0.6 으로 서막도 클라이맥스도 없었다.
##
## 그런데 곡에는 기승전결이 있다 — 같은 곡의 세기 곡선이
## `▃▄▅▃█▆▅▅▇▆▆▃▃▃▃` 였다. 채보가 그걸 뭉갠 것이다:
## 조용한 구간은 반주로 억지로 채워 올리고, 시끄러운 구간은 이미 꽉 차서 더 못 올린다.
##
## 그래서 '얼마나 채울지'를 곡의 세기에 맞춘다. 난이도를 지어내지 않고
## 음악이 이미 가진 모양을 드러내는 쪽이다 — 세기가 평평한 곡은 평평하게 남는다.
INTENSITY_WINDOW = 8.0   # 초. 마디 두어 개 — 이보다 짧으면 프레이즈 단위로 요동친다
INTENSITY_SMOOTH = 2     # 이웃 창 몇 개까지 평활할지


def intensity_curve(tracks, tmap, dur):
    """0..1 세기. 온셋 밀도 0.6 + 동시에 울리는 트랙 수 0.4.

    둘을 섞는 이유: 온셋 밀도만 보면 드럼 롤 하나에 값이 튀고, 트랙 수만 보면
    다 같이 길게 끄는 패드 구간이 클라이맥스로 잡힌다.
    """
    k = max(1, int(dur / INTENSITY_WINDOW) + 1)
    ons = [0.0] * k
    act = [[0] * k for _ in tracks]
    for ti, tr in enumerate(tracks):
        for b, _d, _p, _v in tr["notes"]:
            t = tmap.sec_at(b)
            if t < 0 or t >= dur:
                continue
            j = min(int(t / INTENSITY_WINDOW), k - 1)
            ons[j] += 1
            act[ti][j] = 1
    top = max(ons) or 1.0
    ntr = max(len(tracks), 1)
    raw = [0.6 * (ons[j] / top) + 0.4 * (sum(a[j] for a in act) / ntr)
           for j in range(k)]
    # 평활. 안 하면 창 경계에서 난이도가 계단으로 튄다.
    out = []
    for j in range(k):
        lo = max(0, j - INTENSITY_SMOOTH)
        hi = min(k, j + INTENSITY_SMOOTH + 1)
        out.append(sum(raw[lo:hi]) / (hi - lo))
    span = max(out) - min(out)
    if span < 1e-6:
        return [0.5] * k          # 정말 평평한 곡은 중간 난이도로

    # 순위(백분위)로 편다. 최소-최대로 펴면 세기 분포가 한쪽에 쏠린 곡에서
    # 대부분의 구간이 0 근처에 몰려 곡 전체가 서막처럼 쉬워진다 —
    # 실측 mureka_14 가 그랬다(평균 3.55 -> 2.44탭/초).
    # 순위로 펴면 어떤 곡이든 자기 안에서 가장 조용한 구간이 서막,
    # 가장 북적이는 구간이 클라이맥스가 된다. '이 곡 안에서의 상대적 세기'가
    # 우리가 원하는 것이지 절대값이 아니다.
    order = sorted(range(k), key=lambda j: out[j])
    rank = [0.0] * k
    for pos, j in enumerate(order):
        rank[j] = pos / max(k - 1, 1)
    # 절반은 실제 세기, 절반은 순위. 진짜로 평평한 곡을 가짜 기승전결로
    # 만들지 않으면서도 범위는 다 쓴다.
    lo = min(out)
    norm = [(v - lo) / span for v in out]
    return [0.5 * norm[j] + 0.5 * rank[j] for j in range(k)]


## 세기 -> 그 구간의 채움 천장(박). 세기가 낮으면 거의 안 채우고(멜로디만),
## 높으면 반주 온셋을 촘촘히 얹는다. 낮은 쪽이 '서막', 높은 쪽이 '클라이맥스'다.
## 구간별 '목표 탭 간격'(ms). 세기 0 이면 EASY, 1 이면 HARD.
##
## 왜 박이 아니라 ms 인가: 심심함은 음악적 개념이라 박이 맞지만(공백을 채울지
## 말지), **난이도는 물리적 개념이라 ms 다** — 손과 판정창은 BPM 을 모른다.
## 박으로 잡았더니 65bpm 곡과 175bpm 곡의 체감 난이도가 세 배 벌어졌다.
##
## 300ms = 3.3탭/초(서막) · 150ms = 6.7탭/초(클라이맥스).
## 서막을 더 성기게 하면(400ms) 세기 분포가 낮게 쏠린 곡이 통째로 쉬워진다 —
## 실측 mureka_14 가 평균 3.55 -> 2.44탭/초로 떨어졌다.
CEIL_EASY_MS = 300.0
CEIL_HARD_MS = 150.0

## 최소 간격도 세기를 따른다. 서막에서는 넉넉하게, 클라이맥스에서는 조인다 —
## '어렵다'는 건 결국 손이 바빠지는 것이고, 그건 간격이 정한다.
## 115ms 는 판정창이 ±52ms 로 눌리는 지점이다(Judge.set_gaps).
## 실측 사람 산포가 20~30ms 라 아직 여유가 있고, 이 값은 이미 여러 곡에
## 자연히 존재하던 최소 간격이기도 하다.
GAP_HARD_MS = 115.0


def _at_curve(curve, tmap, beat):
    t = tmap.sec_at(beat)
    j = min(max(int(t / INTENSITY_WINDOW), 0), len(curve) - 1)
    return curve[j]


def ceiling_fn(curve, tmap, base_beats):
    """(박 -> 그 자리의 목표 탭 간격 ms).

    '채울지 말지'가 아니라 '얼마나 촘촘히'를 정한다. 이걸 게이트로만 쓰면
    멜로디가 쉬는 구간은 공백이 몇 초씩이라 어떤 천장이든 넘어서 바닥까지
    꽉 채워지고, 결과가 뒤집혀 '조용한 구간이 최대 밀도'가 된다(실측).

    base_beats(--fill-above-beats)는 서막 쪽 상한으로만 남는다 — 크게 주면
    서막이 더 성겨지고, 작게 주면 곡 전체가 촘촘해진다.
    """
    # base_beats(--fill-above-beats)는 서막 쪽 '배수'다. 기본 1.0 이면 CEIL_EASY_MS.
    # max() 로 두면 안 된다 — 기본값 1.0 에서 max(300, 400)=400 이 되어
    # CEIL_EASY_MS 를 내려도 아무 일도 안 일어난다(실제로 그랬다).
    easy = max(CEIL_EASY_MS * base_beats, CEIL_HARD_MS)
    return lambda b: easy + (CEIL_HARD_MS - easy) * _at_curve(curve, tmap, b)


def gap_fn(curve, tmap, base_ms):
    """(박 -> 그 자리의 최소 간격 ms). 서막은 넉넉, 클라이맥스는 조인다."""
    hard = min(GAP_HARD_MS, base_ms)
    return lambda b: base_ms + (hard - base_ms) * _at_curve(curve, tmap, b)


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


def enrich_onsets(onsets, layers, tmap, fill_above_beats, min_gap_ms,
                  holds=(), verbose=True):
    """공백에 반주 온셋을 얹는다. 층을 순서대로 훑되 이미 메워진 공백은 건너뛴다.

    후보는 전부 이미 1/12 격자 위에 있다(전 트랙을 같은 격자로 스냅했으므로).
    따라서 격자·양자화 불변식은 여기서 깨질 수 없다.

    holds: [[온셋 박, 바퀴]] — 홀드 구간(온셋~뗌)에는 보강을 넣지 않는다.
    키를 잡고 있는 손은 탭을 못 친다. 최소 간격도 누름이 아니라 '뗌'에서 잰다.
    """
    # sec_at 은 템포 항목 수에 선형이라 수천 번 부르면 느리다. 격자 칸으로 메모한다.
    memo = {}

    def sec(beat):
        k = round(beat * GRID)
        if k not in memo:
            memo[k] = tmap.sec_at(beat)
        return memo[k]

    hold_end = {round(b * GRID): b + HOLD_ORBIT_BEATS * n for b, n in holds}

    cur = list(onsets)
    for label, pool in layers:
        if not pool:
            continue
        added = []
        for k in range(len(cur) - 1):
            a, b = cur[k], cur[k + 1]
            # 홀드 타일이면 공백은 '뗌'부터 시작한다
            a = hold_end.get(round(a * GRID), a)
            if callable(fill_above_beats):
                # ── 목표 간격으로 '균등 분배' ──────────────────────
                # 탐욕(앞에서부터 목표만큼 띄우며 집기)은 목표의 1.35배로
                # 수렴한다: 400ms 공백에 목표 150 이면 150 을 하나 집고 남은
                # 250 은 바닥(115) 때문에 더 못 쪼갠다 — 실측 목표 150ms 에
                # 실제 201ms 였다. 공백을 n 등분하고 각 자리에 가장 가까운
                # 온셋을 집으면 목표에 실제로 닿는다.
                target = fill_above_beats(a)
                gap_ms = (sec(b) - sec(a)) * 1000.0
                n = int(round(gap_ms / target))
                if n <= 1:
                    continue
                lo = bisect.bisect_right(pool, a)
                hi = bisect.bisect_left(pool, b)
                cands = pool[lo:hi]
                if not cands:
                    continue
                floor = min_gap_ms(a) if callable(min_gap_ms) else min_gap_ms
                last = a
                for step in range(1, n):
                    want = sec(a) + gap_ms * step / n / 1000.0
                    # 이상적인 자리에 가장 가까운 후보 (양옆만 보면 된다)
                    j = bisect.bisect_left(cands, a + (b - a) * step / n)
                    best, bd = None, 1e9
                    for jj in (j - 1, j, j + 1):
                        if 0 <= jj < len(cands):
                            dd = abs(sec(cands[jj]) - want)
                            if dd < bd:
                                bd, best = dd, cands[jj]
                    # 그 자리에 음이 없으면 비워 둔다 — 없는 소리를 밟게 하지 않는다.
                    # 허용치가 좁으면 후보가 있어도 자리가 비어 밀도가 안 오른다.
                    # 0.5 -> 0.7 로 넓히니 클라이맥스가 목표에 가까워졌다.
                    if best is None or bd * 1000.0 > target * 0.7:
                        continue
                    if (sec(best) - sec(last)) * 1000.0 < floor:
                        continue
                    if (sec(b) - sec(best)) * 1000.0 < floor:
                        continue
                    added.append(best)
                    last = best
                continue

            # 고정 천장(테스트·수동 경로): 예전 그대로 '박' 게이트 + 탐욕.
            ceil = fill_above_beats
            if b - a <= ceil + 1e-9:
                continue
            lo = bisect.bisect_right(pool, a)
            hi = bisect.bisect_left(pool, b)
            last = a
            for c in pool[lo:hi]:
                floor = min_gap_ms(c) if callable(min_gap_ms) else min_gap_ms
                if (sec(c) - sec(last)) * 1000.0 < floor:
                    continue
                if (sec(b) - sec(c)) * 1000.0 < floor:
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


# ---------------------------------------------------------------- 토끼 구간
## 원작의 토끼는 대부분 곡 템포가 아니라 '채보 결정'이다. 전사 템포는
## dejitter 로 평평해져서 그대로 두면 토끼가 사실상 0개다(실측 14곡 중 13곡).
##
## 배속 m 은 벽시계를 보존한다: 홉 박자를 m배로 키우고 배율도 m배 —
## 같은 시각에 같은 탭이고, 행성만 m배로 돈다(스윕도 m배라 기하가 넓어진다).
## 그래서 조건이 전부 기하·구조에서 나온다:
##   · 구간 안 모든 간격 <= 1박 (2배 후 <= 2박 = 한 타일 최대 스윕)
##   · 홀드 없음 (홀드 바퀴는 고정 2박이라 배속과 셈이 꼬인다)
##   · 세기 상위(>= 0.7)가 8초 이상 이어질 것 — 클라이맥스에만 건다
BOOST_MULT = 2.0
BOOST_MIN_SEC = 8.0
BOOST_CURVE_MIN = 0.55   # 구간 '평균' 세기 문턱 (평균은 절정보다 낮게 잡는다)
BOOST_MAX_SECTIONS = 2
BOOST_MAX_SEC = 32.0    # 구간 상한 — 곡 절반이 토끼면 '구간'이 아니다 (mureka_06 실측 90초)


def pick_boost_sections(onsets, holds, curve, tmap):
    """[[시작 박, 끝 박, 배율], ...] — 깨끗한 구간을 세기로 선발, 최대 2개.

    처음엔 '세기 >= 임계 창'을 먼저 찾고 그 안에서 조건을 검사했는데,
    실측 14곡의 모든 클라이맥스에 >1박 간격과 홀드가 몇 개씩 끼어 있어
    구간이 갈가리 찢겨 토끼가 0개였다. 순서를 뒤집는다:
    기하적으로 깨끗한 최대 구간(간격 <= 1박 · 홀드 없음)을 전부 만들고,
    각 구간의 세기 '평균'으로 고른다 — 구간 경계가 세기 창이 아니라
    음악 구조(홀드·긴 쉼)에서 나오므로 안정적이다.
    """
    hold_cells = set(round(b * GRID) for b, _n in holds)
    spans = []
    s0 = 0
    for i in range(len(onsets) - 1):
        bad = (onsets[i + 1] - onsets[i] > MAX_HOP / BOOST_MULT + 1e-9
               or round(onsets[i] * GRID) in hold_cells)
        if bad:
            if i > s0:
                spans.append((s0, i))
            s0 = i + 1
    if len(onsets) - 1 > s0:
        spans.append((s0, len(onsets) - 1))

    out = []
    for a, b in spans:
        if b - a < 8:
            continue
        span_sec = tmap.sec_at(onsets[b]) - tmap.sec_at(onsets[a])
        if span_sec < BOOST_MIN_SEC:
            continue
        w0 = int(tmap.sec_at(onsets[a]) / INTENSITY_WINDOW)
        w1 = max(w0 + 1, int(tmap.sec_at(onsets[b]) / INTENSITY_WINDOW) + 1)
        # 너무 긴 구간은 절정 창을 중심으로 상한까지 줄인다 —
        # 곡의 절반이 토끼면 대비가 사라져 '구간'이 아니게 된다.
        if span_sec > BOOST_MAX_SEC:
            peak = max(range(w0, w1),
                       key=lambda w: curve[min(w, len(curve) - 1)])
            t_c = (peak + 0.5) * INTENSITY_WINDOW
            lo_t, hi_t = t_c - BOOST_MAX_SEC / 2, t_c + BOOST_MAX_SEC / 2
            aa = next((i for i in range(a, b + 1)
                       if tmap.sec_at(onsets[i]) >= lo_t), a)
            bb = next((i for i in range(b, a - 1, -1)
                       if tmap.sec_at(onsets[i]) <= hi_t), b)
            if bb - aa >= 8 and tmap.sec_at(onsets[bb]) - tmap.sec_at(onsets[aa]) >= BOOST_MIN_SEC:
                a, b = aa, bb
                w0 = int(tmap.sec_at(onsets[a]) / INTENSITY_WINDOW)
                w1 = max(w0 + 1, int(tmap.sec_at(onsets[b]) / INTENSITY_WINDOW) + 1)
        vals = [curve[min(w, len(curve) - 1)] for w in range(w0, w1)]
        score = sum(vals) / len(vals)
        if score < BOOST_CURVE_MIN:
            continue
        out.append((score, [onsets[a], onsets[b], BOOST_MULT]))
    out.sort(key=lambda x: -x[0])
    return [sec for _s, sec in out[:BOOST_MAX_SECTIONS]]


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
    m = re.search(r"midspin_tiles = PackedInt32Array\(([^)]*)\)", t)
    mids = [int(x) for x in m.group(1).split(",")] if m else []
    m = re.search(r"speed_changes = PackedVector2Array\(([^)]*)\)", t)
    sc = []
    if m:
        vals = [float(x) for x in m.group(1).split(",")]
        sc = list(zip([int(v) for v in vals[0::2]], vals[1::2]))
    m = re.search(r"hold_tiles = PackedVector2Array\(([^)]*)\)", t)
    hd = {}
    if m:
        vals = [float(x) for x in m.group(1).split(",")]
        hd = dict(zip([int(v) for v in vals[0::2]], vals[1::2]))

    def mult_at(tile):
        v = 1.0
        for x, y in sc:
            if x <= tile and y > 0:
                v = y
        return v

    hops = make_charts.hops_of(ang, twirls, mids)
    out = [so]
    spb = 60000.0 / bpm
    for i in range(1, len(ang)):
        # 홀드박은 홉에 더해진다 — ChartRuntime.hold_beats_at 과 같은 의미론.
        out.append(out[-1] + (hops[i - 1] + HOLD_ORBIT_BEATS * hd.get(i - 1, 0.0))
                   * spb / mult_at(i - 1))
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


def _decode_audio_48k(path, channels):
    """원곡(mp3 등) -> 48kHz float 리스트(스테레오는 L/R 인터리브). macOS afconvert."""
    fd, tmp = tempfile.mkstemp(suffix=".wav")
    os.close(fd)
    try:
        r = subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@%d" % SR,
                            "-c", str(channels), path, tmp], capture_output=True)
        if r.returncode != 0:
            raise SystemExit("afconvert 실패 (macOS 전용): %s"
                             % r.stderr.decode(errors="replace").strip())
        w = wave.open(tmp)
        n = w.getnframes() * w.getnchannels()
        raw = w.readframes(w.getnframes())
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

    스테레오로 채택한다(신스 렌더만 모노) — 원곡을 트는 이유가 '노래답게'인데
    스테레오 이미지를 버리면 반쪽이다. 정렬 계측만 모노 믹스다운으로 한다.
    """
    inter = _decode_audio_48k(path, 2)   # L/R 인터리브
    mono = [(inter[i] + inter[i + 1]) * 0.5 for i in range(0, len(inter) - 1, 2)]
    flux, fps = _flux(mono)

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
    # 인터리브 버퍼라 프레임 수 x2 로 자르고 붙인다.
    lead = int(round(-best_o * SR))
    if lead >= 0:
        buf = [0.0] * (lead * 2) + inter
    else:
        buf = inter[(-lead) * 2:]
    return buf, {
        "original_audio": os.path.basename(path),
        "audio_channels": 2,
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
    # 기본값을 뒤집었다(2026-08-10). 옵트인으로 두면 '--holds 없이 재생성'
    # 한 번에 홀드가 조용히 사라진다 — 실제로 그럴 뻔했다.
    # 실곡 검증 근거: 14곡 116개 배치 · 엔진 교차검증 최대 0.0096ms ·
    # 자동플레이 랭크 P 100%(판정 505 = 입력 481 + 뗌 24).
    ap.add_argument("--no-holds", dest="holds", action="store_false",
                    help="홀드 자동 배치를 끈다 (기본은 켬)")
    ap.set_defaults(holds=True)
    ap.add_argument("--force-synth", action="store_true",
                    help="원곡 오디오 채보를 알고도 신스 렌더로 되돌린다 "
                         "(--audio 없는 재생성이 원곡 채보를 만나면 기본은 중단)")
    args = ap.parse_args()

    name = args.name or os.path.splitext(os.path.basename(args.midi[0]))[0]
    title = args.title or name

    # 원곡 채보를 '조용한 신스 회귀'로부터 지킨다. 실제로 한 번 당했다 —
    # 전곡 재생성 스윕이 --audio 없이 mureka_09 를 훑어 정리맵(신스) 버전으로
    # 되돌렸고, 그 상태가 커밋까지 갔다(3cf41e8, 6aa2e8d 에서 복원).
    # 파일 덮어쓰기는 소리가 안 나므로 여기서 소리를 낸다.
    prev_meta_path = os.path.join(HERE, "assets", "%s.json" % name)
    if not args.audio and not args.force_synth and os.path.exists(prev_meta_path):
        try:
            prev = json.load(open(prev_meta_path))
        except (ValueError, OSError):
            prev = {}
        if prev.get("original_audio"):
            raise SystemExit(
                "%s 는 원곡 오디오 채보다(%s). --audio 없이 재생성하면 신스로\n"
                "되돌아간다 — 원곡 유지는 --audio <파일>, 의도한 회귀는 --force-synth."
                % (name, prev["original_audio"]))

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
    # ── 카운트인은 '박'이 아니라 '벽시계'로 잰다 ─────────────────
    # 4박 고정이었더니 203bpm(mureka_09)에선 1.2초라 손 올릴 새가 없고
    # 66bpm 에선 3.6초 침묵이라 "곡이 안 나온다"로 읽혔다.
    # 목표 ~2.5초에 가장 가까운 정수 박(2~8) — 음악적으론 박, 체감으론 시간.
    # 한 지점 bpm 으로 박수를 정하면 안 된다 — 전사 인트로가 300bpm 으로 찍힌
    # 곡(mureka_06)에서 '68bpm 기준 3박'을 골랐더니 실제 여유가 0.9초였다.
    # 첫 온셋에서 n박 거슬러 간 벽시계를 템포맵으로 직접 적분해 고른다.
    _tm0 = TempoMap(tempos_clean)

    def _lead_wall(nb):
        b1 = onsets[0]
        b0 = b1 - nb
        if b0 >= 0.0:
            return _tm0.sec_at(b1) - _tm0.sec_at(b0)
        return _tm0.sec_at(b1) + (-b0) * 60.0 / tempos_clean[0][1]

    lead_beats = float(min(range(2, 13), key=lambda nb: abs(_lead_wall(nb) - 2.5)))
    # 시프트 기준은 '멜로디 첫 온셋'이다 — 반주 인트로는 일부러 카운트인에 남긴다.
    # 한 번 '전 트랙 첫 노트' 기준으로 밀어 카운트인을 완전 무음+틱으로 만들어
    # 봤는데, "곡 시작까지 비는 느낌"이라는 피드백을 받았다. 원래 불만은
    # 음악 위에 틱이 얹힌 잡음이었지 음악 자체가 아니다 — 얼불춤 실레벨도
    # 인트로가 흐르는 채로 시작한다. 틱은 아래 RMS 게이트가 무음 자리에만
    # 넣으므로, 인트로가 있는 곡은 음악이 카운트인 역할을 대신한다.
    shift = max(0.0, lead_beats - onsets[0])
    print("  카운트인 %g박 = %.0fms (템포맵 적분)"
          % (lead_beats, _lead_wall(lead_beats) * 1000.0))
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
    if onsets[0] > lead_beats + 1e-9:
        intro_fills = 1  # 실제 개수는 공백 채움 루프가 센다 — 시드만 기록
        onsets.insert(0, lead_beats)

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
    # ── 곡 꼬리 앵커 ────────────────────────────────────────────
    # 온셋 목록이 멜로디의 마지막 음에서 끝나면, 반주가 계속되는 꼬리가
    # 채보 밖에 남는다 — 실측 최대 11.4초. 그럼 '완주'가 곡 중간에 뜬다.
    # 전 트랙의 마지막 노트 시작을 앵커로 넣어 보강·걸음이 꼬리까지 채운다.
    # 앵커 자체도 실제 노트라 정당한 탭이다.
    # 속도 타일 삽입 '앞'이어야 한다 — 삽입 범위가 [첫, 끝] 온셋이라
    # 앵커가 뒤에 오면 꼬리의 템포 변경점이 타일을 못 받고
    # '속도 변경은 타일 위' 불변식 검사에서 죽는다(실측 mureka_07 433박).
    last_note = q12(max(n[0] for tr in tracks for n in tr["notes"]))
    if last_note > onsets[-1] + 1e-9:
        print("  꼬리 앵커 %.4g박 — 마지막 탭 뒤 %.1f초의 반주가 채보 밖이었다"
              % (last_note, tmap.sec_at(last_note) - tmap.sec_at(onsets[-1])))
        onsets.append(last_note)

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

    # 세기 곡선 — 밀도 보강과 토끼 구간이 같이 쓴다.
    curve = intensity_curve(tracks, tmap, tmap.sec_at(onsets[-1]))

    # ── 홀드 자동 배치 (보강·걸음보다 먼저 — 홀드 구간엔 아무것도 못 들어간다) ──
    # 기본 켬. 지속음이 없는 곡은 자연히 0개가 된다(mureka_06: 1/12박 스트림).
    hold_marks = []
    if args.holds:
        hold_marks = place_holds(onsets, tracks[mel_i]["notes"], tmap,
                                 args.min_gap_ms)
        if hold_marks:
            orb = sum(n for _b, n in hold_marks)
            print("  홀드 %d개 (멜로디 지속음 위 · 총 %g바퀴 = %g박): %s%s"
                  % (len(hold_marks), orb, orb * HOLD_ORBIT_BEATS,
                     ["%.4g박 x%g" % (b, n) for b, n in hold_marks[:4]],
                     " ..." if len(hold_marks) > 4 else ""))
    # 온셋 박 -> 홀드가 차지하는 박(2n). 걸음 채움·간격 검사가 이걸 뺀다.
    hold_span = {round(b * GRID): HOLD_ORBIT_BEATS * n for b, n in hold_marks}

    # ── 밀도 보강: 공백을 반주 온셋으로 채운다 (걸음 타일보다 먼저) ──
    # 여기서 채워진 자리는 전부 '실제로 소리가 나는' 자리다.
    # 아래 2박 걸음 채움은 이제 진짜 무음 구간에만 남는다.
    mel_only = len(onsets)
    if args.fill_above_beats > 0:
        # 곡의 세기를 따라 '얼마나 채울지'를 구간마다 바꾼다.
        # 이걸 안 하면 조용한 구간은 억지로 채워 올라가고 시끄러운 구간은
        # 이미 꽉 차서 더 못 올라가, 곡의 기승전결이 채보에서 사라진다.
        ceil = ceiling_fn(curve, tmap, args.fill_above_beats)
        spark = "".join(" ▁▂▃▄▅▆▇█"[min(8, int(v * 8))] for v in curve)
        print("  밀도 보강 (세기 따라 목표 간격 %.0f->%.0fms = %.1f->%.1f탭/초"
              " · 바닥 %.0f~%.0fms)"
              % (max(CEIL_EASY_MS * args.fill_above_beats, CEIL_HARD_MS),
                 CEIL_HARD_MS,
                 1000.0 / max(CEIL_EASY_MS * args.fill_above_beats, CEIL_HARD_MS),
                 1000.0 / CEIL_HARD_MS,
                 args.min_gap_ms, min(GAP_HARD_MS, args.min_gap_ms)))
        print("    세기 %s" % spark)
        onsets = enrich_onsets(onsets, support_layers(tracks, mel_i), tmap,
                               ceil, gap_fn(curve, tmap, args.min_gap_ms),
                               holds=hold_marks)
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
        # 홀드가 걸린 온셋도 보호한다 — 지워지면 hold_marks 가 허공을 가리킨다.
        onsets = drop_unhittable(
            onsets, set(round(q12(b) * GRID) for b, _ in tempos)
            | set(round(b * GRID) for b, _ in hold_marks),
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
        # 홀드 타일이면 공백은 '뗌'(온셋 + 2n박)부터 시작한다 —
        # 홀드가 차지한 시간에 걸음 타일이 들어가면 잡은 손으로 밟으라는 뜻이 된다.
        a = out[-1] + hold_span.get(round(out[-1] * GRID), 0.0)
        cells = int(round((o - a) * GRID))
        if cells > MAX_CELLS:
            if args.no_fill:
                raise SystemExit("공백 %.4g박 @ %.4g박 — 한 타일 최대 2박 (--no-fill)"
                                 % (o - a, a))
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

    # ── 토끼 구간 (게임플레이 배속) ─────────────────────────────
    # 원곡 오디오 모드는 제외 — 홉 단위 템포 리샘플과 배속 합성이 얽힌다.
    boosts = []
    if not args.audio:
        boosts = pick_boost_sections(onsets, hold_marks, curve, tmap)
        if os.environ.get("DEBUG_BOOST"):
            print("    [debug] curve>=%.2f 창 %d/%d · 최고 %.2f"
                  % (BOOST_CURVE_MIN,
                     sum(1 for v in curve if v >= BOOST_CURVE_MIN), len(curve),
                     max(curve)))
        for _b0, _b1, _m in boosts:
            print("  토끼 구간 x%g: %.4g~%.4g박 (%.0f~%.0f초 · 세기 상위)"
                  % (_m, _b0, _b1, tmap.sec_at(_b0), tmap.sec_at(_b1)))

    # 간격 불변식은 '이동' 기준이다 — 홀드가 차지한 2n박은 홉이 아니다.
    gaps = [onsets[i] - onsets[i - 1]
            - hold_span.get(round(onsets[i - 1] * GRID), 0.0)
            for i in range(1, len(onsets))]
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
        # 인터리브 버퍼를 그대로 정규화한다 — RMS 는 양 채널 평균이 되고,
        # 리미터 블록(64샘플=32프레임)의 게인이 L/R 에 같이 걸려 채널 연동이
        # 공짜로 성립한다. 채널을 갈라 따로 걸면 이미지가 좌우로 흔들린다.
        buf = loudness_normalize(buf)
        write_wav(os.path.join(HERE, "assets", "%s.wav" % name), buf,
                  audio_meta.get("audio_channels", 1))
        print("  원곡 채택: %s -> assets/%s.wav (스테레오 · 신스 렌더 대체)"
              % (os.path.basename(args.audio), name))

    # ── 카운트인 틱 ────────────────────────────────────────────
    # 침묵 카운트인은 "곡이 안 나온다"로 읽힌다. 마지막 한 마디(최대 4박)에
    # 틱을 박는다 — 마지막 틱만 한 옥타브 위라 출발이 귀로 잡힌다.
    # 원곡 모드에도 박는다: 정렬이 카운트인만큼 무음을 앞에 붙여 놓았다.
    ch = audio_meta.get("audio_channels", 1)
    ticks = int(min(4, math.floor(onsets[0] + 1e-9)))
    placed = 0
    for kt in range(ticks):
        t0 = tmap.sec_at(onsets[0] - ticks + kt)
        start = int(t0 * SR)
        # 그 자리에 이미 음악이 있으면 틱을 안 박는다 — 반주 인트로가 있는
        # 곡(실측 4/14: 01·10·13·14)은 음악 자체가 카운트인이고, 그 위에
        # 틱을 얹으면 잡음으로 들린다(실사용 피드백). 원곡 mp3 도 전사에
        # 안 잡힌 인트로가 앞에 깔려 있을 수 있다 — 가정하지 말고 재서 정한다.
        n2 = int(0.15 * SR)
        acc = 0.0
        cnt = 0
        for i2 in range(0, n2, 8):
            j2 = (start + i2) * ch
            if 0 <= j2 < len(buf):
                acc += buf[j2] * buf[j2]
                cnt += 1
        rms_db = 10.0 * math.log10(acc / cnt) if cnt and acc > 0 else -180.0
        if rms_db > -45.0:
            continue   # 음악이 카운트인을 대신한다
        placed += 1
        # 존재감 있는 메트로놈. 처음엔 50ms·감쇠 τ17ms·단일 사인이었는데
        # 무음 카운트인에서 '깜빡이는 점' 수준이라 "곡 시작까지 비는 느낌"
        # 피드백을 받았다. τ36ms + 2배음 한 겹 + 진폭 0.62 로 키워
        # '의도된 카운트'로 들리게 한다. 마지막 틱만 한 옥타브 위는 유지.
        f = 1760.0 if kt == ticks - 1 else 880.0
        for i2 in range(int(0.1 * SR)):
            env = math.exp(-i2 / SR * 28.0)
            v = (math.sin(2.0 * math.pi * f * i2 / SR)
                 + 0.35 * math.sin(4.0 * math.pi * f * i2 / SR)) * env * 0.62
            for c2 in range(ch):
                j2 = (start + i2) * ch + c2
                if 0 <= j2 < len(buf):
                    buf[j2] = max(-1.0, min(1.0, buf[j2] + v))
    if placed:
        write_wav(os.path.join(HERE, "assets", "%s.wav" % name), buf, ch)
    print("  카운트인 틱 %d/%d개 (음악이 있는 자리는 건너뜀)" % (placed, ticks))

    meta = {
        "bpm": base_bpm,
        "sample_rate": SR,
        # buf 는 스테레오면 인터리브라 프레임 수 = len/채널
        "duration_s": len(buf) / SR / audio_meta.get("audio_channels", 1),
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
        "speed_display_beats": [b for b, _ in display_marks]
            + [b for sec in boosts for b in (sec[0], sec[1])],
        # 게임플레이 배속 구간(토끼). chart_from_song 이 홉 박자 x m ·
        # 배율 x m 으로 적용한다 — 벽시계는 불변이다.
        "boost_sections_beats": boosts,
        # 홀드: [온셋 박, 바퀴]. 채보 쪽 홉은 이 2n박만큼 짧아진다.
        "hold_marks_beats": hold_marks,
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
