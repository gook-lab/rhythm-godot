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


def planet_offset(count):
    """ChartRuntime.planet_offset_deg 와 같아야 한다. (P-2)*180/P"""
    p = max(int(count), 2)
    return (p - 2) * 180.0 / p


def beats_for_tile(prev, cur):
    # U턴(sweep 0 = 360)은 wrap 경계 위라 float 오차에 0박/2박이 뒤집힌다.
    # 여유는 beats_for_tile_spin 과 같아야 한다 (거기 주석 참조).
    s = norm(cur - (prev + 180.0))
    if s < TURN_EPS_DEG or s > 360.0 - TURN_EPS_DEG:
        s = 360.0
    return s / 180.0


def signed_turn(b, spin):
    """홉 b 를 spin 방향으로 갈 때의 상대 회전(도), (-180, 180]."""
    t = (180.0 + spin * b * 180.0) % 360.0
    return t - 360.0 if t > 180.0 else t


def angles_from_hops(hops, start_deg=0.0, loop_guard_deg=None, offset=0.0):
    """hops[k] = 타일 k+2 에 도달하는 박자.

    타일 1 로 가는 첫 홉은 항상 1박이라 입력에서 뺐다.
    반환 길이는 len(hops)+2 — 마지막 하나는 최종 타일의 나갈 방향(미사용).

    loop_guard_deg 를 주면 twirl 을 자동 배치한다.
    0.5박 홉은 CCW 에서 항상 -90도라 네 번 연속이면 닫힌 사각형이 된다.
    누적 회전이 임계를 넘기 전에 방향을 뒤집으면 원 대신 지그재그가 된다.
    반환은 (각도배열, twirl타일목록).
    """
    ang = [norm(start_deg)]
    twirls = []
    spin = 1
    net = 0.0
    for k, b in enumerate(hops):
        if loop_guard_deg is not None:
            if abs(net + signed_turn(b, spin)) > loop_guard_deg + 1e-9:
                spin = -spin
                twirls.append(k + 1)   # 이 홉의 축 타일
                net = 0.0
        net += signed_turn(b, spin)
        ang.append(norm(ang[-1] + 180.0 + offset + spin * b * 180.0))
    ang.append(ang[-1])  # 최종 타일의 나갈 방향: 직선으로 채운다
    return ang, twirls


def spin_at(twirls, tile):
    s = 1
    for t in twirls:
        if t <= tile:
            s = -s
    return s


# ---------------------------------------------------------------- 경로 계획
# 리듬은 손댈 수 없다 — 홉의 박자가 스윕각을 결정하므로 상대 회전의 '크기'는
# 음악이 정한다. 채보 생성이 고를 수 있는 것은 두 가지뿐이다:
#   1. 회전 방향(twirl): 같은 홉이 +턴이 되느냐 -턴이 되느냐
#   2. 2박 홉의 분해: U턴 하나로 두느냐, 1+1 로 쪼개고 중간을 고스트로 두느냐
#      (2박은 스윕이 정확히 360도라 방향과 무관하게 '항상 U턴'이다.
#       연속되면 두 지점을 왕복하며 같은 자리에 수십 장이 쌓인다 —
#       실측 mureka_07 은 홉의 71%가 2박 채움이라 겹침 2179쌍이 나왔다.)
#
# 이 선택들을 빔서치로 고른다. 비용은 '새 타일이 기존 타일과 얼마나 겹치나'.
# 이전 loop_guard(누적 회전 270도에서 반전) 휴리스틱은 원만 못 그리게 할 뿐
# 경로가 자기 위로 되돌아오는 건 못 막았다 — 실측 겹침 95~99% 감소로 교체.

PEN_STACK = 9.0       # 거의 포개짐 (중심거리 < 0.42변)
PEN_OVERLAP = 4.0     # 확실히 겹침 (< 0.92변)
PEN_CROWD = 0.28      # 근접 (< 1.75변) — 퍼지게 만드는 압력
PEN_UTURN_BACK = 3.2  # U턴이 직전 타일을 되밟는 것 — 원작 어휘라 할인
COST_TWIRL = 1.4      # twirl 남발 방지 (겹침 하나보다 싸야 한다)
COST_GHOST = 2.2      # 고스트 남발 방지 (U턴 어휘가 완전히 사라지지 않게)
COST_MID = 1.2        # 중간회전 남발 방지 (twirl 과 같은 급의 '표현 하나')

## 체크포인트 간격(초). 곡이 150~180초라 이 값이면 5~6개가 놓인다.
## 너무 촘촘하면 죽어도 아무 손해가 없어 긴장이 사라지고, 너무 성기면
## 애초에 체크포인트를 넣은 이유(2분 되돌리기)가 안 풀린다.
CHECKPOINT_SEC = 30.0
BEAM_WIDTH = 64
_CELL = 1.75  # 공간 해시 셀 크기(변 배수). 3x3 조회가 PEN_CROWD 반경을 덮는다.


def _grid_put(grid, x, y, side):
    g = dict(grid)
    k = (int(x // (_CELL * side)), int(y // (_CELL * side)))
    g[k] = grid.get(k, ()) + ((x, y),)
    return g


def _grid_penalty(grid, x, y, side, back_pos=None):
    cx, cy = int(x // (_CELL * side)), int(y // (_CELL * side))
    pen = 0.0
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            for (qx, qy) in grid.get((cx + dx, cy + dy), ()):
                d = math.hypot(x - qx, y - qy)
                if d < 0.42 * side:
                    if back_pos is not None and \
                            math.hypot(qx - back_pos[0], qy - back_pos[1]) < 1.0:
                        pen += PEN_UTURN_BACK
                    else:
                        pen += PEN_STACK
                elif d < 0.92 * side:
                    pen += PEN_OVERLAP
                elif d < _CELL * side:
                    pen += PEN_CROWD
    return pen


def _decomps(b):
    """홉 b 의 표현 후보 [(서브홉들, 고스트 플래그들)]. 박자 합은 보존된다."""
    out = [((b,), (False,))]
    if abs(b - 2.0) < 1e-9:
        out.append(((1.0, 1.0), (True, False)))   # 직선 두 걸음 — 채움 체인의 본선
        out.append(((0.5, 1.5), (True, False)))   # 옆걸음 — 막힌 곳 탈출용
        out.append(((1.5, 0.5), (True, False)))
    return out


# ── 패턴(모티프) — 창작마당 채보의 어휘 ──────────────────────────────
# 같은 홉이 이어지는 구간(스트림·채움 체인)을 홉 단위 탐욕으로 풀면
# 스핀이 잡음처럼 튀어 모양이 '무늬'가 안 된다. 얼불춤 창작마당 채보는
# 반복 구간을 계단·지그재그·파도·나선 호 같은 정형 패턴으로 짠다 —
# 그래서 반복 구간은 템플릿 통째로 분기시킨다. 충돌 비용은 똑같이 적용되므로
# 막힌 자리에선 그 패턴이 자연히 탈락하고 다른 패턴이 뽑힌다.
MOTIF_MIN = 3    # 같은 홉이 이만큼 이어지면 패턴으로 다룬다
MOTIF_CHUNK = 8  # 패턴 한 번에 확정하는 최대 홉 수 — 빔이 경계에서 갈아탈 수 있다
PREF_EPS = 0.02  # 동점 패턴 사이의 순환 선호 — 구간마다 다른 무늬가 나오게 한다


def _steps_of(hops):
    """홉 리스트 -> [(홉값, 개수)]. 반복 구간은 MOTIF_CHUNK 단위로 자른다."""
    steps = []
    i = 0
    while i < len(hops):
        j = i
        while j < len(hops) and abs(hops[j] - hops[i]) < 1e-9:
            j += 1
        n = j - i
        if n >= MOTIF_MIN:
            while n > 0:
                take = min(n, MOTIF_CHUNK)
                steps.append((hops[i], take))
                n -= take
        else:
            steps.extend((hops[i], 1) for _ in range(n))
        i = j
    return steps


def _programs_for_step(b, cnt, s0):
    """스텝 하나의 후보 프로그램들. 프로그램 = 원본 홉당 (서브홉, 고스트, 스핀열).

    cnt == 1 은 기존 홉 단위 분기(분해 x 스핀), cnt > 1 은 패턴 템플릿이다.
    """
    if cnt == 1:
        progs = []
        for subs, gflags in _decomps(b):
            combos = [((), ())]
            for sb in subs:
                # 기하가 같은 분기(직선·U턴)는 안 뒤집는다 — 순수 비용이다.
                flip = abs(signed_turn(sb, 1) - signed_turn(sb, -1)) > 1e-9
                nc = []
                for (seq, mseq) in combos:
                    spins = (1, -1) if flip else (seq[-1] if seq else s0,)
                    for sp in spins:
                        for md in (False, True):
                            nc.append((seq + (sp,), mseq + (md,)))
                combos = nc
            progs.extend([(subs, gflags, seq, mseq)] for seq, mseq in combos)
        return progs

    # 아래는 '스핀 무늬'만 만든다. 중간회전 무늬는 _with_midspin 이 곱해 준다 —
    # 중간회전은 진행 방향을 180도 접는 것이라, 같은 스핀 무늬라도 완전히 다른
    # 모양이 된다(0.25박 스트림: 코일 vs 완만한 호).
    if abs(b - 1.0) < 1e-9:      # 1박은 직선뿐 — 스핀이 모양을 못 바꾼다
        base = [[((b,), (False,), (s0,))] * cnt]
    elif abs(b - 2.0) < 1e-9:    # 채움 체인: 직선 행진 · 계단 · 사다리 · U턴 왕복
        straight = [((1.0, 1.0), (True, False), (s0, s0))] * cnt
        stairs = [[((0.5, 1.5), (True, False), (s, s))] * cnt for s in (s0, -s0)]
        ladder = [((0.5, 1.5), (True, False),
                   ((s0, s0) if k % 2 == 0 else (-s0, -s0)))
                  for k in range(cnt)]
        uturns = [((b,), (False,), (s0,))] * cnt
        base = [straight] + stairs + [ladder, uturns]
    else:
        def spin_seq(period, start):
            return [[((b,), (False,), (start if (k // period) % 2 == 0 else -start,))]
                    for k in range(cnt)]

        base = []
        for start in (s0, -s0):
            base.append(sum(spin_seq(1, start), []))   # 지그재그 — 스트림의 본선
            base.append(sum(spin_seq(2, start), []))   # 2주기 파도
            base.append([((b,), (False,), (start,))] * cnt)  # 상수 스핀 — 나선 호
        base.append(sum(spin_seq(3, s0), []))          # 3주기 — 넓은 파도
    return _with_midspin(base)


## 스핀 무늬 하나당 중간회전 무늬 셋: 없음 · 전부 · 번갈아.
## 전수 조합(2^n)은 빔이 감당 못 하고, 무늬로서도 의미가 없다 —
## 사람이 읽는 건 '규칙적인 반복'이지 임의 배열이 아니다.
def _with_midspin(programs):
    out = []
    for prog in programs:
        for mode in range(3):
            out.append([(subs, gf, seq,
                         tuple((mode == 1) or (mode == 2 and (k + si) % 2 == 0)
                               for si in range(len(subs))))
                        for k, (subs, gf, seq) in enumerate(prog)])
    return out


def _apply_program(state, program, side):
    """상태에 프로그램(홉들의 열)을 적용해 (비용증분, 새 상태 필드들)을 계산."""
    (sc, ang, x, y, spin, ch, grid, prev) = state
    pen = 0.0
    a, xx, yy, g, pv, sp = ang, x, y, grid, prev, spin
    for (subs, gflags, seq, mseq) in program:
        for si, sb in enumerate(subs):
            if seq[si] != sp:
                pen += COST_TWIRL
                sp = seq[si]
            if gflags[si]:
                pen += COST_GHOST
            if mseq[si]:
                pen += COST_MID
            # 중간회전이면 두 행성이 교대하지 않아 기준각의 +180 이 빠진다.
            a = norm(a + (0.0 if mseq[si] else 180.0) + sp * sb * 180.0)
            nx = xx + math.cos(math.radians(a)) * side
            ny = yy - math.sin(math.radians(a)) * side
            back = pv if abs(sb - 2.0) < 1e-9 else None
            pen += _grid_penalty(g, nx, ny, side, back)
            g = _grid_put(g, nx, ny, side)
            pv = (xx, yy)
            xx, yy = nx, ny
    return (sc + pen, a, xx, yy, sp, ch + tuple(program), g, pv)


def plan_path(hops, start_deg=0.0, side=RADIUS, beam=BEAM_WIDTH):
    """hops(타일 2..N 도달 박자) -> (분해된 홉, twirl 타일, ghost 타일, 각도배열,
    원본 타일 -> 새 타일 인덱스 맵).

    빔서치: 상태 = (누적비용, 나갈각, 위치, 스핀, 선택 이력, 점유 그리드, 직전 타일).
    반복 구간은 패턴 템플릿 단위로, 나머지는 홉 단위로 분기한다.
    같은 (위치·각·스핀) 상태는 최저 비용만 남긴다.
    """
    a0 = norm(start_deg)
    x1 = math.cos(math.radians(a0)) * side
    y1 = -math.sin(math.radians(a0)) * side
    grid = _grid_put(_grid_put({}, 0.0, 0.0, side), x1, y1, side)
    states = [(0.0, a0, x1, y1, 1, (), grid, (0.0, 0.0))]
    for seg_no, (b, cnt) in enumerate(_steps_of(hops)):
        nxt = []
        for state in states:
            progs = _programs_for_step(b, cnt, state[4])
            for ti, prog in enumerate(progs):
                st = _apply_program(state, prog, side)
                pref = PREF_EPS * ((ti + seg_no) % len(progs)) if cnt > 1 else 0.0
                nxt.append((st[0] + pref,) + st[1:])
        nxt.sort(key=lambda st: st[0])
        seen = set()
        states = []
        for st in nxt:
            key = (round(st[2], 1), round(st[3], 1), round(st[1], 1), st[4])
            if key in seen:
                continue
            seen.add(key)
            states.append(st)
            if len(states) >= beam:
                break

    # 선택 이력 -> 최종 배열들
    choices = states[0][5]
    hops_out, twirls, ghosts, mids = [], [], [], []
    ang = [norm(start_deg)]
    spin, tile = 1, 0
    old_to_new = {0: 0, 1: 1}   # 타일 0(출발)과 1(첫 온셋)은 항상 그대로다
    old_tile = 1
    for (subs, gflags, seq, mseq) in choices:
        for si, sb in enumerate(subs):
            if seq[si] != spin:
                twirls.append(tile + 1)   # 이 홉의 축 타일
                spin = seq[si]
            a0 = ang[-1] + (0.0 if mseq[si] else 180.0)
            ang.append(norm(a0 + spin * sb * 180.0))
            hops_out.append(sb)
            tile += 1
            # 고스트도 중간회전도 '이 서브홉이 도달하는 타일'에 붙는다.
            if gflags[si]:
                ghosts.append(tile + 1)
            if mseq[si]:
                mids.append(tile + 1)
        old_tile += 1
        old_to_new[old_tile] = tile + 1   # 원본 홉이 끝나는 타일 = 실제(밟는) 타일
    ang.append(ang[-1])
    return hops_out, twirls, ghosts, mids, ang, old_to_new


TURN_EPS_DEG = 1.0  # ChartRuntime.TURN_EPS_DEG 와 같아야 한다


def beats_for_tile_spin(prev, cur, spin, mid=False, offset=0.0):
    base = (prev if mid else prev + 180.0) + offset
    d = (cur - base) if spin >= 0 else (base - cur)
    s = norm(d)
    # U턴은 sweep 0 = 360 이고 그 값이 정확히 wrap 경계에 얹혀 있다.
    # 여유 없이 한쪽만 보면 float 오차 0.001도에 0박/2박이 뒤집힌다
    # (ChartRuntime.beats_for_tile 의 주석 참조 — 실측 6.5초 어긋남).
    if s < TURN_EPS_DEG or s > 360.0 - TURN_EPS_DEG:
        s = 360.0
    return s / 180.0


def hops_of(ang, twirls=(), mids=(), offset=0.0):
    """ChartRuntime.beats_to_reach 와 같은 계산. 반환 길이 = len(ang)-1."""
    mset = set(mids)
    out = []
    for i in range(1, len(ang)):
        inc = ang[i - 2] if i >= 2 else ang[0]
        out.append(beats_for_tile_spin(inc, ang[i - 1], spin_at(twirls, i - 1),
                                       i in mset, offset))
    return out


def tile_positions(ang, r=RADIUS):
    """ChartRuntime.tile_positions 와 같은 계산 (y 반전 포함)."""
    p = [(0.0, 0.0)]
    for i in range(1, len(ang)):
        a = math.radians(ang[i - 1])
        p.append((p[-1][0] + math.cos(a) * r, p[-1][1] - math.sin(a) * r))
    return p


def verify(ang, hops_wanted, twirls=(), mids=(), offset=0.0):
    """런타임과 같은 계산으로 (1) 의도한 리듬이 나오는지 (2) 착지가 맞는지 확인.

    (2)가 이 파일에 있는 이유: 공전 끝점이 다음 타일 좌표와 어긋나는 버그가 있었다.
    직선 구간에선 오차 0 이라 안 보이고, 90도 턴에서 135px, U턴에서 192px 벗어났다.
    생성 단계에서 같이 잰다.
    """
    hops = hops_of(ang, twirls, mids, offset)
    # 암묵적 첫 홉(타일 1)은 '직선'이다 — angles[0] 이 진입이자 진출이라
    # 스윕이 180-offset 도가 된다. 2행성이면 1박이지만 3행성이면 2/3박이다.
    # 여기에 1.0 을 못 박아 두면 삼행성 채보가 첫 타일부터 검증에 걸린다.
    want = [(180.0 - offset) / 180.0] + list(hops_wanted)
    assert len(hops) == len(want), f"홉 개수 {len(hops)} != {len(want)}"
    for i, (g, w) in enumerate(zip(hops, want)):
        assert abs(g - w) < 1e-6, f"타일 {i+1} 홉: want {w}, got {g}"

    mset = set(mids)
    pos = tile_positions(ang)
    worst = 0.0
    for i in range(1, len(ang)):
        inc = ang[i - 2] if i >= 2 else ang[0]
        sp = spin_at(twirls, i - 1)
        md = i in mset
        sw = beats_for_tile_spin(inc, ang[i - 1], sp, md, offset) * 180.0 \
            * (1 if sp >= 0 else -1)
        end = math.radians(norm(inc + (0.0 if md else 180.0) + offset) + sw)
        lx = pos[i - 1][0] + math.cos(end) * RADIUS
        ly = pos[i - 1][1] - math.sin(end) * RADIUS
        worst = max(worst, math.hypot(lx - pos[i][0], ly - pos[i][1]))
    assert worst < 1e-3, f"착지 오차 {worst:.4f}px"
    return hops, worst


def fmt(x):
    # %g 는 6유효숫자라 2/3 같은 속도 배율이 0.666667 로 잘려
    # 긴 곡에서 히트타임이 밀린다. %.9g 는 .tres 의 float 정밀도보다 넉넉하다.
    return "%.9g" % x


# 카운트인(박). 첫 타일 앞에 두는 여유다.
# 얼불춤도 countdownTicks 로 4박을 센다. 두 가지 이유로 필요하다:
#   1. 음악적 — 플레이어가 박자를 잡을 시간이 있어야 한다.
#   2. 기술적 — AudioClock 워밍업(기본 100ms) 동안 렌더가 멈춰 있는데,
#      첫 타일이 0ms 에 있으면 warm 되는 순간 그만큼 건너뛰어 카메라가 32px 튄다.
LEAD_IN_BEATS = 4.0


def write_tres(name, title, bpm, hops_wanted, start_offset_ms=None, speed_changes=None,
               loop_guard_deg=None, holds=None, checkpoints=None, planets=2):
    """손으로 쓴 홉 리스트 -> .tres. 테스트/데모 채보 전용 (계획 없음)."""
    if start_offset_ms is None:
        start_offset_ms = LEAD_IN_BEATS * 60000.0 / bpm
    off = planet_offset(planets)
    ang, twirls = angles_from_hops(hops_wanted, loop_guard_deg=loop_guard_deg,
                                   offset=off)
    hops, worst = verify(ang, hops_wanted, twirls, offset=off)
    _emit_tres(name, title, bpm, ang, hops, twirls, [], [], checkpoints or [],
               start_offset_ms, speed_changes, worst, holds=holds or [],
               planets=planets)
    return ang


def difficulty_of(bpm, ang, hops, ghosts, mids, twirls, speed_changes, holds):
    """난이도 자동 산정 (adofai.gg 의 1~21 스케일을 빌린 규칙 기반).

    adofai.gg 는 사람이 매기지만 우리는 곡이 14개뿐이고 전부 파이프라인
    산출물이라, '잰 숫자'로 매긴다 — 스코어(opinion.mjs)와 같은 철학이다.

    성분(전부 실측 가능한 물리량):
      속도  = 피크 탭속(2초 창 95백분위) + 평균 탭속의 로그 혼합.
              로그인 이유: 3->6타/초가 6->9보다 훨씬 크게 어려워진다.
      압박  = 연속 간격 130ms 미만 비율 (한계 근접 구간이 얼마나 긴가).
      기술  = 중간회전·트월 밀도 + 토끼 구간 수 + 홀드 수. 각각 상한을
              둔다 — 기술 요소는 '더한다'지 속도를 대체하지 않는다.
    보정 기준(실측): 클릭 트랙(t01~) 1~3 · mureka 대역 6~13 이 되게 상수를
    맞췄다. 절대 척도가 아니라 '우리 목록 안의 서열'이 목적이다.
    """
    ghost_set = set(ghosts)
    full_hops = [1.0] + list(hops)
    hold_d = dict(holds)
    mult_d = dict(speed_changes or [])
    spb_ms = 60000.0 / bpm
    taps = []
    t_ms, cur = 0.0, 1.0
    for i in range(1, len(ang)):
        cur = mult_d.get(i - 1, cur)
        t_ms += (full_hops[i - 1] + 2.0 * hold_d.get(i - 1, 0.0)) * spb_ms / cur
        if i not in ghost_set:
            taps.append(t_ms)
    if len(taps) < 3:
        return 1.0, "탭 3개 미만"
    span_s = (taps[-1] - taps[0]) / 1000.0
    avg_tps = (len(taps) - 1) / max(span_s, 1e-6)
    # 탭마다 '이후 2초 창'의 탭 수를 세고 95백분위를 피크로 쓴다 —
    # 최댓값은 한 번의 버스트에, 평균은 쉬는 구간에 휘둘린다.
    import bisect
    win = [bisect.bisect_left(taps, t + 2000.0) - k for k, t in enumerate(taps)]
    win.sort()
    peak_tps = win[int(len(win) * 0.95)] / 2.0
    gaps_ms = [taps[k + 1] - taps[k] for k in range(len(taps) - 1)]
    frac_fast = sum(1 for g in gaps_ms if g < 130.0) / len(gaps_ms)
    n = float(len(ang))
    # 토끼 구간 수: 배율이 직전의 1.5배 이상 뛰는 경계만 센다 (보정 마크 제외).
    rabbits, prev = 0, 1.0
    for _, m in sorted(speed_changes or []):
        if m > prev * 1.5:
            rabbits += 1
        prev = m
    tech = (min(1.5, 30.0 * len(mids) / n) + min(1.0, 8.0 * len(twirls) / n)
            + 0.35 * min(rabbits, 2) + min(0.6, 0.1 * len(hold_d)))
    # 선형 혼합. 처음엔 로그 혼합이었는데 14곡이 11.1~13.0 으로 뭉쳤다 —
    # 서열이 목적인데 변별이 없으면 실패다. 선형으로 바꾸니 5.9~10.4 로 퍼진다.
    d = 0.9 * peak_tps + 0.75 * avg_tps + 3.2 * frac_fast + tech - 1.2
    return (max(1.0, min(21.0, round(d, 1))),
            "피크 %.1f타/초 · 평균 %.1f · 한계간격 %.0f%% · 기술 %.1f"
            % (peak_tps, avg_tps, 100.0 * frac_fast, tech))


def _emit_tres(name, title, bpm, ang, hops, twirls, ghosts, mids, checkpoints,
               start_offset_ms, speed_changes, worst, display_tiles=None,
               holds=(), planets=2):
    total = sum(hops)
    difficulty, diff_why = difficulty_of(bpm, ang, hops, ghosts, mids, twirls,
                                         speed_changes, holds)
    path = os.path.join(HERE, "charts", name + ".tres")
    with open(path, "w", encoding="utf-8") as f:
        f.write('[gd_resource type="Resource" script_class="Chart" load_steps=3 format=3]\n\n')
        f.write('[ext_resource type="Script" path="res://scripts/Chart.gd" id="1_chart"]\n')
        f.write('[ext_resource type="AudioStream" path="%s" id="2_audio"]\n\n' % AUDIO)
        f.write("[resource]\n")
        f.write('script = ExtResource("1_chart")\n')
        f.write("bpm = %s\n" % fmt(float(bpm)))
        if int(planets) != 2:
            f.write("planet_count = %d\n" % int(planets))
        f.write("angles = PackedFloat32Array(%s)\n" % ", ".join(fmt(a) for a in ang))
        f.write("start_offset_ms = %s\n" % fmt(float(start_offset_ms)))
        f.write('audio = ExtResource("2_audio")\n')
        if twirls:
            f.write("twirl_tiles = PackedInt32Array(%s)\n"
                    % ", ".join(str(t) for t in twirls))
        if ghosts:
            f.write("ghost_tiles = PackedInt32Array(%s)\n"
                    % ", ".join(str(t) for t in ghosts))
        if mids:
            f.write("midspin_tiles = PackedInt32Array(%s)\n"
                    % ", ".join(str(t) for t in mids))
        if checkpoints:
            f.write("checkpoint_tiles = PackedInt32Array(%s)\n"
                    % ", ".join(str(t) for t in checkpoints))
        if holds:
            f.write("hold_tiles = PackedVector2Array(%s)\n"
                    % ", ".join("%d, %s" % (int(t), fmt(float(n))) for t, n in holds))
        if speed_changes:
            # 배율도 fmt 를 거쳐야 한다. 여기만 %g 로 남겨두면 6유효숫자로 잘려
            # (1.04033 vs 1.0403271377884193) 그 구간의 모든 타일에 상대오차
            # 2.8e-6 이 곱해진다 — 실측 489타일 곡에서 0.034ms 누적.
            f.write("speed_changes = PackedVector2Array(%s)\n"
                    % ", ".join("%d, %s" % (int(i), fmt(m)) for i, m in speed_changes))
        # 마커를 그릴 타일만. 원곡 채보의 홉 단위 보정 배율(전사 잡음)은
        # speed_changes 에는 있어도 여기 없으면 화면에 안 나온다 (Chart.gd 주석).
        if speed_changes and display_tiles is not None:
            f.write("speed_display = PackedInt32Array(%s)\n"
                    % ", ".join(str(int(t)) for t in display_tiles))
        f.write("difficulty = %s\n" % fmt(float(difficulty)))
        f.write('title = "%s"\n' % title)
    print("%-20s 난이도 %.1f (%s)" % ("", difficulty, diff_why))
    print("%-20s 타일 %3d · %6.1f박 · %5.1fs · 카운트인 %.0fms · 착지오차 %.5fpx%s%s"
          % (name + ".tres", len(ang), total, total * 60.0 / bpm,
             start_offset_ms, worst,
             ("  twirl %d개" % len(twirls)) if twirls else "",
             ("  고스트 %d개" % len(ghosts)) if ghosts else ""))
    print("%-20s 홉: %s%s" % ("", [round(h, 3) for h in hops[:12]],
                              " ..." if len(hops) > 12 else ""))


def overlap_pairs(ang, side=RADIUS):
    """겹치는 타일 쌍 수 (인접 타일 제외). 경로 품질 지표 — 리듬과 무관하다."""
    pos = tile_positions(ang)
    grid = {}
    for i, (x, y) in enumerate(pos):
        grid.setdefault((int(x // side), int(y // side)), []).append(i)
    count = 0
    for (cx, cy), idxs in grid.items():
        for i in idxs:
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    for j in grid.get((cx + dx, cy + dy), ()):
                        if j - i >= 2 and math.hypot(
                                pos[i][0] - pos[j][0],
                                pos[i][1] - pos[j][1]) < 0.92 * side:
                            count += 1
    return count


def chart_from_song(meta_path, name, title, audio_res, speed_marks=None):
    """곡의 멜로디 온셋에서 채보를 뽑는다.

    곡과 채보가 같은 소스에서 나와야 둘이 갈라지지 않는다.
    손으로 다시 적으면 반드시 어긋난다.

    매핑:
      타일 1 이 첫 온셋에 떨어져야 한다. 첫 홉은 항상 1박이므로
      start_offset = (첫 온셋 - 1박). 그 앞은 자연스럽게 카운트인이 된다.

    경로는 plan_path 가 계획한다(스핀 선택 + 2박 홉의 고스트 분해).
    고스트가 끼면 타일 수가 온셋 수보다 많아지므로, 속도 타일 인덱스를
    old_to_new 로 새 번호에 사상하고, 밟는 타일의 누적박이 온셋과 일치하는지
    여기서 다시 검증한다.
    """
    meta = json.load(open(meta_path, encoding="utf-8"))
    bpm = float(meta["bpm"])
    onsets = meta["melody_onsets_beats"]

    # 속도 표시는 인자 우선, 없으면 메타(midi2song 이 넣는다), 그것도 없으면 없음.
    if speed_marks is None:
        speed_marks = meta.get("speed_marks_beats") or []

    # 간격은 1/12 격자로 스냅한다 (GRID — midi2song 과 같은 격자).
    # round(g, 6) 은 1/12 = 0.0833333... 을 0.083333 으로 잘라 홉당 3.3e-7박을
    # 흘린다. 사소해 보이지만 느린 곡(65.7bpm)의 1/12박 스트림 238개에서
    # 0.06ms 로 누적돼 0.01ms 검증 게이트를 넘었다. k/12 의 가장 가까운
    # 배정밀도 값을 쓰면 hops_of 가 각도(15k도)에서 되계산하는 값과 비트까지 같다.
    # 홀드: 온셋 인덱스 -> 바퀴 수. 홀드는 히트타임을 뒤로 미는 유일한 타일이라
    # (한 바퀴 = 2박, ChartRuntime 이 홉에 더한다) 다음 온셋까지의 간격에서
    # 2n박을 가져간다 — 경로 홉은 그만큼 짧아지고 온셋의 절대 시각은 그대로다.
    hold_orb = {}
    for hb, hn in (meta.get("hold_marks_beats") or []):
        idx = next((k for k, o in enumerate(onsets) if abs(o - hb) <= 1e-6), None)
        if idx is not None and idx < len(onsets) - 1:
            hold_orb[idx] = float(hn)

    gaps = [round((onsets[i] - onsets[i - 1] - 2.0 * hold_orb.get(i - 1, 0.0))
                  * 12.0) / 12.0
            for i in range(1, len(onsets))]

    # ── 토끼 구간 적용: 홉 박자 x m · 배율 x m — 벽시계 불변 ─────
    # wall = beats*spb/mult 이므로 둘을 같이 곱하면 히트타임이 그대로다.
    # 검증 게이트(replay vs expected < 0.01ms)가 이 항등식을 파일 단위로 잠근다.
    boosts = meta.get("boost_sections_beats") or []
    if boosts:
        for b0, b1, m in boosts:
            for i in range(len(gaps)):
                if onsets[i] >= b0 - 1e-9 and onsets[i + 1] <= b1 + 1e-9:
                    gaps[i] = round(gaps[i] * m * 12.0) / 12.0
        sm = sorted([list(x) for x in speed_marks])

        def _tempo_mult(b):
            v = 1.0
            for bb, mm in sm:
                if bb <= b + 1e-9:
                    v = mm
            return v

        marks = []
        for bb, mm in sm:
            k = 1.0
            for b0, b1, m in boosts:
                if b0 - 1e-9 <= bb < b1 - 1e-9:
                    k = m
            marks.append([bb, mm * k])
        for b0, b1, m in boosts:
            marks.append([b0, _tempo_mult(b0) * m])
            marks.append([b1, _tempo_mult(b1)])
        dd = {}
        for bb, mm in sorted(marks):
            dd[round(bb * 12.0)] = [bb, mm]   # 같은 박은 마지막 승
        speed_marks = [dd[kk] for kk in sorted(dd)]

    hops, twirls, ghosts, mids, ang, old_to_new = plan_path(gaps)
    _, worst = verify(ang, hops, twirls, mids)

    # 리듬 보존: 밟는(비고스트) 타일의 누적박 == 원본 온셋 간격의 누적.
    # 분해가 박자 합을 보존한다는 걸 '결과물'에서 다시 확인한다.
    cum = [0.0]
    for h in hops:
        cum.append(cum[-1] + h)
    ghost_set = set(ghosts)
    real = [cum[j - 1] for j in range(1, len(cum) + 1) if j not in ghost_set]
    want = [0.0]
    for g in gaps:
        want.append(want[-1] + g)
    assert len(real) == len(want), "밟는 타일 수 %d != 온셋 수 %d" % (len(real), len(want))
    for a, b in zip(real, want):
        assert abs(a - b) < 1e-6, "리듬 훼손: %.6f != %.6f" % (a, b)

    # 토끼/달팽이: (박, 배율) -> (원본 타일 인덱스, 배율) -> 새 인덱스.
    # 타일 i(원본 번호)는 onsets[i-1] 에 떨어지므로, 그 박 이상인 첫 온셋을 찾는다.
    # 주의: 게임은 홉 단위 상수 배속이라, 변경 박이 온셋과 일치해야 정확하다.
    # (midi2song 은 변경 지점에 타일을 강제 삽입해서 이를 보장한다)
    # 고스트 분해로 쪼개진 서브홉들은 축 타일이 앞 온셋 쪽이라 배율을 그대로
    # 물려받는다 — 변경은 항상 온셋(=밟는 타일)에서만 일어나므로 안전하다.
    speed_changes = []
    for beat, mult in speed_marks:
        idx = next((k for k, o in enumerate(onsets) if o >= beat - 1e-9), None)
        if idx is None:
            continue
        if abs(onsets[idx] - beat) > 1e-6:
            print("  !! 속도 변경 %.4f박이 온셋과 어긋남(가장 가까운 %.4f) — 홉 중간 변경은 표현 불가"
                  % (beat, onsets[idx]))
        speed_changes.append((old_to_new[idx + 1], mult))

    # 표시용 속도 타일(의도된 변경만). 원곡 모드에선 speed_changes(홉 단위
    # 보정 배율)와 갈라진다. 의도된 변경이 하나도 없으면 [-1] 로 '없음'을
    # 명시한다 — 필드 부재(구버전: 전부 표시)와 구분하기 위해서다.
    display_tiles = None
    disp_beats = meta.get("speed_display_beats")
    if disp_beats is not None and speed_changes:
        display_tiles = []
        for beat in disp_beats:
            idx = next((k for k, o in enumerate(onsets)
                        if abs(o - beat) <= 1e-6), None)
            if idx is not None:
                display_tiles.append(old_to_new[idx + 1])
        if not display_tiles:
            display_tiles = [-1]

    # ── 체크포인트 배치 ────────────────────────────────────────
    # 실제 히트타임을 되계산해서 일정 시간마다 찍는다. 박으로 세면 안 된다 —
    # 토끼/달팽이가 걸린 구간은 같은 박수라도 벽시계가 배로 차이난다.
    # 고스트는 밟지 않으므로 후보에서 뺀다(거기서 되살아나면 첫 입력이 없다).
    ghost_set = set(ghosts)
    spb_ms = 60000.0 / bpm
    # plan_path 의 hops 는 '타일 1 로 가는 첫 홉(항상 1박)'이 빠져 있다.
    # verify() 가 want = [1.0] + hops 로 비교하는 것과 같은 규약이다.
    full_hops = [1.0] + list(hops)
    # 홀드를 새 타일 번호로 사상한다. 온셋 idx 의 타일은 old idx+1 이다.
    holds_new = [(old_to_new[idx + 1], n) for idx, n in sorted(hold_orb.items())]
    hold_new = dict(holds_new)
    checkpoints = []
    t_ms, next_cp = 0.0, CHECKPOINT_SEC * 1000.0
    mult = dict(speed_changes)
    cur_mult = 1.0
    for i in range(1, len(ang)):
        cur_mult = mult.get(i - 1, cur_mult)
        # 홀드박(2n)도 벽시계를 차지한다 — 안 세면 홀드 많은 곡의 체크포인트가
        # 30초 간격보다 촘촘해진다.
        t_ms += (full_hops[i - 1] + 2.0 * hold_new.get(i - 1, 0.0)) \
            * spb_ms / cur_mult
        # 홀드 타일에서의 부활은 '깨자마자 잡고 버티기'라 손이 준비가 안 된다 —
        # 체크포인트 후보에서 뺀다(다음 타일로 밀릴 뿐이다).
        if t_ms >= next_cp and i not in ghost_set and i not in hold_new \
                and i < len(ang) - 1:
            checkpoints.append(i)
            next_cp = t_ms + CHECKPOINT_SEC * 1000.0

    # 벽시계 시작점: 메타가 주면 그대로(가변 템포 경로), 없으면 상수 템포 공식.
    so_ms = meta.get("start_offset_ms")
    if so_ms is None:
        start_beat = onsets[0] - 1.0
        assert start_beat > 0, "첫 온셋이 1박보다 빨라서 카운트인을 못 넣는다"
        so_ms = start_beat * 60000.0 / bpm
    global AUDIO
    prev_audio = AUDIO
    AUDIO = audio_res
    try:
        _emit_tres(name, title, bpm, ang, hops, twirls, ghosts, mids, checkpoints,
                   so_ms, speed_changes, worst, display_tiles, holds_new)
    finally:
        AUDIO = prev_audio
    print("%-20s 첫 온셋 %g박 -> 타일0 @ %.3fs · 심판 타일 %d · 겹침 %d쌍"
          % ("", onsets[0], so_ms / 1000.0, len(want), overlap_pairs(ang)))
    if holds_new:
        print("%-20s 홀드 타일: %s" % ("", " ".join(
            "타일%d x%g바퀴" % (t, n) for t, n in holds_new)))
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
    # 홀드: 타일 2 에서 한 바퀴, 타일 5 에서 두 바퀴 더 돈다.
    # 밟고 -> 누른 채로 도는 걸 보고 -> 마지막 바퀴가 끝나는 순간 뗀다.
    write_tres("t06_hold", "06 홀드", 120, [1, 1, 1, 1, 1, 1],
               holds=[(2, 1), (5, 2)], checkpoints=[4])
    # 삼행성: 같은 리듬(전부 1박)인데 기하가 다르다. 도는 행성이 60도 더
    # 돌아간 데서 출발하므로 직선 타일이 스윕 120도(=2/3박)가 된다.
    write_tres("t07_three", "07 삼행성", 120, [1, 1, 1, 1, 1, 1, 1], planets=3)

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
