#!/usr/bin/env python3
"""
T10 v3 — SetSpeed(BPM 변경)와 Twirl(회전방향 반전)을 반영한 실측 검증.

v2 에서 bmb 총 길이가 12분 29초로 나왔다(원곡은 4분대). 원인 후보 둘:
  (a) 각도->박자 공식이 틀렸다
  (b) 실제 채보가 상시로 쓰는 SetSpeed / Twirl 를 무시했다
bmb 는 SetSpeed 132개(128->256->512 bpm), Twirl 787개(전체 타일의 25%)를 쓴다.
=> (b)를 반영하고 나서도 길이가 안 맞으면 그때가 (a)다.
"""
import sys, math, json
sys.path.insert(0, ".")
from verify_formula import load_adofai, angles_of, MIDSPIN


def normalize360(x):
    return math.fmod(math.fmod(x, 360.0) + 360.0, 360.0)


def sweep_for(prev, cur, ccw):
    """ccw=True 면 반시계로, False(twirl 상태)면 시계로 돈다."""
    s = normalize360(cur - (prev + 180.0)) if ccw else normalize360((prev + 180.0) - cur)
    if abs(s) < 1e-9:
        s = 360.0
    return s


def simulate(path, twirl_before=True, verbose=True):
    d = load_adofai(path)
    ang, fmt = angles_of(d)
    st = d.get("settings", {})
    bpm0 = float(st.get("bpm", 100) or 100)

    # floor -> 이벤트
    speed_at, twirl_at = {}, set()
    for a in d.get("actions", []):
        et = a.get("eventType")
        f = a.get("floor")
        if et == "SetSpeed":
            speed_at[f] = a
        elif et == "Twirl":
            twirl_at.add(f)

    bpm = bpm0
    ccw = True
    t_ms = 0.0
    total_beats = 0.0
    for i in range(len(ang)):
        # 이 타일에 걸린 이벤트 적용
        if i in speed_at:
            a = speed_at[i]
            if a.get("speedType", "Bpm") == "Multiplier":
                bpm = bpm * float(a.get("bpmMultiplier", 1) or 1)
            else:
                bpm = float(a.get("beatsPerMinute", bpm) or bpm)
                m = a.get("bpmMultiplier")
                if m:
                    bpm *= float(m)
        if twirl_before and i in twirl_at:
            ccw = not ccw
        if i == 0:
            continue
        if ang[i] == MIDSPIN or ang[i - 1] == MIDSPIN:
            continue
        b = sweep_for(ang[i - 1], ang[i], ccw) / 180.0
        total_beats += b
        t_ms += b * (60000.0 / bpm)
        if not twirl_before and i in twirl_at:
            ccw = not ccw

    sec = t_ms / 1000.0
    if verbose:
        print(f"  twirl 적용 시점 {'진입 전' if twirl_before else '통과 후'}: "
              f"{total_beats:8.1f}박  ->  {int(sec//60)}분 {sec%60:04.1f}초")
    return sec


if __name__ == "__main__":
    KNOWN = {  # 참고용 원곡 대략 길이 (초). 정확할 필요 없다 — 자릿수만 본다.
        "test_bmb.adofai": ("Camellia - Blackmagik Blazing", 250),
        "test_sb.adofai": ("Camellia - Secret Boss", 300),
    }
    for f in sys.argv[1:]:
        d = load_adofai(f)
        ang, fmt = angles_of(d)
        st = d["settings"]
        n_tw = sum(1 for a in d.get("actions", []) if a.get("eventType") == "Twirl")
        n_ss = sum(1 for a in d.get("actions", []) if a.get("eventType") == "SetSpeed")
        print(f"\n{'='*70}\n{f}  [{fmt}]  타일 {len(ang)} · 시작bpm {st.get('bpm')} "
              f"· Twirl {n_tw} · SetSpeed {n_ss}")
        # v2 방식(둘 다 무시)
        bpm0 = float(st["bpm"])
        tb = 0.0
        for i in range(1, len(ang)):
            if ang[i] == MIDSPIN or ang[i - 1] == MIDSPIN:
                continue
            tb += sweep_for(ang[i - 1], ang[i], True) / 180.0
        s0 = tb * 60.0 / bpm0
        print(f"  [v2] 둘 다 무시              : {tb:8.1f}박  ->  "
              f"{int(s0//60)}분 {s0%60:04.1f}초")
        a = simulate(f, twirl_before=True)
        b = simulate(f, twirl_before=False)
        if f in KNOWN:
            name, ref = KNOWN[f]
            print(f"  원곡 참고: {name} ~= {ref//60}분 {ref%60:02d}초")
            for lbl, v in (("진입 전", a), ("통과 후", b)):
                print(f"    오차({lbl}): {100.0*(v-ref)/ref:+7.1f}%")
