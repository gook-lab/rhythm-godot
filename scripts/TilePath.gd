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
const FILL_PASSED := Color(0.30, 0.36, 0.55, 0.10)
const FILL_UPCOMING := Color(0.55, 0.68, 0.95, 0.14)
const FILL_TARGET := Color(0.95, 0.92, 0.60, 0.22)

const EDGE_PASSED := Color(0.35, 0.42, 0.62, 0.55)
const EDGE_UPCOMING := Color(1.15, 1.35, 1.90)     # HDR -> 블룸
const EDGE_TARGET := Color(2.20, 2.00, 1.10)       # 목표는 더 세게

var _positions: PackedVector2Array
var _angles: PackedFloat32Array
var _side := 96.0
var _cursor := 1        # 지금 밟아야 할 타일
var _last_cursor := -1

## 타일 임팩트. tile -> [남은 세기 0~1, 색]
## 순수 연출이라 오디오 클럭이 아니라 프레임 시간으로 감쇠시킨다(화면 흔들림과 같은 취급).
const IMPACT_SEC := 0.22
const IMPACT_SCALE := 0.34      # 최대로 커지는 비율
var _impacts := {}


func setup(positions: PackedVector2Array, angles: PackedFloat32Array, side: float) -> void:
	_positions = positions
	_angles = angles
	_side = side
	_last_cursor = -1
	queue_redraw()


## 매 프레임 부르되, 값이 바뀔 때만 다시 그린다.
## 174개 타일을 60fps 로 재구성할 이유가 없다.
func set_cursor(i: int) -> void:
	if i == _last_cursor:
		return
	_last_cursor = i
	_cursor = i
	queue_redraw()


## 타일을 밟았을 때. 판정 색으로 잠깐 부풀었다 가라앉는다.
func impact(tile: int, col: Color) -> void:
	if tile < 0 or tile >= _positions.size():
		return
	_impacts[tile] = [1.0, col]
	set_process(true)
	queue_redraw()


func clear_impacts() -> void:
	_impacts.clear()
	queue_redraw()


func _process(delta: float) -> void:
	if _impacts.is_empty():
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
	for i in range(n):
		if i < _cursor:
			_draw_tile(i, half, FILL_PASSED, EDGE_PASSED, 1.5)
	for i in range(n - 1, _cursor, -1):
		_draw_tile(i, half, FILL_UPCOMING, EDGE_UPCOMING, 2.0)
	# 목표 타일은 맨 위에, 테두리를 더 굵게
	if _cursor >= 0 and _cursor < n:
		_draw_tile(_cursor, half, FILL_TARGET, EDGE_TARGET, 3.5)

	# 임팩트는 전부 위에. 부풀었다 가라앉는다.
	for t in _impacts:
		var e: Array = _impacts[t]
		var k: float = clampf(e[0], 0.0, 1.0)
		var col: Color = e[1]
		# 커졌다 돌아오는 게 아니라 '커지면서 사라진다' — 잔상처럼 읽힌다.
		var grow := half * (1.0 + IMPACT_SCALE * (1.0 - k))
		var deg := _angles[t] if t < _angles.size() else 0.0
		var q := _quad(_positions[t], deg, grow)
		draw_colored_polygon(q, Color(col.r, col.g, col.b, 0.30 * k))
		var outline := q.duplicate()
		outline.append(q[0])
		draw_polyline(outline, Color(col.r * 1.6, col.g * 1.6, col.b * 1.6, k), 3.5, true)
		# 방사 플레어. 원작에서 밟은 자리에 빛이 터지는 그 느낌.
		var flare := half * (0.5 + 1.6 * (1.0 - k))
		draw_circle(_positions[t], flare,
			Color(col.r, col.g, col.b, 0.22 * k * k))


func _draw_tile(i: int, half: float, fill: Color, edge: Color, edge_w: float) -> void:
	# angles[i] 는 타일 i 에서 나갈 방향. 마지막 타일은 그 앞을 따른다.
	var deg := _angles[i] if i < _angles.size() else _angles[_angles.size() - 1]
	var q := _quad(_positions[i], deg, half)
	draw_colored_polygon(q, fill)
	var outline := q.duplicate()
	outline.append(q[0])
	draw_polyline(outline, edge, edge_w, true)
