#!/usr/bin/env python3
"""홀드 자동 배치(place_holds)와 보강 차단(enrich_onsets holds=) 단위 테스트.

홀드의 세 규칙을 각각 잠근다:
  1. 지속음 위에서만 (dur >= 2n — 짧은 노트에 홀드를 걸면 거짓 동작)
  2. 뗌 -> 다음 탭 이동 시간 확보 (travel >= min_gap_ms)
  3. 홀드 구간(누름~뗌)엔 보강 타일이 못 들어간다 — 잡은 손은 탭을 못 친다
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from midilib import TempoMap  # noqa: E402
from midi2song import place_holds, enrich_onsets, HOLD_ORBIT_BEATS  # noqa: E402

FAIL = 0


def ok(cond, what):
    global FAIL
    print("  %s %s" % ("ok  " if cond else "FAIL", what))
    if not cond:
        FAIL += 1


def note(beat, dur):
    return (beat, dur, 60, 96)


def main():
    tm = TempoMap([(0.0, 120.0)])   # 1박 = 500ms

    print("배치 — 지속음·간격 규칙")
    # 4박 지속음, 다음 온셋까지 6박: 바퀴는 지속음이 상한 (2바퀴), 이동 2박 남는다
    h = place_holds([4.0, 10.0], [note(4.0, 4.0)], tm, 150.0)
    ok(h == [[4.0, 2.0]], "dur 4박·간격 6박 -> 2바퀴 (지속음이 상한) — %s" % h)

    # 10박 지속음(레가토), 간격 4박: 간격이 상한. 2바퀴면 이동 0 -> 1바퀴로 물러난다
    h = place_holds([0.0, 4.0], [note(0.0, 10.0)], tm, 150.0)
    ok(h == [[0.0, 1.0]], "간격 4박 꽉 찬 지속음 -> 1바퀴 (이동 구간 확보) — %s" % h)

    # 짧은 노트(1.5박)는 홀드가 아니다
    h = place_holds([0.0, 6.0], [note(0.0, 1.5)], tm, 150.0)
    ok(h == [], "1.5박 노트 -> 홀드 없음 — %s" % h)

    # 이동 구간이 ms 바닥을 못 넘으면 바퀴를 줄이고, 그래도 안 되면 포기
    # 2.25박 간격: 1바퀴면 이동 0.25박 = 125ms < 150ms -> 홀드 없음
    h = place_holds([0.0, 2.25], [note(0.0, 4.0)], tm, 150.0)
    ok(h == [], "이동 125ms < 150ms -> 홀드 포기 — %s" % h)

    # 같은 간격이라도 느린 곡이면 통과: 60bpm 이면 0.25박 = 250ms
    tm60 = TempoMap([(0.0, 60.0)])
    h = place_holds([0.0, 2.25], [note(0.0, 4.0)], tm60, 150.0)
    ok(h == [[0.0, 1.0]], "60bpm 같은 간격 -> 1바퀴 (바닥은 ms, 박이 아니다) — %s" % h)

    # 마지막 온셋에는 홀드를 안 건다 (다음 온셋이 없다)
    h = place_holds([0.0], [note(0.0, 8.0)], tm, 150.0)
    ok(h == [], "마지막 온셋 -> 홀드 없음")

    print("보강 차단 — 홀드 구간엔 반주 타일이 못 들어간다")
    onsets = [0.0, 6.0]
    pool = [1.0, 2.0, 3.0, 4.0, 5.0]
    # 홀드 없음: 공백 6박이 반주로 채워진다
    got = enrich_onsets(onsets, [("반주", pool)], tm, 1.0, 150.0, verbose=False)
    ok(len(got) > 2, "홀드 없으면 보강이 들어간다 (%d개)" % len(got))
    # 2바퀴 홀드(0~4박): 4박 이전 후보는 전부 차단, 뗌(4박) 직후는 min_gap 미달
    got = enrich_onsets(onsets, [("반주", pool)], tm, 1.0, 150.0,
                        holds=[[0.0, 2.0]], verbose=False)
    inside = [c for c in got if 0.0 < c < HOLD_ORBIT_BEATS * 2.0]
    ok(inside == [], "홀드 구간(0~4박) 안 보강 0개 — %s" % got)
    ok(4.0 not in got, "뗌 지점(4.0박)은 뗌에서 min_gap 미달이라 제외")
    ok(5.0 in got, "뗌 뒤 여유 있는 후보(5.0박)는 들어간다")

    print("PASS" if FAIL == 0 else "FAILED %d" % FAIL)
    sys.exit(FAIL)


if __name__ == "__main__":
    main()
