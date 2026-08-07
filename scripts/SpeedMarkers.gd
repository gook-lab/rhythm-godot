class_name SpeedMarkers
extends Node2D

## 토끼/달팽이 타일 표시 (얼불춤의 SetSpeed 타일).
## 위로 향한 삼각형 = 빨라짐(토끼), 아래로 = 느려짐(달팽이).
##
## 스프라이트를 쓰지 않는 이유는 나머지와 같다 — M1 은 도형으로 간다.
## 배속 숫자를 같이 찍는 게 아이콘보다 정보가 많다.

var _chart: Chart
var _positions: PackedVector2Array


func setup(chart: Chart, positions: PackedVector2Array) -> void:
	_chart = chart
	_positions = positions
	queue_redraw()


func _draw() -> void:
	if _chart == null:
		return
	var font := ThemeDB.fallback_font
	for k in range(_chart.speed_changes.size()):
		var sc := _chart.speed_changes[k]
		var i := int(sc.x)
		var m := sc.y
		if i < 0 or i >= _positions.size() or m <= 0.0:
			continue
		# 직전 배율과 비교해야 '빨라짐/느려짐'을 안다. 절대 배율만으론 모른다.
		var prev := 1.0 if k == 0 else _chart.speed_changes[k - 1].y
		if is_equal_approx(m, prev):
			continue
		var up := m > prev
		var p: Vector2 = _positions[i] + Vector2(0, -46)
		var col := Color(1.0, 0.85, 0.3) if up else Color(0.5, 0.8, 1.0)
		var s := 13.0
		var tri := PackedVector2Array([
			p + (Vector2(0, -s) if up else Vector2(0, s)),
			p + Vector2(-s * 0.9, s * 0.6 if up else -s * 0.6),
			p + Vector2(s * 0.9, s * 0.6 if up else -s * 0.6),
		])
		draw_colored_polygon(tri, col)
		draw_string(font, p + Vector2(-16, 30), "x%g" % m,
			HORIZONTAL_ALIGNMENT_CENTER, 32, 13, col)
