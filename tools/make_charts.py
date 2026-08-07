#!/usr/bin/env python3
"""
박자 패턴 -> 각도 배열 역산기, 그리고 .tres 생성.

손으로 각도를 적으면 하나가 5도 틀려도 게임은 그냥 돌아간다.
그럼 "느낌이 이상한데" 상태에서 범인이 내 각도인지, 공식인지, 클럭인지,
그냥 내 손인지를 구분할 방법이 없다. 그래서 각도를 손으로 안 쓴다.

의미론 (ChartRuntime 과 정확히 일치해야 한다):
  angles[i] = 타일 i 에서 '나갈' 절대 방향(도)
  타일 i 로 가는 공전은 축이 타일 i-1, 도는 행성이 타일 i-2 에서 출발한다.
  따라서  beats_to_reach(i) = beats_for_tile(angles[i-2], angles[i-1])
  타일 1 은 진입 방향이 없어서 직선으로 간주 -> 항상 1박.
  마지막 angles[n-1] 은 최종 타일의 나갈 방향이라 게임에 쓰이지 않는다(포맷상 채운다).

역산:
  beats_for_tile(prev, cur) = normalize360(cur - (prev+180)) / 180
  => cur = normalize360(prev + 180 + beats*180)
  검산: 1박 -> cur=prev(직선) · 2박 -> cur=prev+180(U턴)
        1.5박 -> cur=prev+90 · 0.5박 -> cur=prev-90
"""
import json
import math
import os

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUDIO = "res://assets/click_120.wav"
RADIUS = 96.0  # Main.TILE_SPACING 과 같아야 한다


def norm(x):
    return x % 360.0


def beats_for_tile(prev, cur):
    s = norm(cur - (prev + 180.0))
    return (360.0 if abs(s) < 1e-9 else s) / 180.0


def angles_from_hops(hops, start_deg=0.0):
    """hops[k] = 타일 k+2 에 도달하는 박자.

    타일 1 로 가는 첫 홉은 항상 1박이라 입력에서 뺐다.
    반환 길이는 len(hops)+2 — 마지막 하나는 최종 타일의 나갈 방향(미사용).
    """
    ang = [norm(start_deg)]
    for b in hops:
        ang.append(norm(ang[-1] + 180.0 + b * 180.0))
    ang.append(ang[-1])  # 최종 타일의 나갈 방향: 직선으로 채운다
    return ang


def hops_of(ang):
    """ChartRuntime.beats_to_reach 와 같은 계산. 반환 길이 = len(ang)-1."""
    out = []
    for i in range(1, len(ang)):
        inc = ang[i - 2] if i >= 2 else ang[0]
        out.append(beats_for_tile(inc, ang[i - 1]))
    return out


def tile_positions(ang, r=RADIUS):
    """ChartRuntime.tile_positions 와 같은 계산 (y 반전 포함)."""
    p = [(0.0, 0.0)]
    for i in range(1, len(ang)):
        a = math.radians(ang[i - 1])
        p.append((p[-1][0] + math.cos(a) * r, p[-1][1] - math.sin(a) * r))
    return p


def verify(ang, hops_wanted):
    """런타임과 같은 계산으로 (1) 의도한 리듬이 나오는지 (2) 착지가 맞는지 확인.

    (2)가 이 파일에 있는 이유: 공전 끝점이 다음 타일 좌표와 어긋나는 버그가 있었다.
    직선 구간에선 오차 0 이라 안 보이고, 90도 턴에서 135px, U턴에서 192px 벗어났다.
    생성 단계에서 같이 잰다.
    """
    hops = hops_of(ang)
    want = [1.0] + list(hops_wanted)
    assert len(hops) == len(want), f"홉 개수 {len(hops)} != {len(want)}"
    for i, (g, w) in enumerate(zip(hops, want)):
        assert abs(g - w) < 1e-6, f"타일 {i+1} 홉: want {w}, got {g}"

    pos = tile_positions(ang)
    worst = 0.0
    for i in range(1, len(ang)):
        inc = ang[i - 2] if i >= 2 else ang[0]
        end = math.radians(norm(inc + 180.0) + beats_for_tile(inc, ang[i - 1]) * 180.0)
        lx = pos[i - 1][0] + math.cos(end) * RADIUS
        ly = pos[i - 1][1] - math.sin(end) * RADIUS
        worst = max(worst, math.hypot(lx - pos[i][0], ly - pos[i][1]))
    assert worst < 1e-3, f"착지 오차 {worst:.4f}px"
    return hops, worst


def fmt(x):
    return "%g" % x


# 카운트인(박). 첫 타일 앞에 두는 여유다.
# 얼불춤도 countdownTicks 로 4박을 센다. 두 가지 이유로 필요하다:
#   1. 음악적 — 플레이어가 박자를 잡을 시간이 있어야 한다.
#   2. 기술적 — AudioClock 워밍업(기본 100ms) 동안 렌더가 멈춰 있는데,
#      첫 타일이 0ms 에 있으면 warm 되는 순간 그만큼 건너뛰어 카메라가 32px 튄다.
LEAD_IN_BEATS = 4.0


def write_tres(name, title, bpm, hops_wanted, start_offset_ms=None, speed_changes=None):
    if start_offset_ms is None:
        start_offset_ms = LEAD_IN_BEATS * 60000.0 / bpm
    ang = angles_from_hops(hops_wanted)
    hops, worst = verify(ang, hops_wanted)
    total = sum(hops)
    path = os.path.join(HERE, "charts", name + ".tres")
    with open(path, "w", encoding="utf-8") as f:
        f.write('[gd_resource type="Resource" script_class="Chart" load_steps=3 format=3]\n\n')
        f.write('[ext_resource type="Script" path="res://scripts/Chart.gd" id="1_chart"]\n')
        f.write('[ext_resource type="AudioStream" path="%s" id="2_audio"]\n\n' % AUDIO)
        f.write("[resource]\n")
        f.write('script = ExtResource("1_chart")\n')
        f.write("bpm = %s\n" % fmt(float(bpm)))
        f.write("angles = PackedFloat32Array(%s)\n" % ", ".join(fmt(a) for a in ang))
        f.write("start_offset_ms = %s\n" % fmt(float(start_offset_ms)))
        f.write('audio = ExtResource("2_audio")\n')
        if speed_changes:
            f.write("speed_changes = PackedVector2Array(%s)\n"
                    % ", ".join("%d, %g" % (int(i), m) for i, m in speed_changes))
        f.write('title = "%s"\n' % title)
    print("%-20s 타일 %3d · %6.1f박 · %5.1fs · 카운트인 %.0fms · 착지오차 %.5fpx"
          % (name + ".tres", len(ang), total, total * 60.0 / bpm,
             start_offset_ms, worst))
    print("%-20s 홉: %s%s" % ("", [round(h, 3) for h in hops[:12]],
                              " ..." if len(hops) > 12 else ""))
    return ang


def chart_from_song(meta_path, name, title, audio_res, speed_marks=None):
    """곡의 멜로디 온셋에서 채보를 뽑는다.

    곡과 채보가 같은 소스에서 나와야 둘이 갈라지지 않는다.
    손으로 다시 적으면 반드시 어긋난다.

    매핑:
      타일 1 이 첫 온셋에 떨어져야 한다. 첫 홉은 항상 1박이므로
      start_offset = (첫 온셋 - 1박). 그 앞은 자연스럽게 카운트인이 된다.
    """
    meta = json.load(open(meta_path, encoding="utf-8"))
    bpm = float(meta["bpm"])
    onsets = meta["melody_onsets_beats"]

    # 토끼/달팽이: (박, 배율) -> (타일 인덱스, 배율)
    # 타일 i 는 onsets[i-1] 에 떨어지므로, 그 박 이상인 첫 온셋을 찾는다.
    speed_changes = []
    for beat, mult in (speed_marks or []):
        idx = next((k for k, o in enumerate(onsets) if o >= beat - 1e-9), None)
        if idx is None:
            continue
        speed_changes.append((idx + 1, mult))
    gaps = [round(onsets[i] - onsets[i - 1], 6) for i in range(1, len(onsets))]
    start_beat = onsets[0] - 1.0
    assert start_beat > 0, "첫 온셋이 1박보다 빨라서 카운트인을 못 넣는다"
    global AUDIO
    prev_audio = AUDIO
    AUDIO = audio_res
    try:
        ang = write_tres(name, title, bpm, gaps,
                         start_offset_ms=start_beat * 60000.0 / bpm,
                         speed_changes=speed_changes)
    finally:
        AUDIO = prev_audio
    print("%-20s 첫 온셋 %g박 -> 카운트인 %.2fs · 심판 타일 %d"
          % ("", onsets[0], start_beat * 60.0 / bpm, len(gaps) + 1))
    if speed_changes:
        print("%-20s 속도 타일: %s" % ("", " ".join(
            "%s타일%d x%g" % ("토끼" if m > 1 else "달팽이", i, m)
            for i, m in speed_changes)))
    return ang


if __name__ == "__main__":
    os.makedirs(os.path.join(HERE, "charts"), exist_ok=True)

    # 자명한 것부터 올린다. 각 단계에서 공식/클럭/손 중 하나씩 용의자를 지운다.
    # (앞의 1박 하나는 첫 홉이라 자동으로 붙는다)
    write_tres("t01_straight", "01 직선", 120, [1])
    write_tres("t02_uturn", "02 U턴 2박", 120, [1, 2])
    write_tres("t03_ninety", "03 90도 1.5박", 120, [1, 1.5, 1])
    write_tres("t04_mixed", "04 혼합", 120, [1, 0.5, 0.5, 1, 1.5, 0.5, 2, 1])
    # 사각형: 90도 턴 4연속. 경로가 자기 위로 되돌아온다.
    # 착지 버그가 가장 잘 드러났던 모양이라 회귀용으로 남긴다.
    write_tres("t05_square", "05 사각형(90도 4연속)", 120, [1, 0.5, 0.5, 0.5, 0.5, 1])

    # 손으로 짠 데모. 4/4 로 읽히도록 마디마다 4박이 되게 맞췄다.
    demo = (
        [1, 1, 1]                       # 첫 홉 1박이 자동으로 붙어 4박
        + [1, 1, 1, 1]
        + [0.5, 0.5, 1, 1, 1]           # 8분음 진입
        + [0.5, 0.5, 0.5, 0.5, 1, 1]
        + [1, 1, 2]                     # U턴으로 숨 고르기
        + [0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 1]
        + [1.5, 0.5, 1, 1]              # 엇박
        + [1, 1, 1, 1]
        + [0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5]
        + [2, 2]                        # 마무리
    )
    write_tres("demo", "demo — 손으로 짠 채보", 120, demo)

    # 실제 곡 채보 — 멜로디 온셋에서 자동으로 뽑는다
    song_meta = os.path.join(HERE, "assets", "song_140.json")
    if os.path.exists(song_meta):
        # C 구간(28마디=112박)에서 1.5배속(토끼), 아웃트로(36마디)에서 원복,
        # 마지막 두 마디(38마디)는 0.7배속(달팽이)로 늘어지게.
        chart_from_song(song_meta, "song140", "칩튠 140 — 멜로디 채보",
                        "res://assets/song_140.wav",
                        speed_marks=[(112.0, 1.5), (144.0, 1.0), (152.0, 0.7)])
    else:
        print("\n(assets/song_140.json 없음 — python3 tools/make_song.py 먼저)")

    print("\n전부 통과 — 런타임과 같은 계산으로 리듬 재현 + 착지 불변식(<0.001px)")
