#!/usr/bin/env python3
"""
밴드리미티드 웨이브테이블 신디사이저. 순수 파이썬, 의존성 0.

왜 새로 만들었나 (2026-08-10, "원곡처럼 안 들린다"):
  이전 합성은 `1.0 if ph < duty else -1.0` 짜리 나이브 사각파였다. 두 가지가 문제다.

  1. 에일리어싱. 이상적인 사각파는 하모닉이 무한대까지 있는데 48kHz 로 샘플링하면
     24kHz 위의 성분이 전부 아래로 접혀 들어온다. 접힌 성분은 기본 주파수의
     정수배가 아니라서 화음에 안 녹고 '지직'거리는 잡음으로 들린다.
     게다가 엣지 위치가 샘플 격자에 반올림되며 음정마다 다르게 흔들려서,
     같은 음을 길게 끌면 소리가 미세하게 떨린다.
  2. 엔벌로프가 평평했다. 어택 5ms 뒤 릴리스 전까지 진폭이 1.0 고정.
     악기가 뭐든 오르간처럼 '웅' 하고 버틴다. 피아노도 기타도 안 뜯긴다.
     사람이 '노래'로 듣는 신호의 큰 부분이 이 시간축 모양인데 그게 없었다.

해법:
  파형을 미리 '나이퀴스트 아래 하모닉만' 더해서 표로 굽는다(가산 합성).
  재생은 표를 읽는 것뿐이라 런타임 비용은 오히려 더 싸고, 접힘이 원천적으로 없다.

  표를 음마다 구울 필요는 없다. 하모닉 수를 2의 거듭제곱으로 버킷팅해서
  9개(1,2,4,...,256)만 굽고 음높이에 맞는 걸 고른다 — 고전적인 웨이브테이블
  밉맵이다. 굽는 비용이 2048 x (1+2+...+256) = 약 100만 연산으로 끝난다.

  하모닉 상한은 음색 손잡이도 된다. 베이스를 16하모닉으로 자르면 런타임
  필터 없이 둥근 소리가 된다 — 8.8M 샘플에 필터를 거는 것보다 공짜에 가깝다.

성능: 표 읽기는 위상 누적 + 선형보간이라 나이브 사각파의 `%` 와 비교문보다
  느리지 않다. 엔벌로프도 매 샘플 exp() 를 부르지 않고 곱셈 하나로 감쇠시킨다.
"""
import math

SR = 48000
TABLE = 2048          # 표 길이. 2의 거듭제곱이라 인덱싱이 싸다
MAX_HARMONICS = 256   # 이 위로는 사람이 음색 차이를 못 듣는다
_NYQUIST = SR * 0.5


# ─────────────────────────────────────────────────── 표 굽기 (가산 합성)
def _bake(wave, harmonics):
    """하모닉 harmonics 개까지만 더한 한 주기. 길이 TABLE+1 (끝에 보간용 여벌)."""
    tab = [0.0] * (TABLE + 1)
    step = 2.0 * math.pi / TABLE
    if wave == "square":
        # 홀수 하모닉, 진폭 1/k
        ks = [(k, 1.0 / k) for k in range(1, harmonics + 1, 2)]
    elif wave == "saw":
        # 전 하모닉, 진폭 1/k. 사각보다 성분이 촘촘해 두껍게 들린다
        ks = [(k, 1.0 / k) for k in range(1, harmonics + 1)]
    elif wave == "triangle":
        # 홀수 하모닉, 진폭 1/k^2 에 부호 교대 — 사각보다 훨씬 부드럽다
        ks = [(k, (1.0 if (k // 2) % 2 == 0 else -1.0) / (k * k))
              for k in range(1, harmonics + 1, 2)]
    else:
        raise ValueError("알 수 없는 파형: %s" % wave)
    for k, a in ks:
        for i in range(TABLE):
            tab[i] += a * math.sin(k * i * step)
    peak = max(abs(v) for v in tab) or 1.0
    for i in range(TABLE):
        tab[i] /= peak
    tab[TABLE] = tab[0]   # 감싸기 보간용
    return tab


_CACHE = {}


def _table(wave, harmonics):
    key = (wave, harmonics)
    if key not in _CACHE:
        _CACHE[key] = _bake(wave, harmonics)
    return _CACHE[key]


def table_for(wave, freq, cap=MAX_HARMONICS):
    """freq 를 접힘 없이 낼 수 있는 표. 하모닉 수를 2의 거듭제곱으로 버킷팅한다."""
    room = int(_NYQUIST / max(freq, 1.0))
    h = 1
    while h * 2 <= room and h * 2 <= cap:
        h *= 2
    return _table(wave, max(1, h))


# ─────────────────────────────────────────────────── 악기 역할
# (파형, 하모닉 상한, 어택s, 디케이s, 서스테인비, 릴리스s, 디튠센트)
#
# 하모닉 상한이 음색 손잡이다. 낮추면 둥글어진다 — 런타임 필터가 필요 없다.
# 디케이/서스테인이 '뜯는 소리'와 '버티는 소리'를 가른다. 이게 없어서
# 전부 오르간처럼 들렸다.
ROLES = {
    # 리드: 살짝 뜯고 버틴다. 디튠 두 겹이라 두껍게 들린다.
    "lead":   ("saw",      32, 0.004, 0.09, 0.72, 0.10, 7.0),
    # 베이스: 어둡게 잘라야 저역이 뭉치지 않는다.
    "bass":   ("triangle", 16, 0.006, 0.14, 0.82, 0.07, 0.0),
    # 뜯는 악기(기타·피아노): 서스테인 0 — 끝까지 감쇠한다.
    "pluck":  ("saw",      32, 0.003, 0.60, 0.00, 0.06, 4.0),
    # 받쳐주는 성부: 천천히 들어와 뒤에 깔린다.
    "pad":    ("triangle", 24, 0.030, 0.20, 0.70, 0.18, 5.0),
}

CENT = 2.0 ** (1.0 / 1200.0)


def midi_hz(n):
    return 440.0 * (2.0 ** ((n - 69) / 12.0))


def render(buf, t0, dur_s, freq, role, amp):
    """buf(초 도메인 float 리스트)의 t0 초 위치에 음 하나를 더한다.

    엔벌로프는 매 샘플 exp() 를 부르지 않는다. 감쇠는 곱셈 하나로 재귀시키고
    (e *= k), 어택만 선형으로 올린다. 8.8M 샘플에서 이 차이가 크다.
    """
    wave, cap, atk, dec, sus, rel, detune = ROLES[role]
    tab = table_for(wave, freq, cap)

    start = int(t0 * SR)
    if start >= len(buf):
        return
    # 릴리스는 음 길이 뒤에 꼬리로 붙인다. 뜯는 악기는 디케이가 끝나면
    # 어차피 무음이라 길게 잡아도 비용이 안 든다(아래 조기 종료).
    n = max(1, int(dur_s * SR))
    tail = int(rel * SR)
    total = min(n + tail, len(buf) - start)
    if total <= 0:
        return

    n_atk = max(1, int(atk * SR))
    # 목표까지 지수 감쇠. 시상수를 디케이 시간의 1/3 로 두면 그 시간에 95% 도달한다.
    k_dec = math.exp(-3.0 / max(1.0, dec * SR))
    k_rel = math.exp(-3.0 / max(1.0, rel * SR))

    inc = freq / SR
    ph = 0.0
    ph2 = 0.0
    inc2 = inc * (CENT ** detune) if detune else 0.0

    env = 0.0
    lvl = 1.0          # 디케이가 sus 를 향해 내려가는 현재 배율
    for i in range(total):
        j = start + i
        if i < n_atk:
            env = (i + 1) / n_atk
        elif i < n:
            lvl = sus + (lvl - sus) * k_dec
            env = lvl
        else:
            env *= k_rel
            if env < 0.0005:
                break          # 다 죽었다 — 남은 샘플을 돌 이유가 없다
        # 표 읽기 + 선형보간
        ph += inc
        if ph >= 1.0:
            ph -= 1.0
        x = ph * TABLE
        i0 = int(x)
        v = tab[i0] + (tab[i0 + 1] - tab[i0]) * (x - i0)
        if inc2:
            ph2 += inc2
            if ph2 >= 1.0:
                ph2 -= 1.0
            y = ph2 * TABLE
            j0 = int(y)
            v = (v + tab[j0] + (tab[j0 + 1] - tab[j0]) * (y - j0)) * 0.5
        buf[j] += v * env * amp


# ─────────────────────────────────────────────────── 드럼
_noise_state = 12345


def noise():
    global _noise_state
    _noise_state = (_noise_state * 1103515245 + 12345) & 0x7FFFFFFF
    return (_noise_state / 0x3FFFFFFF) - 1.0


def kick(buf, t0, amp=0.72):
    """피치 스윕 + 클릭. 클릭이 있어야 작은 스피커에서도 박자가 들린다."""
    start = int(t0 * SR)
    n = int(0.18 * SR)
    for i in range(n):
        j = start + i
        if j >= len(buf):
            break
        t = i / SR
        f = 150.0 * math.exp(-t * 38.0) + 48.0
        v = math.sin(2.0 * math.pi * f * t) * math.exp(-t * 16.0)
        if i < 240:                      # 5ms 어택 클릭
            v += noise() * 0.35 * (1.0 - i / 240.0)
        buf[j] += v * amp


def _pole(hz):
    return 1.0 - math.exp(-2.0 * math.pi * hz / SR)


## 노이즈는 반드시 대역을 잘라서 써야 한다.
##
## 흰 노이즈는 에너지가 Hz 당 균일해서 '최상위 한 옥타브'(12~24kHz)에만 전체의
## 절반이 실린다. 그대로 쓰면 실측 스펙트럼 중심이 햇 15.2kHz · 스네어 11.9kHz
## 였고, 곡 전체 중심이 10.2kHz 까지 끌려 올라갔다 — 악기가 아니라 '치익' 하는
## 히스다(대중음악의 중심은 보통 1~4kHz).
##
## 1극(6dB/oct)으로는 못 잡는다. 11kHz 에서 잘라도 한 옥타브 위가 6dB 밖에
## 안 줄어 최상위 옥타브가 그대로 남는다 — 실측 12.5kHz 로 별로 안 내려갔다.
## 3극(18dB/oct)으로 캐스케이드해야 실제로 눌린다.
SNARE_BAND = (1200.0, 5000.0)
HAT_BAND = (3200.0, 7000.0)

## 대역통과는 진폭을 크게 깎는다. 통과 후 피크를 원래대로 되돌리는 보정값이고,
## 아래 __main__ 자가측정이 실제 피크를 찍어 준다.
SNARE_MAKEUP = 5.4
HAT_MAKEUP = 6.0


def _band_noise(a_lo, a_hi, state):
    """3극 저역통과 - 1극 저역통과 = 18dB/oct 대역통과. state 는 길이 4 리스트."""
    state[0] += (noise() - state[0]) * a_hi
    state[1] += (state[0] - state[1]) * a_hi
    state[2] += (state[1] - state[2]) * a_hi
    state[3] += (state[2] - state[3]) * a_lo
    return state[2] - state[3]


def snare(buf, t0, amp=0.6):
    """대역 정형 노이즈 + 두 음의 몸통. 단일 사인은 '뿅'이라 스네어가 안 된다."""
    start = int(t0 * SR)
    n = int(0.16 * SR)
    a_lo, a_hi = _pole(SNARE_BAND[0]), _pole(SNARE_BAND[1])
    st = [0.0, 0.0, 0.0, 0.0]
    for i in range(n):
        j = start + i
        if j >= len(buf):
            break
        t = i / SR
        e = math.exp(-t * 24.0)
        body = (math.sin(2.0 * math.pi * 185.0 * t) * 0.6
                + math.sin(2.0 * math.pi * 278.0 * t) * 0.4)
        buf[j] += (_band_noise(a_lo, a_hi, st) * SNARE_MAKEUP * 0.65
                   + body * 0.35) * e * amp


def hat(buf, t0, amp=0.13, open_=False):
    start = int(t0 * SR)
    n = int((0.12 if open_ else 0.035) * SR)
    d = 22.0 if open_ else 95.0
    a_lo, a_hi = _pole(HAT_BAND[0]), _pole(HAT_BAND[1])
    st = [0.0, 0.0, 0.0, 0.0]
    for i in range(n):
        j = start + i
        if j >= len(buf):
            break
        buf[j] += (_band_noise(a_lo, a_hi, st) * HAT_MAKEUP
                   * math.exp(-(i / SR) * d) * amp)


def drum(buf, t0, pitch, vel):
    a = vel / 100.0
    if pitch in (35, 36):
        kick(buf, t0, 0.72 * a)
    elif pitch in (38, 40):
        snare(buf, t0, 0.55 * a)
    elif pitch in (46, 44):
        hat(buf, t0, 0.13 * a, open_=True)
    else:
        hat(buf, t0, 0.13 * a)


# ─────────────────────────────────────────────────── 공간감
def slapback(buf, delay_s=0.085, gain=0.22):
    """짧은 지연을 되먹여 공간감을 준다.

    제대로 된 리버브(콤 여러 개 + 올패스)는 순수 파이썬으로 8.8M 샘플에
    돌리면 수십 초가 걸린다. 제자리 단일 탭은 한 번 훑는 것으로 끝나고,
    되먹임이라 지연이 겹겹이 옅어지며 짧은 잔향처럼 들린다.
    gain < 0.5 면 발산하지 않는다.
    """
    d = int(delay_s * SR)
    if d <= 0:
        return
    for i in range(d, len(buf)):
        buf[i] += buf[i - d] * gain


# ─────────────────────────────────────────────────── 자가측정
# 위 상수(대역·보정게인)는 귀가 아니라 이 숫자로 골랐다.
#   python3 tools/synth.py
# 스펙트럼 중심이 곧 '밝기'다. 대중음악 믹스는 보통 1~4kHz 이고,
# 흰 노이즈를 그대로 쓰면 12kHz 를 넘어 악기가 아니라 히스로 들린다.
if __name__ == "__main__":
    try:
        import numpy as np
    except ImportError:
        raise SystemExit("자가측정에는 numpy 가 필요하다 (합성 자체는 stdlib 만 쓴다)")

    def report(buf, label):
        x = np.asarray(buf)
        n = 1 << 15
        seg = x[:n] if len(x) >= n else np.pad(x, (0, n - len(x)))
        mag = np.abs(np.fft.rfft(seg * np.hanning(n)))
        f = np.fft.rfftfreq(n, 1.0 / SR)
        print("  %-10s 중심 %6.0f Hz · >12kHz %5.1f%% · 피크 %.2f"
              % (label, (mag * f).sum() / mag.sum(),
                 100.0 * mag[f > 12000].sum() / mag.sum(), np.abs(x).max()))

    print("드럼 (피크는 1.0 을 넘으면 안 된다 — 합에서 혼자 먹는다)")
    for nm, fn, kw in (("킥", kick, {}), ("스네어", snare, {}),
                       ("클로즈햇", hat, {}), ("오픈햇", hat, {"open_": True})):
        b = [0.0] * SR
        fn(b, 0.0, **kw)
        report(b, nm)

    print("음정 악기 (역할별 음색)")
    for role in ROLES:
        b = [0.0] * SR
        render(b, 0.0, 0.5, 440.0, role, 0.25)
        report(b, role)

    print("접힘(에일리어싱) — 기본주파수 정수배 밖으로 새는 에너지")
    for pitch in (57, 69, 81, 93):
        f0 = midi_hz(pitch)
        tab = table_for("saw", f0, 64)
        n = 1 << 15
        ph, out = 0.0, np.empty(n)
        for i in range(n):
            ph += f0 / SR
            if ph >= 1.0:
                ph -= 1.0
            x = ph * TABLE
            i0 = int(x)
            out[i] = tab[i0] + (tab[i0 + 1] - tab[i0]) * (x - i0)
        mag = np.abs(np.fft.rfft(out * np.hanning(n))) ** 2
        fr = np.fft.rfftfreq(n, 1.0 / SR)
        m = np.zeros(len(fr), bool)
        for h in range(1, int(SR * 0.5 / f0) + 1):
            m |= np.abs(fr - h * f0) < (f0 * 0.06 + 6.0)
        m[fr < 20] = True
        print("  %6.1f Hz  %.4f%%" % (f0, 100.0 * mag[~m].sum() / mag.sum()))
