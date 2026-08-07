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

var _positions: PackedVector2Array
var _angles: PackedFloat32Array
var _side := 96.0

## 마커(소용돌이·토끼/달팽이)는 타일의 '일부'다.
## 별도 노드로 그리면 타일이 떨어져 나간 뒤에도 마커가 허공에 남는다(실제로 그랬다).
## 타일과 같은 함수에서 그리면 낙하·회전·페이드를 공짜로 따라간다.
var _twirl_set := {}
var _ghost_set := {}
var _speed_at := {}     # tile -> [배율, 빨라짐 여부]
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
	_speed_at.clear()
	if chart != null:
		for t in chart.twirl_tiles:
			_twirl_set[int(t)] = ChartRuntime.spin_at(chart, int(t))
		for g in chart.ghost_tiles:
			_ghost_set[int(g)] = true
		for k in range(chart.speed_changes.size()):
			var sc := chart.speed_changes[k]
			var prev := 1.0 if k == 0 else chart.speed_changes[k - 1].y
			if sc.y > 0.0 and not is_equal_approx(sc.y, prev):
				_speed_at[int(sc.x)] = [sc.y, sc.y > prev]
	queue_redraw()


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


func _quad(center: Vector2, deg: float, half: float) -> PackedVector2Array:
	var a := deg_to_rad(deg)
	# 화면은 아래가 +y 라 각도의 y 를 뒤집는다(ChartRuntime.tile_positions 와 같은 규약).
	var u := Vector2(cos(a), -sin(a)) * half     # 진행 방향
	var v := Vector2(-u.y, u.x)                  # 그 수직
	return PackedVector2Array([
		center - u - v, center + u - v, center + u + v, center - u + v,
	])


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
	for i in range(n - 1, _cursor - 1, -1):
		if i == target:
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
		var deg := _angles[t] if t < _angles.size() else 0.0
		var q := _quad(_positions[t], deg, grow)
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
	var deg: float = (_angles[t] if t < _angles.size() else 0.0) + f[2] * e
	var q := _quad(pos, deg, half * (0.55 + 0.45 * k))
	draw_colored_polygon(q, Color(FILL_PASSED.r, FILL_PASSED.g, FILL_PASSED.b,
		FILL_PASSED.a * k * 2.2))
	var outline := q.duplicate()
	outline.append(q[0])
	draw_polyline(outline, Color(EDGE_PASSED.r, EDGE_PASSED.g, EDGE_PASSED.b,
		EDGE_PASSED.a * k), 1.5, true)
	_draw_markers(t, pos, f[2] * e, k)


func _draw_tile(i: int, half: float, fill: Color, edge: Color, edge_w: float) -> void:
	# angles[i] 는 타일 i 에서 나갈 방향. 마지막 타일은 그 앞을 따른다.
	var deg := _angles[i] if i < _angles.size() else _angles[_angles.size() - 1]
	var q := _quad(_positions[i], deg, half)
	draw_colored_polygon(q, fill)
	var outline := q.duplicate()
	outline.append(q[0])
	draw_polyline(outline, edge, edge_w, true)
	_draw_markers(i, _positions[i], 0.0, 1.0)


## 타일 위 마커. 낙하 중에도 같은 변환(위치·회전·투명도)으로 따라간다.
func _draw_markers(tile: int, center: Vector2, rot_deg: float, alpha: float) -> void:
	if _twirl_set.has(tile):
		var spin: int = _twirl_set[tile]
		var pts := PackedVector2Array()
		var steps := 26
		var rot := deg_to_rad(rot_deg)
		for n in range(steps + 1):
			var f := float(n) / steps
			var a := f * TAU * 1.6 * (1.0 if spin >= 0 else -1.0) + rot
			var r := (6.0 + 16.0 * f)
			pts.append(center + Vector2(cos(a), -sin(a)) * r)
		draw_polyline(pts, Color(0.85, 0.55, 1.0, 0.9 * alpha), 2.5, true)
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
