#!/usr/bin/env python3
"""
밀도 보강 + 걸음 채움 단독 테스트.

이 두 단계는 '리듬을 바꾸는' 유일한 곳이라 회귀가 나면 곡 전체가 어긋난다.
곡 파일 없이 손으로 만든 온셋/템포로 불변식을 잠근다:

  - 보강은 원래 온셋을 하나도 지우지 않는다 (멜로디는 성역이다)
  - 보강은 최소 간격보다 좁은 자리를 만들지 않는다 (못 치는 채보 금지)
  - 보강은 천장(박) 이하의 공백은 건드리지 않는다
  - 층 우선순위: 위 층으로 메워지면 아래 층은 안 쓴다
  - 걸음 채움은 공백을 '등분'한다 (그리디는 1/12박 조각을 남겼다)
  - 걸음 채움 뒤 모든 간격이 (0, 2] 박이고 격자 위에 있다
  - 못 치는 간격 정리는 속도 타일을 절대 안 버린다 (버리면 배속이 틀린다)
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from midilib import TempoMap
from midi2song import (enrich_onsets, support_layers, drop_unhittable,
                       q12, GRID, MAX_HOP)

FAIL = 0


def ok(cond, what):
    global FAIL
    print("  %s %s" % ("ok  " if cond else "FAIL", what))
    if not cond:
        FAIL += 1


def walk_fill(onsets):
    """midi2song 의 걸음 채움과 같은 계산 (칸 정수 등분)."""
    max_cells = int(round(MAX_HOP * GRID))
    out = [onsets[0]]
    filled = []
    for o in onsets[1:]:
        cells = int(round((o - out[-1]) * GRID))
        if cells > max_cells:
            a = out[-1]
            n = -(-cells // max_cells)
            for k in range(1, n):
                t = q12(a + round(cells * k / n) / GRID)
                out.append(t)
                filled.append(t)
        out.append(o)
    return out, filled


# 120bpm 상수 = 1박 500ms. 계산이 암산으로 검산된다.
TMAP = TempoMap([(0.0, 120.0)])


def t_preserves_melody():
    print("보강은 원래 온셋을 지우지 않는다")
    mel = [0.0, 4.0, 8.0]
    layers = [("드럼", [1.0, 2.0, 3.0, 5.0, 6.0, 7.0])]
    got = enrich_onsets(mel, layers, TMAP, 1.0, 150.0, verbose=False)
    ok(all(m in got for m in mel), "멜로디 %s 가 전부 남는다" % mel)
    ok(got == sorted(got), "정렬 유지")
    ok(len(set(got)) == len(got), "중복 없음")


def t_min_gap():
    print("보강은 최소 간격보다 좁은 자리를 만들지 않는다")
    # 120bpm 에서 1/12박 = 41.7ms. 후보를 촘촘히 깔아 두고 150ms 바닥을 건다.
    mel = [0.0, 4.0]
    dense = [round(k / 12.0, 6) for k in range(1, 48)]
    got = enrich_onsets(mel, [("촘촘", dense)], TMAP, 1.0, 150.0, verbose=False)
    ms = [(got[i] - got[i - 1]) * 500.0 for i in range(1, len(got))]
    ok(min(ms) >= 150.0 - 1e-6, "최소 간격 %.1fms >= 150" % min(ms))
    ok(len(got) > 2, "그래도 채우긴 했다 (%d개)" % len(got))


def t_ceiling():
    print("천장 이하의 공백은 건드리지 않는다")
    # 공백이 정확히 1박이면 천장(1.0박) 이하라 손대지 않는다.
    mel = [0.0, 1.0, 2.0, 3.0]
    got = enrich_onsets(mel, [("드럼", [0.5, 1.5, 2.5])], TMAP, 1.0, 100.0,
                        verbose=False)
    ok(got == mel, "1박 공백은 그대로 (%s)" % got)
    # 1.5박이면 천장을 넘으므로 채운다.
    mel2 = [0.0, 1.5]
    got2 = enrich_onsets(mel2, [("드럼", [0.75])], TMAP, 1.0, 100.0, verbose=False)
    ok(got2 == [0.0, 0.75, 1.5], "1.5박 공백은 채운다 (%s)" % got2)


def t_layer_priority():
    print("층 우선순위 — 위 층으로 메워지면 아래 층은 안 쓴다")
    mel = [0.0, 2.0]
    layers = [("백비트", [1.0]), ("하이햇", [0.5, 1.5])]
    got = enrich_onsets(mel, layers, TMAP, 1.0, 100.0, verbose=False)
    # 백비트가 1.0 을 채우면 남는 공백은 1박씩이라 천장 이하 -> 하이햇 미사용
    ok(got == [0.0, 1.0, 2.0], "백비트만 쓰인다 (%s)" % got)


def t_support_layers_split():
    print("층 분류 — 킥/스네어와 하이햇을 가른다")
    tracks = [
        {"label": "vocal", "drums": False, "notes": [(0.0, 1, 60, 100)]},
        {"label": "drums", "drums": True,
         "notes": [(1.0, 1, 36, 100), (1.5, 1, 42, 100), (2.0, 1, 38, 100)]},
        {"label": "bass", "drums": False, "notes": [(3.0, 1, 40, 100)]},
        {"label": "synth", "drums": False, "notes": [(4.0, 1, 72, 100)]},
    ]
    layers = dict((n, v) for n, v in support_layers(tracks, 0))
    ok(layers["드럼 백비트"] == [1.0, 2.0], "킥(36)·스네어(38) -> 백비트")
    ok(layers["하이햇"] == [1.5], "42 -> 하이햇")
    ok(layers["베이스"] == [3.0], "bass 라벨 -> 베이스 (드럼 음높이여도)")
    ok(layers["그 외 성부"] == [4.0], "synth -> 그 외 성부")
    ok(0.0 not in sum(layers.values(), []), "멜로디 트랙은 후보에서 빠진다")


def t_walk_even():
    print("걸음 채움은 공백을 등분한다")
    # 2와 1/12박 = 25칸. 그리디면 [24, 1] 로 갈려 1칸(=1/12박)이 남는다.
    got, filled = walk_fill([0.0, 25.0 / 12.0])
    mid_cells = [round((got[i] - got[i - 1]) * GRID) for i in range(1, len(got))]
    ok(mid_cells == [12, 13] or mid_cells == [13, 12],
       "25칸 공백이 12+13 으로 갈린다 (got %s)" % mid_cells)
    ok(min(mid_cells) > 1, "1칸짜리 조각이 안 생긴다")


def t_walk_invariants():
    print("걸음 채움 후 간격 불변식")
    cases = [
        [0.0, 25.0 / 12.0], [0.0, 5.0], [0.0, 2.0], [0.0, 100.0 / 12.0],
        [0.0, 1.0, 7.5, 7.75, 20.0],
    ]
    worst = 0.0
    for c in cases:
        got, _ = walk_fill(c)
        gaps = [got[i] - got[i - 1] for i in range(1, len(got))]
        ok(all(0 < g <= MAX_HOP + 1e-9 for g in gaps),
           "%s -> 모든 간격이 (0, 2]박 (최대 %.4f)" % (c, max(gaps)))
        ok(all(abs(g * GRID - round(g * GRID)) < 1e-6 for g in gaps),
           "%s -> 전부 1/12 격자 위" % c)
        ok(all(o in got for o in c), "%s -> 원래 온셋 보존" % c)
        worst = max(worst, max(gaps))
    print("    최대 홉 %.4f박" % worst)


def t_enrich_then_walk():
    print("보강 -> 걸음 채움 합성: 걸음 타일은 진짜 무음에만 남는다")
    mel = [0.0, 6.0, 12.0]
    # 앞 공백엔 드럼이 있고, 뒤 공백은 무음이다.
    layers = [("드럼", [1.0, 2.0, 3.0, 4.0, 5.0])]
    got = enrich_onsets(mel, layers, TMAP, 1.0, 150.0, verbose=False)
    out, filled = walk_fill(got)
    front = [f for f in filled if f < 6.0]
    back = [f for f in filled if f > 6.0]
    ok(not front, "드럼이 있는 앞 구간엔 걸음 타일 0개 (%s)" % front)
    ok(len(back) >= 2, "무음인 뒤 구간엔 걸음 타일이 놓인다 (%d개)" % len(back))


def t_floor_basic():
    print("못 치는 간격 정리 — 뒤 타일을 버린다")
    # 120bpm: 1/12박 = 41.7ms. 0.0 / 1/12 / 1.0 -> 가운데가 버려진다.
    ons = [0.0, 1.0 / 12, 1.0, 2.0]
    got = drop_unhittable(ons, set(), TMAP, 100.0, verbose=False)
    ok(got == [0.0, 1.0, 2.0], "41.7ms 짜리 자리가 사라진다 (%s)" % got)
    ok(got[0] == ons[0], "첫 타일은 남는다 (시작점이라 옮기면 안 된다)")


def t_floor_protects_speed_tiles():
    print("정리는 속도 타일을 절대 안 버린다")
    # 1/12박에 속도 타일이 있고 그 바로 앞 0.0 은 평범한 온셋.
    # 속도 타일이 이기고 앞엣것이 버려져야 한다 — 앞에 여유가 있을 때만.
    ons = [0.0, 1.0, 1.0 + 1.0 / 12, 3.0]
    protect = {round((1.0 + 1.0 / 12) * GRID)}
    got = drop_unhittable(ons, protect, TMAP, 100.0, verbose=False)
    ok(1.0 + 1.0 / 12 in got, "속도 타일이 살아남는다 (%s)" % got)
    ok(1.0 not in got, "대신 평범한 이웃이 버려진다")

    # 속도 타일 둘이 붙어 있으면 아무것도 못 버린다 — 그대로 둔다.
    ons2 = [0.0, 1.0, 1.0 + 1.0 / 12]
    protect2 = {round(1.0 * GRID), round((1.0 + 1.0 / 12) * GRID)}
    got2 = drop_unhittable(ons2, protect2, TMAP, 100.0, verbose=False)
    ok(got2 == ons2, "둘 다 보호면 둘 다 남는다 (%s)" % got2)


def t_floor_no_cascade():
    print("정리가 연쇄로 앞 타일까지 밀어내지 않는다")
    # 속도 타일이 이기려면 '그 앞 타일과도' 여유가 있어야 한다.
    # 0.0 과 1/12 이 붙어 있고 1/12 이 보호 대상이면, 0.0 을 버리는 순간
    # 시작점이 사라진다 — len(kept)==1 분기가 이걸 처리한다.
    ons = [0.0, 1.0 / 12, 2.0]
    got = drop_unhittable(ons, {1}, TMAP, 100.0, verbose=False)
    ok(len(got) == 2 and abs(got[0] - 1.0 / 12) < 1e-9,
       "보호 타일이 시작점을 대체한다 (%s)" % got)
    gaps = [(got[i] - got[i - 1]) * 500.0 for i in range(1, len(got))]
    ok(all(g >= 100.0 for g in gaps), "결과에 100ms 미만 간격이 없다 (%s)" % gaps)


def t_floor_result_invariant():
    print("정리 후 간격 불변식 (보호 충돌 제외)")
    ons = sorted(set([0.0] + [round(k / 12.0, 6) for k in range(1, 60)]
                     + [7.0, 9.5]))
    got = drop_unhittable(ons, set(), TMAP, 100.0, verbose=False)
    gaps = [(got[i] - got[i - 1]) * 500.0 for i in range(1, len(got))]
    ok(min(gaps) >= 100.0 - 1e-6, "최소 간격 %.1fms >= 100" % min(gaps))
    ok(got == sorted(got) and len(set(got)) == len(got), "정렬·중복 없음 유지")
    ok(set(got) <= set(ons), "새 온셋을 만들지 않는다 (버리기만 한다)")


for t in (t_preserves_melody, t_min_gap, t_ceiling, t_layer_priority,
          t_support_layers_split, t_walk_even, t_walk_invariants,
          t_enrich_then_walk, t_floor_basic, t_floor_protects_speed_tiles,
          t_floor_no_cascade, t_floor_result_invariant):
    t()

print("\n%s" % ("전부 통과" if FAIL == 0 else "FAILED %d" % FAIL))
sys.exit(1 if FAIL else 0)
