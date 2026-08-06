#!/usr/bin/env python3
"""
박자 패턴 -> 각도 배열 역산기, 그리고 .tres 생성.

손으로 각도를 적으면 하나가 5도 틀려도 게임은 그냥 돌아간다.
그럼 "느낌이 이상한데" 상태에서 범인이 내 각도인지, 공식인지, 클럭인지,
그냥 내 손인지를 구분할 방법이 없다. 그래서 각도를 손으로 안 쓴다.

역산:
  sweep = normalize360(cur - (prev + 180))
  beats = sweep / 180
  => cur = normalize360(prev + 180 + beats*180)

검산:
  beats=1   -> cur = prev + 360 = prev          (직선)
  beats=2   -> cur = prev + 540 = prev + 180    (U턴)
  beats=1.5 -> cur = prev + 450 = prev + 90
  beats=0.5 -> cur = prev + 270 = prev - 90
"""
import os

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUDIO = "res://assets/click_120.wav"


def norm(x):
    return x % 360.0


def angles_from_beats(beats, start_deg=0.0):
    """beats[i] = 타일 i 에서 타일 i+1 로 갈 때의 대기 박자."""
    ang = [norm(start_deg)]
    for b in beats:
        ang.append(norm(ang[-1] + 180.0 + b * 180.0))
    return ang


def verify(ang, beats):
    """생성한 각도를 다시 공식에 넣어 원래 박자가 나오는지 확인한다."""
    for i, want in enumerate(beats):
        s = norm(ang[i + 1] - (ang[i] + 180.0))
        if abs(s) < 1e-9:
            s = 360.0
        got = s / 180.0
        assert abs(got - want) < 1e-6, f"tile {i}: want {want}, got {got}"
    return True


def fmt(x):
    return ("%g" % x)


def write_tres(name, title, bpm, beats, start_offset_ms=0.0):
    ang = angles_from_beats(beats)
    verify(ang, beats)
    total_beats = sum(beats)
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
        f.write('title = "%s"\n' % title)
    print("%-22s 타일 %3d · %6.1f박 · %5.1fs · %s"
          % (name + ".tres", len(ang), total_beats, total_beats * 60.0 / bpm, title))
    return ang


if __name__ == "__main__":
    os.makedirs(os.path.join(HERE, "charts"), exist_ok=True)

    # 자명한 것부터 올린다. 각 단계에서 공식/클럭/손 중 하나씩 용의자를 지운다.
    write_tres("t01_straight", "01 직선 1박", 120, [1])
    write_tres("t02_uturn", "02 U턴 2박", 120, [1, 2])
    write_tres("t03_ninety", "03 90도 1.5박", 120, [1, 1.5, 1])
    write_tres("t04_mixed", "04 혼합", 120, [1, 0.5, 0.5, 1, 1.5, 0.5, 2, 1])

    # 손으로 짠 데모. 4/4 기준으로 읽히도록 마디마다 4박이 되게 맞췄다.
    demo = (
        [1, 1, 1, 1]                    # 워밍업 4박
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
    print("\n전부 역산 검산 통과 (생성한 각도를 공식에 다시 넣어 원래 박자가 나오는지 확인)")
