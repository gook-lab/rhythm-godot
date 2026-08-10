#!/usr/bin/env python3
"""
변환기의 '고르는 판단' 단독 테스트 — 기준 템포 선택과 멜로디 트랙 선택.

둘 다 실곡을 넣기 전에는 안 드러나는 종류였다(2026-08-10, Mureka 14곡):
  - 기준 BPM 을 첫 온셋에서 따오니, 곡 맨 앞의 짧은 300bpm 구간 때문에
    나머지 전곡이 x0.393 달팽이 타일 하나가 됐다(118bpm 곡인데).
  - 멜로디를 'vocal' 라벨로 고르니, 전사기가 보컬을 거의 못 잡은 곡에서
    172초 곡에 타일 10개짜리 채보가 나왔다.

U턴 여유(TURN_EPS_DEG)도 여기서 같이 잠근다 — 각도에 float 오차가 0.001도만
섞여도 U턴이 0박/2박으로 뒤집혀 히트타임이 6.5초 어긋났던 자리다.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import midi2song as M
import make_charts as MC
from midilib import TempoMap

FAIL = 0


def ok(cond, what):
    global FAIL
    print("  %s %s" % ("ok  " if cond else "FAIL", what))
    if not cond:
        FAIL += 1


def make_track(onsets, dur=0.25):
    """온셋 목록 -> track_stats 가 받는 트랙 모양."""
    return {"label": "t", "drums": False,
            "notes": [(b, dur, 60, 96) for b in onsets]}


def main():
    print("기준 템포 — '가장 오래 가는' 것이어야 한다")
    # Mureka 2번 재현: 앞 4박만 300bpm, 나머지 270박이 118bpm.
    tempos = [(0.0, 300.0), (4.0, 118.0)]
    got = M.dominant_bpm(tempos, 0.0, 274.0)
    ok(abs(got - 118.0) < 1e-9,
       "짧은 앞구간에 끌려가지 않는다 — %.1f (첫 온셋 기준이면 300)" % got)
    # 반대로 진짜 대부분이 빠른 곡이면 그쪽이 기준이다.
    ok(abs(M.dominant_bpm([(0.0, 118.0), (4.0, 300.0)], 0.0, 274.0) - 300.0) < 1e-9,
       "대다수가 빠르면 그쪽이 기준")
    # '오래'는 박이 아니라 시간이다. 같은 박수라면 느린 쪽이 더 오래 간다.
    ok(abs(M.dominant_bpm([(0.0, 60.0), (10.0, 240.0)], 0.0, 20.0) - 60.0) < 1e-9,
       "박이 같으면 느린 쪽(시간이 길다)이 기준")
    ok(M.dominant_bpm([(0.0, 140.0)], 0.0, 100.0) == 140.0, "구간 하나면 그것")

    print("\n멜로디 선택 — 라벨이 아니라 '나올 채보'로 고른다")
    dur = 120.0
    tmap = TempoMap([(0.0, 120.0)])   # 1박 = 0.5초

    # (a) 곡을 거의 안 덮는 트랙: 앞 5초에 몰려 있다 (전사 실패한 vocal 스템)
    short = M.track_stats(make_track([i * 0.5 for i in range(20)]), tmap, dur)
    # (b) 곡 전체를 고르게 덮는 트랙 (120초 @120bpm = 240박)
    spread = M.track_stats(make_track([i * 1.0 for i in range(240)]), tmap, dur)
    # (c) 곡을 덮지만 사람이 못 칠 만큼 촘촘한 트랙
    dense = M.track_stats(make_track([i * 0.125 for i in range(1900)]), tmap, dur)

    ok(short["span"] < 0.15 and spread["span"] > 0.9,
       "덮는 비율이 갈린다 — 몰림 %.2f vs 고름 %.2f" % (short["span"], spread["span"]))
    ok(M.melody_score(spread) > M.melody_score(short) * 5,
       "곡을 덮는 쪽이 압도적으로 높다 — %.3f vs %.3f"
       % (M.melody_score(spread), M.melody_score(short)))
    ok(dense["tight"] > 0.9,
       "못 치는 간격 비율이 잡힌다 — %.2f" % dense["tight"])
    ok(M.melody_score(spread) > M.melody_score(dense),
       "덮더라도 못 칠 만큼 촘촘하면 진다 — %.3f vs %.3f"
       % (M.melody_score(spread), M.melody_score(dense)))
    ok(M.track_stats(make_track([1.0]), tmap, dur) is None,
       "노트가 하나뿐이면 채보가 안 된다(None)")

    print("\nU턴 여유 — wrap 경계에서 0박/2박이 뒤집히면 안 된다")
    for name, prev, cur in [("정확", 0.0, 180.0),
                            ("+오차", 0.0, 180.0006),
                            ("-오차", 0.0, 179.9994),
                            ("랩", 350.0, 170.0006)]:
        b = MC.beats_for_tile_spin(prev, cur, 1)
        ok(abs(b - 2.0) < 1e-3, "%s U턴 = 2.0박 — %.6f" % (name, b))
    # 정상 홉은 그대로여야 한다 — 여유가 정상값까지 먹으면 안 된다.
    ok(abs(MC.beats_for_tile_spin(0.0, 0.0, 1) - 1.0) < 1e-9, "직선 1박은 그대로")
    # 격자의 최소 홉은 1/12박 = 스윕 15도다. 여유(1도)가 여기까지 먹으면
    # 가장 촘촘한 리듬이 통째로 U턴이 되어 버린다.
    ok(abs(MC.beats_for_tile_spin(0.0, 195.0, 1) - 1.0 / 12.0) < 1e-6,
       "최소 격자 홉(15도) = 1/12박 그대로 — %.6f" % MC.beats_for_tile_spin(0.0, 195.0, 1))

    print("\n" + ("PASS" if FAIL == 0 else "FAILED %d" % FAIL))
    sys.exit(FAIL)


if __name__ == "__main__":
    main()
