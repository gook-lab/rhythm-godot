class_name SpeedMarkers
extends Node2D

## 타일 위의 마커 두 종류.
##   삼각형  = 속도 변경(얼불춤의 토끼/달팽이). 위=빨라짐, 아래=느려짐.
##   소용돌이 = twirl(회전 방향 반전).
##
## twirl 마커가 중요한 이유: 회전이 뒤집히면 같은 박자가 반대로 꺾인다.
## 표시가 없으면 플레이어는 왜 길이 반대로 도는지 알 수 없다.
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
	_draw_twirls()
	_draw_speed()


## 소용돌이. 회전이 뒤집히는 지점이라 방향을 알아볼 수 있어야 한다.
func _draw_twirls() -> void:
	for k in range(_chart.twirl_tiles.size()):
		var i := _chart.twirl_tiles[k]
		if i < 0 or i >= _positions.size():
			continue
		var c: Vector2 = _positions[i]
		# 이 타일부터의 회전 방향으로 감기는 나선
		var spin := ChartRuntime.spin_at(_chart, i)
		var pts := PackedVector2Array()
		var turns := 1.6
		var steps := 26
		for n in range(steps + 1):
			var f := float(n) / steps
			var a := f * TAU * turns * (1.0 if spin >= 0 else -1.0)
			var r := 6.0 + 16.0 * f
			pts.append(c + Vector2(cos(a), -sin(a)) * r)
		draw_polyline(pts, Color(0.85, 0.55, 1.0, 0.9), 2.5, true)


func _draw_speed() -> void:
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
