#!/usr/bin/env python3
"""
라우드니스 정규화 단독 테스트.

곡의 '들리는 크기'는 판정 효과음과의 균형을 결정한다 — 곡마다 제각각이면
같은 효과음이 어떤 곡에서만 튀어나온다. 그래서 여기서 잠그는 건 세 가지다:
목표 RMS 도달 · 천장 준수 · 리미터 손실 보상.

전부 실제로 한 번씩 틀렸던 것들이다(2026-08-10):
  - 블록 사이 게인 보간이 그 블록의 필요 게인을 넘겨 천장을 0.898 로 초과
  - 한 패스만 걸어 리미터가 깎은 만큼을 안 되돌려 목표보다 3.7dB 낮게 앉음
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_song import loudness_normalize, _gain_and_limit, TARGET_RMS

FAIL = 0


def ok(cond, what):
    global FAIL
    print("  %s %s" % ("ok  " if cond else "FAIL", what))
    if not cond:
        FAIL += 1


def rms(buf):
    return math.sqrt(sum(v * v for v in buf) / len(buf)) if buf else 0.0


def db(x):
    return 20.0 * math.log10(x) if x > 0 else -999.0


def tone(n, amp, period=100):
    return [amp * math.sin(2 * math.pi * i / period) for i in range(n)]


def spiky(n, body, peak, every):
    """조용한 본체 + 드문 큰 피크. 크레스트가 큰 실제 믹스를 흉내낸다."""
    b = tone(n, body)
    for i in range(0, n, every):
        b[i] = peak
    return b


def main():
    print("목표 RMS 도달 (누를 게 없는 신호)")
    # 피크가 천장 아래라 리미터가 안 걸린다 — 게인만으로 정확히 맞아야 한다.
    out = loudness_normalize(tone(60000, 0.02))
    ok(abs(db(rms(out)) - db(TARGET_RMS)) < 0.01,
       "리미터 미개입 시 목표에 정확히 — %.3fdB (목표 %.3f)"
       % (db(rms(out)), db(TARGET_RMS)))
    ok(max(map(abs, out)) <= 0.89 + 1e-9, "천장 이하")

    print("\n천장 준수 (블록 보간이 넘기던 버그)")
    # 게인이 블록마다 오르내리는 신호. 보간값을 그 블록의 필요 게인으로
    # 클램프하지 않으면 여기서 0.898 처럼 천장을 넘는다.
    out = loudness_normalize(spiky(200000, 0.05, 0.95, 3000))
    ok(max(map(abs, out)) <= 0.89 + 1e-9,
       "잦은 피크에서도 천장 이하 — 최대 %.6f" % max(map(abs, out)))
    out2 = loudness_normalize(spiky(200000, 0.03, 0.99, 997))
    ok(max(map(abs, out2)) <= 0.89 + 1e-9,
       "블록 경계와 어긋난 주기에서도 천장 이하 — 최대 %.6f" % max(map(abs, out2)))

    print("\n리미터 손실 보상 (한 패스로는 목표에 못 닿는다)")
    sig = spiky(200000, 0.06, 0.9, 5000)
    one = _gain_and_limit(sig, TARGET_RMS, 0.89)
    many = loudness_normalize(sig)
    ok(db(rms(one)) < db(TARGET_RMS) - 0.3,
       "1패스는 목표보다 낮게 앉는다 — %.2fdB" % db(rms(one)))
    ok(db(rms(many)) > db(rms(one)) + 0.2,
       "반복이 그만큼 되돌린다 — %.2fdB -> %.2fdB" % (db(rms(one)), db(rms(many))))
    ok(max(map(abs, many)) <= 0.89 + 1e-9, "되돌리면서도 천장은 지킨다")

    print("\n상한 (억지로 끌어올려 납작하게 만들지 않는다)")
    # 크레스트가 극단이면 목표까지 못 간다. 그게 옳다 — 거기까지 밀면
    # 리미터가 상시 걸려 소리가 뭉개진다.
    ext = loudness_normalize(spiky(200000, 0.005, 0.98, 500))
    ok(db(rms(ext)) < db(TARGET_RMS),
       "극단 크레스트는 목표에 못 미친다(의도) — %.1fdB" % db(rms(ext)))
    ok(max(map(abs, ext)) <= 0.89 + 1e-9, "그래도 천장은 지킨다")

    print("\n스테레오 인터리브 (원곡 오디오 경로)")
    # L=R 인 신호를 넣으면, 나온 뒤 벌어진 정도가 곧 '채널 연동이 깨진 정도'다.
    # 채널을 갈라 따로 정규화하면 여기가 크게 벌어지고 이미지가 좌우로 흔들린다.
    frames = 100000
    mono = tone(frames, 0.05)
    for i in range(0, frames, 1500):
        mono[i] = 0.95
    inter = []
    for v in mono:
        inter += [v, v]
    so = loudness_normalize(inter)
    lch, rch = so[0::2], so[1::2]
    worst = max(abs(db(abs(l)) - db(abs(r)))
                for l, r in zip(lch, rch) if abs(l) > 1e-6 and abs(r) > 1e-6)
    ok(worst < 0.2,
       "L/R 게인 차가 가청 한계 훨씬 아래 — 최대 %.4fdB (블록 안 보간 몫)" % worst)
    ok(max(map(abs, so)) <= 0.89 + 1e-9, "스테레오도 천장 이하")
    # 모노와 완전히 같지는 않다. 블록이 '샘플' 단위(64)라 인터리브 스테레오에서는
    # 같은 64샘플이 32프레임 = 절반 시간이고, 그만큼 리미터가 빠르게 따라간다
    # (덜 누르니 조금 더 크게 앉는다). 실측 0.87dB — 곡 간 편차(0.7dB)와 같은
    # 급이라 실제로는 문제가 안 됐다(원곡 스테레오 곡이 -15.02dB 로 가장 정확했다).
    # 이 값이 커지면 블록을 프레임 단위로 바꿔야 한다는 신호다.
    gap = abs(db(rms(so)) - db(rms(loudness_normalize(mono))))
    ok(gap < 1.5, "모노와의 차이가 곡 간 편차 급을 안 넘는다 — %.2fdB" % gap)

    print("\n경계 입력")
    ok(loudness_normalize([]) == [], "빈 버퍼")
    ok(loudness_normalize([0.0] * 1000) == [0.0] * 1000, "무음은 그대로(0 나눗셈 없음)")

    print("\n" + ("PASS" if FAIL == 0 else "FAILED %d" % FAIL))
    sys.exit(FAIL)


if __name__ == "__main__":
    main()
