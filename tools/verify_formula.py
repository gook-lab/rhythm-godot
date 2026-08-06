#!/usr/bin/env python3
"""T10 v2 — 실제 채보(pathData 포맷 포함)로 각도->박자 공식 통계 검증."""
import json, re, sys, math
from collections import Counter

# pathData 문자 -> 각도. 출처: M1n3c4rt/adofaipy __init__.py:41 (독립 구현체)
PATHCHARS = {"R":0,"p":15,"J":30,"E":45,"T":60,"o":75,"U":90,"q":105,"G":120,
             "Q":135,"H":150,"W":165,"L":180,"x":195,"N":210,"Z":225,"F":240,
             "V":255,"D":270,"Y":285,"B":300,"C":315,"M":330,"A":345,"!":999}
MIDSPIN = 999


def load_adofai(path):
    """.adofai 는 '거의' JSON 이다. 실측한 위반 3종을 고친다."""
    s = open(path, encoding="utf-8-sig").read()
    s = re.sub(r",\s*,", ",", s)               # 1) 이중 콤마: "difficulty": 1, ,
    s = re.sub(r",(\s*[}\]])", r"\1", s)       # 2) 트레일링 콤마: false , }
    s = re.sub(r"([}\]])(\s*)\"", r"\1,\2\"", s)  # 3) 섹션 사이 콤마 누락: ] "decorations"
    s = re.sub(r",\s*,", ",", s)               # (1을 다시 — 3이 만들 수 있음)
    return json.loads(s)


def angles_of(d):
    if "angleData" in d:
        return list(d["angleData"]), "angleData"
    if "pathData" in d:
        return [PATHCHARS[c] for c in d["pathData"]], "pathData"
    return None, None


def normalize360(x):
    return math.fmod(math.fmod(x, 360.0) + 360.0, 360.0)


def beats_for_tile(prev, cur):
    sweep = normalize360(cur - (prev + 180.0))
    if abs(sweep) < 1e-9:
        sweep = 360.0
    return sweep / 180.0


NICE = {0.125:"1/8", 0.25:"1/4", 1/3:"1/3", 0.375:"3/8", 0.5:"1/2", 2/3:"2/3",
        0.75:"3/4", 1.0:"1", 1.25:"5/4", 4/3:"4/3", 1.5:"3/2", 1.75:"7/4",
        2.0:"2", 2.25:"9/4", 2.5:"5/2", 3.0:"3", 3.5:"7/2", 4.0:"4", 5.0:"5",
        6.0:"6", 8.0:"8", 12.0:"12", 16.0:"16"}


def nice_name(b):
    for n, name in NICE.items():
        if abs(b - n) < 1e-6:
            return name
    return None


def report(path):
    d = load_adofai(path)
    ang, fmt = angles_of(d)
    st = d.get("settings", {})
    print(f"\n{'='*70}\n{path}   [{fmt}]")
    print(f"  타일 {len(ang)}개 · bpm {st.get('bpm')} · song {st.get('song','')!r}"
          f" · artist {st.get('artist','')!r}")

    mids = sum(1 for a in ang if a == MIDSPIN)
    if mids:
        print(f"  midspin(!) {mids}개 — 공식 전제를 깨므로 제외하고 잰다")

    beats, skipped = [], 0
    for i in range(1, len(ang)):
        if ang[i] == MIDSPIN or ang[i-1] == MIDSPIN:
            skipped += 1
            continue
        beats.append(beats_for_tile(ang[i-1], ang[i]))

    c = Counter(round(b, 6) for b in beats)
    total = len(beats)
    musical = sum(n for b, n in c.items() if nice_name(b))
    print(f"  측정 대상 {total}개 (midspin 인접 {skipped}개 제외)")
    print(f"  박자값 분포 (상위 12):")
    for b, n in c.most_common(12):
        nm = nice_name(b)
        mark = f"OK {nm:>4}" if nm else "??  ---"
        print(f"    {mark}  {b:>9.5f} 박  x{n:<5d} ({100.0*n/total:5.2f}%)")
    print(f"    고유 박자값 {len(c)}종")
    bad = [(b, n) for b, n in c.items() if not nice_name(b)]
    if bad:
        bad.sort(key=lambda x: -x[1])
        print(f"  비음악적 값 상위: {[(round(b,4), n) for b, n in bad[:6]]}")
    pct = 100.0 * musical / total if total else 0
    print(f"  ==> 음악적인 값 비율: {musical}/{total} = {pct:.2f}%")
    return pct


if __name__ == "__main__":
    pcts = []
    for f in sys.argv[1:]:
        try:
            p = report(f)
            if p is not None:
                pcts.append((f, p))
        except Exception as e:
            print(f"\n{f}: 파싱 실패 — {type(e).__name__}: {e}")
    print(f"\n{'='*70}\n판정")
    for f, p in pcts:
        v = "PASS" if p >= 95 else ("의심" if p >= 70 else "FAIL")
        print(f"  {v:<5} {p:6.2f}%  {f}")
