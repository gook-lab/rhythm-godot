class_name TilePath
extends Node2D

## 경로를 '낱개 타일'로 그린다. Line2D 연속 획을 대체한다.
##
## 왜 연속선이 아니라 타일인가:
##   연속선은 다음에 어디서 밟는지를 눈으로 셀 수 없다. 타일이 나뉘어 있으면
##   남은 개수가 그대로 남은 박자 수라서 타이밍을 눈으로 준비할 수 있다.
##   원작이 타일로 그리는 이유가 장식이 아니라 이것이다.
##
## 각 타일은 한 변이 간격과 같은 정사각형이고, 그 타일에서 나갈 방향으로 회전한다.
## 직선 구간에서는 중심 간격 == 한 변이라 타일끼리 정확히 맞닿는다.
## 꺾이는 데선 안쪽이 겹치고 바깥이 벌어지는데, 원작도 같은 모양이다.
##
## 상태별로 다르게 칠한다 — 이게 있어야 '지금 밟아야 할 타일'이 눈에 들어온다:
##   지나간 타일 / 지금 목표 / 앞으로 올 타일

## 타일은 '채우기'가 아니라 '윤곽선'으로 읽힌다.
## 원작 스크린샷을 보면 안은 거의 비어 있고 테두리만 밝게 빛난다.
## 채우기를 불투명하게 하면 경로가 벽처럼 보여서 그 느낌이 안 난다.
##
## 색 성분이 1.0 을 넘으면 HDR 이라 WorldEnvironment 의 글로우가 걸린다.
## 테두리만 1.0 을 넘겨서 선이 발광하고 안은 가라앉게 만든다.
## 이전 팔레트(색조·채도)를 그대로 두고 밝기만 낮췄다.
## 채도까지 죽였더니 차분해지긴 했는데 심심해졌다 — 문제는 채도가 아니라 밝기였다.
##
## 기준: 색 성분이 1.0 을 넘으면 WorldEnvironment 글로우가 걸린다.
## 앞으로 올 타일도 살짝 넘겨서 경로가 은은히 빛나되, 목표 타일이 확실히 더 밝게.
const FILL_PASSED := Color(0.30, 0.36, 0.55, 0.09)
const FILL_UPCOMING := Color(0.55, 0.68, 0.95, 0.12)
const FILL_TARGET := Color(0.95, 0.92, 0.60, 0.19)

const EDGE_PASSED := Color(0.30, 0.36, 0.53, 0.5)
const EDGE_UPCOMING := Color(0.86, 1.01, 1.42)     # 1.90 -> 1.42
const EDGE_TARGET := Color(1.65, 1.50, 0.82)       # 2.20 -> 1.65

## 고스트(자동 통과) 타일 — '밟지 않는 길'로 읽혀야 한다.
## 크기를 절반으로 줄이고 채우기 없이 흐린 윤곽만 그린다.
## 글로우(>1.0)를 주지 않는다 — 빛나는 건 전부 '칠 것'이라는 규약을 지킨다.
const EDGE_GHOST := Color(0.50, 0.62, 0.90, 0.38)
const GHOST_SCALE := 0.52

## 중간회전 타일 — 행성이 교대하지 않고 이어서 돈다.
## 표시가 없으면 "왜 갑자기 반대로 도는지" 를 읽을 방법이 없다.
## twirl(소용돌이)과 구분되어야 하므로 색과 모양을 다르게 쓴다:
## twirl 은 보라색 나선, 중간회전은 청록색 '이어짐' 겹고리.
const MID_COLOR := Color(0.45, 1.05, 0.95, 0.9)

## 체크포인트 — 죽으면 여기서 되살아난다. 원작처럼 빛나는 마름모.
## 지나갈 때 '여기까지는 안전하다'가 읽혀야 하므로 눈에 띄어야 한다.
const CHECKPOINT_COLOR := Color(1.30, 1.15, 0.45, 0.95)

## 홀드 — 밟고 나서 N바퀴 도는 동안 키를 누르고 있어야 한다.
## 바퀴 수만큼 동심원을 그린다: 개수가 곧 '얼마나 오래'다.
const HOLD_COLOR := Color(1.20, 0.62, 1.15, 0.95)

var _positions: PackedVector2Array
var _angles: PackedFloat32Array
var _side := 96.0

## 마커(소용돌이·토끼/달팽이)는 타일의 '일부'다.
## 별도 노드로 그리면 타일이 떨어져 나간 뒤에도 마커가 허공에 남는다(실제로 그랬다).
## 타일과 같은 함수에서 그리면 낙하·회전·페이드를 공짜로 따라간다.
var _twirl_set := {}
var _ghost_set := {}
var _mid_set := {}
var _cp_set := {}
var _hold_at := {}     # tile -> 바퀴 수
var _speed_at := {}     # tile -> [배율, 빨라짐 여부]
## ── 가상 렌더링(뷰포트 컬링) ─────────────────────────────────
## 850타일 채보를 커서가 움직일 때마다 전부 다시 그리면(타일당 둥근 폴리곤
## 20점 + 마커) 촘촘한 구간에서 히치가 난다 — 실측 fps 28까지.
## 화면 근처 타일만 그린다. 카메라가 따라오는 게임이라 보이는 건 늘 커서
## 주변 30~60개다. 목록 가상화(react virtual list)와 같은 발상이다.
var _view := Vector2.INF     # 카메라 중심. INF 면 컬링 없음(전체 그리기)
var _view_r2 := INF
var _drawn_view := Vector2.INF

var _cursor := 1        # 지금 밟아야 할 타일
var _last_cursor := -1

## 타일 임팩트. tile -> [남은 세기 0~1, 색]
## 순수 연출이라 오디오 클럭이 아니라 프레임 시간으로 감쇠시킨다(화면 흔들림과 같은 취급).
const IMPACT_SEC := 0.22
const IMPACT_SCALE := 0.34      # 최대로 커지는 비율
var _impacts := {}

## 지나간 타일이 떨어져 나간다 (원작의 trackDisappearAnimation).
## tile -> [경과초, 초기속도, 각속도(도/초)]
## 난수는 시작할 때 한 번만 뽑아 저장한다 — 매 프레임 뽑으면 타일이 부들거린다.
const FALL_SEC := 1.15
const FALL_GRAVITY := 420.0
var _falls := {}
var _rng := RandomNumberGenerator.new()


func setup(positions: PackedVector2Array, angles: PackedFloat32Array, side: float,
		chart: Chart = null) -> void:
	_positions = positions
	_angles = angles
	_side = side
	_last_cursor = -1
	_twirl_set.clear()
	_ghost_set.clear()
	_mid_set.clear()
	_cp_set.clear()
	_hold_at.clear()
	_speed_at.clear()
	if chart != null:
		for t in chart.twirl_tiles:
			_twirl_set[int(t)] = ChartRuntime.spin_at(chart, int(t))
		for g in chart.ghost_tiles:
			_ghost_set[int(g)] = true
		for m in chart.midspin_tiles:
			_mid_set[int(m)] = true
		for c in chart.checkpoint_tiles:
			_cp_set[int(c)] = true
		for k in range(chart.hold_tiles.size()):
			var h := chart.hold_tiles[k]
			if h.y > 0.0:
				_hold_at[int(h.x)] = h.y
		# speed_display 가 있으면 그 타일만 마커를 받는다 — 원곡 오디오 채보의
		# 홉 단위 보정 배율(잡음)은 배속으로는 살아 있되 눈에는 안 보인다.
		var show := {}
		for t in chart.speed_display:
			if int(t) >= 0:
				show[int(t)] = true
		var filter := chart.speed_display.size() > 0
		for k in range(chart.speed_changes.size()):
			var sc := chart.speed_changes[k]
			var prev := 1.0 if k == 0 else chart.speed_changes[k - 1].y
			if filter and not show.has(int(sc.x)):
				continue
			if sc.y > 0.0 and not is_equal_approx(sc.y, prev):
				_speed_at[int(sc.x)] = [sc.y, sc.y > prev]
	queue_redraw()


## 카메라 중심을 알려준다. 매 프레임 불러도 싸다 — 반지름의 1/4 이상
## 움직였을 때만 다시 그린다(그 안쪽은 여유 마진이 덮는다).
func set_view(center: Vector2, radius: float) -> void:
	_view = center
	_view_r2 = radius * radius
	if _drawn_view == Vector2.INF \
			or _drawn_view.distance_squared_to(center) > _view_r2 * 0.0625:
		queue_redraw()


func _visible(i: int) -> bool:
	return _view == Vector2.INF \
		or _positions[i].distance_squared_to(_view) <= _view_r2


## 매 프레임 부르되, 값이 바뀔 때만 다시 그린다.
## 174개 타일을 60fps 로 재구성할 이유가 없다.
func set_cursor(i: int) -> void:
	if i == _last_cursor:
		return
	# 새로 지나간 타일들을 떨어뜨린다. 한 프레임에 여러 칸 전진할 수도 있다.
	if _last_cursor >= 0:
		for t in range(_last_cursor, mini(i, _positions.size())):
			_start_fall(t)
	_last_cursor = i
	_cursor = i
	set_process(true)
	queue_redraw()


func _start_fall(tile: int) -> void:
	if tile < 0 or tile >= _positions.size() or _falls.has(tile):
		return
	_falls[tile] = [
		0.0,
		Vector2(_rng.randf_range(-42.0, 42.0), _rng.randf_range(-120.0, -40.0)),
		_rng.randf_range(-160.0, 160.0),
	]


## 타일을 밟았을 때. 판정 색으로 잠깐 부풀었다 가라앉는다.
func impact(tile: int, col: Color) -> void:
	if tile < 0 or tile >= _positions.size():
		return
	_impacts[tile] = [1.0, col]
	set_process(true)
	queue_redraw()


func clear_impacts() -> void:
	_impacts.clear()
	_falls.clear()
	_last_cursor = -1
	queue_redraw()


func _process(delta: float) -> void:
	if _impacts.is_empty() and _falls.is_empty():
		set_process(false)
		return
	var done: Array = []
	for t in _impacts:
		var e: Array = _impacts[t]
		e[0] -= delta / IMPACT_SEC
		if e[0] <= 0.0:
			done.append(t)
	for t in done:
		_impacts.erase(t)

	done = []
	for t in _falls:
		var f: Array = _falls[t]
		f[0] += delta
		if f[0] >= FALL_SEC:
			done.append(t)
	for t in done:
		_falls.erase(t)   # 다 떨어진 타일은 더 이상 그리지 않는다

	queue_redraw()


## 각도 -> 진행 방향 단위벡터.
## 화면은 아래가 +y 라 각도의 y 를 뒤집는다(ChartRuntime.tile_positions 와 같은 규약).
func _dir(deg: float) -> Vector2:
	var a := deg_to_rad(deg)
	return Vector2(cos(a), -sin(a))



## 미터(팔꿈치) 길이 상한. 꺾임이 급할수록 팔꿈치 점이 밖으로 뻗는데
## (미터 공식의 분모가 0 으로), 상한 없이 두면 165도 꺾임에서 7.7배 스파이크가
## 된다. 잘라내면 살짝 깎인 팔꿈치(bevel)가 되고 둥글림이 마저 다듬는다.
const MITER_MAX := 1.6


func _shape_local(i: int, half: float) -> PackedVector2Array:
	# 타일은 낱장 카드가 아니라 '트랙의 한 구간'이다.
	#
	# 세 번째 시도다. ① 두 방향 쐐기: 변은 맞물리는데 넓이가 요동치고
	# 자기교차(나비넥타이)가 났다. ② 고정 사각형 + 이등분선 회전: 안정적이지만
	# 꺾이는 자리마다 이웃끼리 대각선으로 겹쳐 '카드 무더기'로 보였다 —
	# 원작 스크린샷과 나란히 놓고 보면 원작은 타일들이 이음매에서 만나
	# 하나의 띠로 이어진다.
	#
	# 그래서 원작의 실제 구조로 간다: 타일 i 는
	#   앞 이음매(이전 타일과의 중간, 들어온 방향에 수직)에서 출발해
	#   중심에서 꺾이고
	#   뒤 이음매(다음 타일과의 중간, 나갈 방향에 수직)에서 끝나는
	# 폭 일정한 '굽은 도미노'다. 직선 구간은 정확히 맞닿는 직사각형이 되고
	# (이음매 = 두 중심의 중점이므로), 꺾이는 자리는 팔꿈치가 된다.
	# 폭도 길이도 상수라 ①의 불안정이 없고, 이음매가 맞물리니 ②의 겹침이 없다.
	#
	# 팔꿈치 점은 폴리라인 미터 조인 공식 그대로다:
	#   M = ±(v_in + v_out) * half / (1 + u_in·u_out)
	# 직선이면 ±v*half 로 퇴화해 직사각형과 일치한다(검산).
	var n := _angles.size()
	var out_deg: float = _angles[i] if i < n else _angles[n - 1]
	var in_deg: float = _angles[i - 1] if i >= 1 else out_deg
	var uin := _dir(in_deg)
	var uout := _dir(out_deg)
	var d := uin.dot(uout)
	# U턴은 이음매가 겹쳐 트랙 폭이 0 이 된다. 경로가 되돌아가는 자리라
	# 그게 맞지만 안 보이면 안 되므로 들어온 방향의 직사각형으로 둔다.
	if d < -0.95:
		uout = uin
		d = 1.0
	var vin := Vector2(-uin.y, uin.x) * half
	var vout := Vector2(-uout.y, uout.x) * half
	var e1 := -uin * half - vin    # 앞 이음매
	var e2 := -uin * half + vin
	var x1 := uout * half - vout   # 뒤 이음매
	var x2 := uout * half + vout
	if d > 0.999:                  # 직선 — 그냥 직사각형
		return PackedVector2Array([e1, x1, x2, e2])
	var m := (vin + vout) / (1.0 + d)
	if m.length() > MITER_MAX * half:
		m = m.normalized() * MITER_MAX * half
	return PackedVector2Array([e1, -m, x1, x2, m, e2])


## 모서리를 둥글린다.
##
## 원작 타일은 각진 사각형이 아니라 **모서리가 둥근 캡슐**이다. 이게 왜 중요하냐면,
## 둥근 끝이 이웃과의 각도 차이를 흡수해서 어떤 각으로 꺾여도 이음매가 매끄럽다 —
## 각진 쐐기는 90도에서 완전한 삼각형이 되어 뾰족하게 튄다.
## 경로 끝처럼 이웃이 없는 자리에서는 반원 마감이 그대로 보인다(원작과 같다).
##
## 반지름은 '이 모서리에 붙은 두 변 중 짧은 쪽의 절반'으로 자른다.
## 안 그러면 90도 코너처럼 한 변이 0 인 자리에서 도형이 뒤집힌다.
## 0.5 는 낱장 카드 시절 값이다. 트랙(이음매 맞물림)에서는 모서리를 덜 깎아야
## 이음매의 틈이 작아진다 — 0.4 가 원작 스크린샷과 가장 비슷했다.
const ROUND_RATIO := 0.4     # half 대비 모서리 반지름
const ROUND_SEG := 4         # 모서리당 보간 점 수. 4 면 60fps 에 부담 없고 충분히 둥글다


func _round_poly(pts: PackedVector2Array, r: float) -> PackedVector2Array:
	# 겹친 점을 먼저 지운다 — 90도 코너는 두 꼭짓점이 한 점으로 모여서
	# 그대로 두면 길이 0 인 변이 생기고 굽힘 계산이 터진다.
	var q := PackedVector2Array()
	for pt in pts:
		if q.is_empty() or q[q.size() - 1].distance_squared_to(pt) > 0.01:
			q.append(pt)
	while q.size() > 1 and q[0].distance_squared_to(q[q.size() - 1]) < 0.01:
		q.remove_at(q.size() - 1)
	if q.size() < 3:
		return pts

	var out := PackedVector2Array()
	var n := q.size()
	for i in range(n):
		var cur: Vector2 = q[i]
		var d1: Vector2 = q[(i - 1 + n) % n] - cur
		var d2: Vector2 = q[(i + 1) % n] - cur
		var l1 := d1.length()
		var l2 := d2.length()
		if l1 < 0.001 or l2 < 0.001:
			out.append(cur)
			continue
		var rr := minf(r, minf(l1, l2) * 0.5)
		var a := cur + d1 / l1 * rr
		var b := cur + d2 / l2 * rr
		# a -> b 를 cur 을 제어점으로 하는 2차 베지에로 잇는다.
		# 원호와 육안으로 구분되지 않으면서 계산이 훨씬 싸다.
		out.append(a)
		for k in range(1, ROUND_SEG):
			var t := float(k) / ROUND_SEG
			out.append(a.lerp(cur, t).lerp(cur.lerp(b, t), t))
		out.append(b)
	return out


## 로컬 모양을 회전·확대해 월드로 옮긴다. 낙하·임팩트가 같은 모양을 쓰게 하는 통로다.
func _quad_of(i: int, center: Vector2, half: float, rot_deg := 0.0,
		scale := 1.0) -> PackedVector2Array:
	var pts := _round_poly(_shape_local(i, half), half * ROUND_RATIO)
	var rot := deg_to_rad(-rot_deg)   # 각도는 CCW 양수, 화면은 y 반전이라 부호가 뒤집힌다
	var out := PackedVector2Array()
	for pt in pts:
		out.append(center + (pt * scale).rotated(rot))
	return out


func _draw() -> void:
	var n := _positions.size()
	if n == 0:
		return
	var half := _side * 0.5

	# 지나간 타일 -> 앞으로 올 타일 순으로 그려서, 겹치는 부분은 나중 것이 위에 온다.
	# 떨어지는 중인 타일만 그리고, 다 떨어진 것은 아예 안 그린다.
	for t in _falls:
		_draw_falling(t, half)
	# 목표는 '다음에 밟을' 타일이다. 렌더 커서가 고스트 위를 지나는 중이면
	# 고스트가 아니라 그 너머의 판정 타일이 노랗게 빛나야 한다 —
	# 고스트가 목표색이 되면 "이걸 치라"는 뜻이 돼 버린다.
	var target := _cursor
	while target >= 0 and target < n and _ghost_set.has(target):
		target += 1
	_drawn_view = _view
	for i in range(n - 1, _cursor - 1, -1):
		if i == target:
			continue
		if not _visible(i):
			continue
		if _ghost_set.has(i):
			_draw_tile(i, half * GHOST_SCALE, Color.TRANSPARENT, EDGE_GHOST, 1.5)
		elif i > _cursor:
			_draw_tile(i, half, FILL_UPCOMING, EDGE_UPCOMING, 2.0)
	# 목표 타일은 맨 위에, 테두리를 더 굵게
	if _cursor >= 0 and target < n:
		_draw_tile(target, half, FILL_TARGET, EDGE_TARGET, 3.5)

	# 임팩트는 전부 위에. 부풀었다 가라앉는다.
	for t in _impacts:
		var e: Array = _impacts[t]
		var k: float = clampf(e[0], 0.0, 1.0)
		var col: Color = e[1]
		# 커졌다 돌아오는 게 아니라 '커지면서 사라진다' — 잔상처럼 읽힌다.
		var grow := half * (1.0 + IMPACT_SCALE * (1.0 - k))
		var q := _quad_of(t, _positions[t], grow)
		draw_colored_polygon(q, Color(col.r, col.g, col.b, 0.26 * k))
		var outline := q.duplicate()
		outline.append(q[0])
		draw_polyline(outline, Color(col.r * 1.25, col.g * 1.25, col.b * 1.25, k), 3.2, true)
		# 방사 플레어. 원작에서 밟은 자리에 빛이 터지는 그 느낌.
		var flare := half * (0.5 + 1.6 * (1.0 - k))
		draw_circle(_positions[t], flare,
			Color(col.r, col.g, col.b, 0.18 * k * k))


## 지나간 타일이 중력에 떨어지며 회전하고 사라진다.
func _draw_falling(t: int, half: float) -> void:
	if _ghost_set.has(t):
		half *= GHOST_SCALE   # 서 있을 때 작았으니 떨어질 때도 작아야 한다
	var f: Array = _falls[t]
	var e: float = f[0]
	var k: float = clampf(1.0 - e / FALL_SEC, 0.0, 1.0)   # 1 -> 0
	var vel: Vector2 = f[1]
	var pos: Vector2 = _positions[t] + vel * e + Vector2(0, 0.5 * FALL_GRAVITY * e * e)
	var q := _quad_of(t, pos, half * (0.55 + 0.45 * k), f[2] * e)
	draw_colored_polygon(q, Color(FILL_PASSED.r, FILL_PASSED.g, FILL_PASSED.b,
		FILL_PASSED.a * k * 2.2))
	var outline := q.duplicate()
	outline.append(q[0])
	draw_polyline(outline, Color(EDGE_PASSED.r, EDGE_PASSED.g, EDGE_PASSED.b,
		EDGE_PASSED.a * k), 1.5, true)
	_draw_markers(t, pos, f[2] * e, k, 0.55 + 0.45 * k)


func _draw_tile(i: int, half: float, fill: Color, edge: Color, edge_w: float) -> void:
	# angles[i] 는 타일 i 에서 나갈 방향. 마지막 타일은 그 앞을 따른다.
	var q := _quad_of(i, _positions[i], half)
	draw_colored_polygon(q, fill)
	var outline := q.duplicate()
	outline.append(q[0])
	draw_polyline(outline, edge, edge_w, true)
	_draw_markers(i, _positions[i], 0.0, 1.0)


## 타일 위 마커. 낙하 중에도 같은 변환(위치·회전·투명도)으로 따라간다.
## 마커가 들어갈 자리와 크기.
##
## 타일 모양이 종류마다 달라진 뒤(쐐기·마름모·길쭉) 마커를 예전처럼 '타일 좌표에
## 고정 크기'로 그리면 좁은 쐐기에서 도형 밖으로 삐져나가 잘린 것처럼 보인다.
## 실제로 그랬다 — 90도 코너의 삼각형 타일에서 중간회전 겹고리가 밖으로 나갔다.
##
## 두 가지를 도형에서 가져온다:
##   자리 = 면적 가중 무게중심 (쐐기는 타일 좌표가 도형 중심이 아니다)
##   크기 = 그 점에서 변까지의 최단거리(내접원) / 정사각형일 때의 값(half)
##
## 정사각형이면 무게중심 = 원점, 내접반경 = half 라 배율이 정확히 1.0 —
## 즉 예전 채보에서는 한 픽셀도 안 바뀐다.
const MARKER_MIN_SCALE := 0.5   # 이보다 줄이면 무슨 표시인지 못 읽는다


func _marker_fit(tile: int, half: float) -> Array:
	var pts := _shape_local(tile, half)
	var n := pts.size()
	var a2 := 0.0
	var c := Vector2.ZERO
	for k in range(n):
		var p0: Vector2 = pts[k]
		var p1: Vector2 = pts[(k + 1) % n]
		var cr := p0.cross(p1)
		a2 += cr
		c += (p0 + p1) * cr
	if absf(a2) < 0.001:
		return [Vector2.ZERO, MARKER_MIN_SCALE]
	c /= 3.0 * a2
	var inr := INF
	for k in range(n):
		var p0: Vector2 = pts[k]
		var e: Vector2 = pts[(k + 1) % n] - p0
		var l := e.length()
		if l < 0.001:
			continue
		inr = minf(inr, absf(e.cross(c - p0)) / l)
	if not is_finite(inr):
		return [Vector2.ZERO, MARKER_MIN_SCALE]
	return [c, clampf(inr / half, MARKER_MIN_SCALE, 1.0)]


func _draw_markers(tile: int, center: Vector2, rot_deg: float, alpha: float,
		size := 1.0) -> void:
	# 도형 안쪽으로 들어오게 자리와 배율을 먼저 잡는다.
	# 낙하 중이면 도형도 같이 돌아가므로 무게중심도 같이 돌린다.
	var fit := _marker_fit(tile, _side * 0.5)
	var rot := deg_to_rad(-rot_deg)
	# size 는 낙하 중 타일이 줄어드는 비율이다. 마커가 같이 안 줄면
	# 떨어지는 조각보다 표시가 커져 허공에 뜬 것처럼 보인다.
	var m: float = fit[1] * size
	var at: Vector2 = center + ((fit[0] as Vector2) * size).rotated(rot)

	if _twirl_set.has(tile):
		var spin: int = _twirl_set[tile]
		var pts := PackedVector2Array()
		var steps := 26
		var rr := deg_to_rad(rot_deg)
		for n in range(steps + 1):
			var f := float(n) / steps
			var a := f * TAU * 1.6 * (1.0 if spin >= 0 else -1.0) + rr
			var r := (6.0 + 16.0 * f) * m
			pts.append(at + Vector2(cos(a), -sin(a)) * r)
		draw_polyline(pts, Color(0.85, 0.55, 1.0, 0.9 * alpha), 2.5, true)
	if _hold_at.has(tile):
		var orbits: float = _hold_at[tile]
		var col := Color(HOLD_COLOR.r, HOLD_COLOR.g, HOLD_COLOR.b,
			HOLD_COLOR.a * alpha)
		for n in range(int(orbits)):
			draw_arc(at, (13.0 + n * 7.0) * m, 0.0, TAU, 28, col, 2.4, true)
	if _cp_set.has(tile):
		# 마름모 = 정사각형을 45도 돌린 것. 타일과 겹쳐도 형태가 구분된다.
		var r := 15.0 * m
		var rot3 := deg_to_rad(rot_deg)
		var dm := PackedVector2Array()
		for n in range(5):
			dm.append(at + Vector2(0, -r).rotated(rot3 + n * TAU / 4.0))
		draw_polyline(dm, Color(CHECKPOINT_COLOR.r, CHECKPOINT_COLOR.g,
			CHECKPOINT_COLOR.b, CHECKPOINT_COLOR.a * alpha), 2.6, true)
	if _mid_set.has(tile):
		# 겹친 두 고리 = '두 행성이 교대하지 않고 이어진다'.
		# 진행 방향으로 나란히 놓아 어느 쪽으로 이어지는지도 같이 읽힌다.
		var rot2 := deg_to_rad(rot_deg)
		var dir := Vector2(cos(rot2), -sin(rot2))
		for sgn in [-1.0, 1.0]:
			draw_arc(at + dir * (sgn * 7.0 * m), 11.0 * m, 0.0, TAU, 20,
				Color(MID_COLOR.r, MID_COLOR.g, MID_COLOR.b, MID_COLOR.a * alpha),
				2.2, true)
	if _speed_at.has(tile):
		var e: Array = _speed_at[tile]
		var mult: float = e[0]
		var up: bool = e[1]
		var col := Color(1.0, 0.85, 0.3, alpha) if up else Color(0.5, 0.8, 1.0, alpha)
		var p := center + Vector2(0, -46).rotated(-deg_to_rad(rot_deg))
		var sz := 13.0
		var tri := PackedVector2Array([
			p + (Vector2(0, -sz) if up else Vector2(0, sz)),
			p + Vector2(-sz * 0.9, sz * 0.6 if up else -sz * 0.6),
			p + Vector2(sz * 0.9, sz * 0.6 if up else -sz * 0.6),
		])
		draw_colored_polygon(tri, col)
		# GDScript 의 % 포맷엔 %g 가 없다 — 쓰면 매 프레임 포맷 에러가 나면서
		# 텍스트가 아예 안 그려진다(4MB 로그 스팸으로 발견). String.num 이
		# %g 의 의도(뒤 0 제거: 2.0 -> "2", 1.5 -> "1.5")를 대신한다.
		draw_string(ThemeDB.fallback_font, p + Vector2(-16, 30), "x" + String.num(mult),
			HORIZONTAL_ALIGNMENT_CENTER, 32, 13, col)
