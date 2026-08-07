class_name TimingBar
extends Control

## 히트 에러 미터. 얼불춤 모드의 TimingScale 바와 같은 물건이다.
##
## 가운데가 정확(delta 0), 왼쪽이 빠름, 오른쪽이 늦음.
## 최근 입력이 눈금으로 찍히고 오래된 것부터 흐려진다.
##
## 연출이면서 동시에 계측 도구다. 눈금이 한쪽으로 쏠려 있으면 오프셋 문제고,
## 가운데를 중심으로 넓게 퍼져 있으면 산포 문제다 —
## 전자는 슬라이더로 고쳐지고 후자는 안 고쳐진다. 그 둘을 눈으로 구분하려고 만든다.

const MAX_TICKS := 40

@export var perfect_color := Color(0.35, 0.95, 0.55)
@export var very_color := Color(0.98, 0.85, 0.35)
@export var edge_color := Color(0.95, 0.35, 0.35)
@export var tick_color := Color(1, 1, 1)

var _half_range_ms: float = 110.0   # 바 양끝이 뜻하는 ms (= miss 창)
var _perfect_ms: float = 30.0
var _very_ms: float = 60.0
var _ticks: Array[float] = []       # 최근 delta 들
var _mean: float = 0.0
var _has_mean := false


## Judge 의 현재 창에 맞춰 바의 축척을 바꾼다.
## 빠른 구간에선 판정창이 좁아지므로 바도 같이 확대돼야 한다 —
## 안 그러면 눈금이 전부 한가운데 뭉쳐서 아무것도 안 보인다.
func set_windows(perfect: float, very: float, miss: float) -> void:
	_perfect_ms = perfect
	_very_ms = very
	_half_range_ms = maxf(miss, 1.0)
	queue_redraw()


func push(delta_ms: float) -> void:
	if not is_finite(delta_ms):
		return
	_ticks.append(delta_ms)
	if _ticks.size() > MAX_TICKS:
		_ticks.remove_at(0)
	var m := 0.0
	for d in _ticks:
		m += d
	_mean = m / _ticks.size()
	_has_mean = true
	queue_redraw()


func clear() -> void:
	_ticks.clear()
	_has_mean = false
	queue_redraw()


func _ms_to_x(ms: float) -> float:
	var half := size.x * 0.5
	return half + clampf(ms / _half_range_ms, -1.0, 1.0) * half


func _draw() -> void:
	var w := size.x
	var h := size.y
	var bar_h := h * 0.45
	var y := (h - bar_h) * 0.5

	# 판정 구간을 색으로. 바깥이 빨강, 가운데가 초록.
	draw_rect(Rect2(0, y, w, bar_h), edge_color.darkened(0.35))
	var vx0 := _ms_to_x(-_very_ms)
	var vx1 := _ms_to_x(_very_ms)
	draw_rect(Rect2(vx0, y, vx1 - vx0, bar_h), very_color.darkened(0.3))
	var px0 := _ms_to_x(-_perfect_ms)
	var px1 := _ms_to_x(_perfect_ms)
	draw_rect(Rect2(px0, y, px1 - px0, bar_h), perfect_color.darkened(0.15))

	# 정중앙 기준선
	draw_line(Vector2(w * 0.5, y - 3), Vector2(w * 0.5, y + bar_h + 3),
		Color(1, 1, 1, 0.85), 2.0)

	# 최근 입력 눈금. 오래된 것부터 흐려진다.
	var n := _ticks.size()
	for i in range(n):
		var a := float(i + 1) / float(n)          # 최신일수록 1 에 가깝다
		var x := _ms_to_x(_ticks[i])
		draw_line(Vector2(x, y - 2), Vector2(x, y + bar_h + 2),
			Color(tick_color.r, tick_color.g, tick_color.b, 0.15 + 0.75 * a), 2.0)

	# 평균 마커 — 여기가 0 에서 벗어나 있으면 오프셋으로 고칠 수 있다는 신호
	if _has_mean:
		var mx := _ms_to_x(_mean)
		var tri := PackedVector2Array([
			Vector2(mx, y + bar_h + 2),
			Vector2(mx - 5, y + bar_h + 11),
			Vector2(mx + 5, y + bar_h + 11),
		])
		draw_colored_polygon(tri, Color(0.55, 0.8, 1.0))
