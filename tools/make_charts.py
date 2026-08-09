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


def angles_from_hops(hops, start_deg=0.0, loop_guard_deg=None):
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
        ang.append(norm(ang[-1] + 180.0 + spin * b * 180.0))
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
            combos = [()]
            for sb in subs:
                # 기하가 같은 분기(직선·U턴)는 안 뒤집는다 — 순수 비용이다.
                flip = abs(signed_turn(sb, 1) - signed_turn(sb, -1)) > 1e-9
                combos = [seq + (s,) for seq in combos
                          for s in ((1, -1) if flip else (seq[-1] if seq else s0,))]
            progs.extend([(subs, gflags, seq)] for seq in combos)
        return progs

    if abs(b - 1.0) < 1e-9:      # 1박은 직선뿐 — 스핀이 모양을 못 바꾼다
        return [[((b,), (False,), (s0,))] * cnt]

    if abs(b - 2.0) < 1e-9:      # 채움 체인: 직선 행진 · 계단 · 사다리 · U턴 왕복
        straight = [((1.0, 1.0), (True, False), (s0, s0))] * cnt
        stairs = [[((0.5, 1.5), (True, False), (s, s))] * cnt for s in (s0, -s0)]
        ladder = [((0.5, 1.5), (True, False),
                   ((s0, s0) if k % 2 == 0 else (-s0, -s0)))
                  for k in range(cnt)]
        uturns = [((b,), (False,), (s0,))] * cnt
        return [straight] + stairs + [ladder, uturns]

    def spin_seq(period, start):
        return [[((b,), (False,), (start if (k // period) % 2 == 0 else -start,))]
                for k in range(cnt)]

    progs = []
    for start in (s0, -s0):
        progs.append(sum(spin_seq(1, start), []))   # 지그재그 — 스트림의 본선
        progs.append(sum(spin_seq(2, start), []))   # 2주기 파도
        progs.append([((b,), (False,), (start,))] * cnt)   # 상수 스핀 — 나선 호
    progs.append(sum(spin_seq(3, s0), []))          # 3주기 — 넓은 파도
    return progs


def _apply_program(state, program, side):
    """상태에 프로그램(홉들의 열)을 적용해 (비용증분, 새 상태 필드들)을 계산."""
    (sc, ang, x, y, spin, ch, grid, prev) = state
    pen = 0.0
    a, xx, yy, g, pv, sp = ang, x, y, grid, prev, spin
    for (subs, gflags, seq) in program:
        for si, sb in enumerate(subs):
            if seq[si] != sp:
                pen += COST_TWIRL
                sp = seq[si]
            if gflags[si]:
                pen += COST_GHOST
            a = norm(a + 180.0 + sp * sb * 180.0)
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
    hops_out, twirls, ghosts = [], [], []
    ang = [norm(start_deg)]
    spin, tile = 1, 0
    old_to_new = {0: 0, 1: 1}   # 타일 0(출발)과 1(첫 온셋)은 항상 그대로다
    old_tile = 1
    for (subs, gflags, seq) in choices:
        for si, sb in enumerate(subs):
            if seq[si] != spin:
                twirls.append(tile + 1)   # 이 홉의 축 타일
                spin = seq[si]
            ang.append(norm(ang[-1] + 180.0 + spin * sb * 180.0))
            hops_out.append(sb)
            tile += 1
            if gflags[si]:
                ghosts.append(tile + 1)   # 이 서브홉이 도달하는 타일이 고스트
        old_tile += 1
        old_to_new[old_tile] = tile + 1   # 원본 홉이 끝나는 타일 = 실제(밟는) 타일
    ang.append(ang[-1])
    return hops_out, twirls, ghosts, ang, old_to_new


TURN_EPS_DEG = 1.0  # ChartRuntime.TURN_EPS_DEG 와 같아야 한다


def beats_for_tile_spin(prev, cur, spin):
    d = (cur - (prev + 180.0)) if spin >= 0 else ((prev + 180.0) - cur)
    s = norm(d)
    # U턴은 sweep 0 = 360 이고 그 값이 정확히 wrap 경계에 얹혀 있다.
    # 여유 없이 한쪽만 보면 float 오차 0.001도에 0박/2박이 뒤집힌다
    # (ChartRuntime.beats_for_tile 의 주석 참조 — 실측 6.5초 어긋남).
    if s < TURN_EPS_DEG or s > 360.0 - TURN_EPS_DEG:
        s = 360.0
    return s / 180.0


def hops_of(ang, twirls=()):
    """ChartRuntime.beats_to_reach 와 같은 계산. 반환 길이 = len(ang)-1."""
    out = []
    for i in range(1, len(ang)):
        inc = ang[i - 2] if i >= 2 else ang[0]
        out.append(beats_for_tile_spin(inc, ang[i - 1], spin_at(twirls, i - 1)))
    return out


def tile_positions(ang, r=RADIUS):
    """ChartRuntime.tile_positions 와 같은 계산 (y 반전 포함)."""
    p = [(0.0, 0.0)]
    for i in range(1, len(ang)):
        a = math.radians(ang[i - 1])
        p.append((p[-1][0] + math.cos(a) * r, p[-1][1] - math.sin(a) * r))
    return p


def verify(ang, hops_wanted, twirls=()):
    """런타임과 같은 계산으로 (1) 의도한 리듬이 나오는지 (2) 착지가 맞는지 확인.

    (2)가 이 파일에 있는 이유: 공전 끝점이 다음 타일 좌표와 어긋나는 버그가 있었다.
    직선 구간에선 오차 0 이라 안 보이고, 90도 턴에서 135px, U턴에서 192px 벗어났다.
    생성 단계에서 같이 잰다.
    """
    hops = hops_of(ang, twirls)
    want = [1.0] + list(hops_wanted)
    assert len(hops) == len(want), f"홉 개수 {len(hops)} != {len(want)}"
    for i, (g, w) in enumerate(zip(hops, want)):
        assert abs(g - w) < 1e-6, f"타일 {i+1} 홉: want {w}, got {g}"

    pos = tile_positions(ang)
    worst = 0.0
    for i in range(1, len(ang)):
        inc = ang[i - 2] if i >= 2 else ang[0]
        sp = spin_at(twirls, i - 1)
        sw = beats_for_tile_spin(inc, ang[i - 1], sp) * 180.0 * (1 if sp >= 0 else -1)
        end = math.radians(norm(inc + 180.0) + sw)
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
               loop_guard_deg=None):
    """손으로 쓴 홉 리스트 -> .tres. 테스트/데모 채보 전용 (계획 없음)."""
    if start_offset_ms is None:
        start_offset_ms = LEAD_IN_BEATS * 60000.0 / bpm
    ang, twirls = angles_from_hops(hops_wanted, loop_guard_deg=loop_guard_deg)
    hops, worst = verify(ang, hops_wanted, twirls)
    _emit_tres(name, title, bpm, ang, hops, twirls, [],
               start_offset_ms, speed_changes, worst)
    return ang


def _emit_tres(name, title, bpm, ang, hops, twirls, ghosts,
               start_offset_ms, speed_changes, worst, display_tiles=None):
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
        if twirls:
            f.write("twirl_tiles = PackedInt32Array(%s)\n"
                    % ", ".join(str(t) for t in twirls))
        if ghosts:
            f.write("ghost_tiles = PackedInt32Array(%s)\n"
                    % ", ".join(str(t) for t in ghosts))
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
        f.write('title = "%s"\n' % title)
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
    gaps = [round((onsets[i] - onsets[i - 1]) * 12.0) / 12.0
            for i in range(1, len(onsets))]
    hops, twirls, ghosts, ang, old_to_new = plan_path(gaps)
    _, worst = verify(ang, hops, twirls)

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
        _emit_tres(name, title, bpm, ang, hops, twirls, ghosts,
                   so_ms, speed_changes, worst, display_tiles)
    finally:
        AUDIO = prev_audio
    print("%-20s 첫 온셋 %g박 -> 타일0 @ %.3fs · 심판 타일 %d · 겹침 %d쌍"
          % ("", onsets[0], so_ms / 1000.0, len(want), overlap_pairs(ang)))
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
