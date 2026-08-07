class_name PlanetPair
extends Node2D

## 두 행성. 하나는 축(pivot)으로 멈춰 있고 다른 하나가 그 주위를 돈다.
## 타일을 밟을 때마다 역할이 바뀐다.
##
## !! Tween 을 쓰지 않는다.
##    Tween 은 프레임 루프가 굴리는 벽시계 애니메이션이라 오디오 클럭과 별개의
##    두 번째 시간축이 된다. 그러면 전제 1(하나의 진실 소스에서 렌더와 타이밍이
##    동시에 파생)이 깨지고, 가장 흔한 증상은 크래시가 아니라
##    "행성은 아직 도착 안 했는데 판정은 Perfect" — 눈과 손이 불일치하는,
##    진단이 가장 어려운 종류다.
##    대신 set_orbit_progress(u) 를 매 프레임 오디오 클럭에서 파생시킨다.
##
## 트레일은 '기록'이지 '구동'이 아니다. 매 프레임 위치를 남기기만 하고
## 아무것도 움직이지 않으므로 두 번째 시간축을 만들지 않는다.

const TRAIL_LEN := 22

@onready var _a: Node2D = $PlanetA
@onready var _b: Node2D = $PlanetB

var _pivot_pos := Vector2.ZERO
var _start_deg := 0.0
var _sweep_deg := 180.0
var _radius := 96.0
## true 면 A 가 축이고 B 가 돈다. 타일마다 뒤집힌다.
var _a_is_pivot := true

var _trail_a: Array[Vector2] = []
var _trail_b: Array[Vector2] = []
var _color_a := Color(1.0, 0.45, 0.35)
var _color_b := Color(0.4, 0.9, 1.0)


func _ready() -> void:
	# 트레일은 행성 뒤에 깔려야 한다. PlanetPair 자신이 그리고 자식이 위에 그려진다.
	if _a is Planet:
		_color_a = (_a as Planet).color
	if _b is Planet:
		_color_b = (_b as Planet).color


func configure(pivot_pos: Vector2, start_deg: float, sweep_deg: float, radius: float) -> void:
	_pivot_pos = pivot_pos
	_start_deg = start_deg
	_sweep_deg = sweep_deg
	_radius = radius


func swap_roles() -> void:
	_a_is_pivot = not _a_is_pivot


func clear_trails() -> void:
	_trail_a.clear()
	_trail_b.clear()
	queue_redraw()


## u = 0.0 (공전 시작) ~ 1.0 (다음 타일 도착)
func set_orbit_progress(u: float) -> void:
	var t := clampf(u, 0.0, 1.0)
	var ang := deg_to_rad(_start_deg + _sweep_deg * t)
	var orbiting := _pivot_pos + Vector2(cos(ang), -sin(ang)) * _radius
	if _a_is_pivot:
		_a.position = _pivot_pos
		_b.position = orbiting
	else:
		_b.position = _pivot_pos
		_a.position = orbiting
	_push_trail(_trail_a, _a.position)
	_push_trail(_trail_b, _b.position)
	queue_redraw()


func _push_trail(buf: Array[Vector2], p: Vector2) -> void:
	# 축은 안 움직이므로 같은 자리가 쌓인다. 의미 없는 점은 안 넣는다.
	if not buf.is_empty() and buf[buf.size() - 1].distance_squared_to(p) < 1.0:
		return
	buf.append(p)
	if buf.size() > TRAIL_LEN:
		buf.remove_at(0)


func _draw() -> void:
	_draw_trail(_trail_a, _color_a)
	_draw_trail(_trail_b, _color_b)


func _draw_trail(buf: Array[Vector2], base: Color) -> void:
	var n := buf.size()
	if n < 2:
		return
	# 오래된 쪽이 얇고 투명하다. 선분마다 굵기가 달라야 해서 draw_polyline 대신
	# 개별 선분으로 그린다(폴리라인은 굵기가 하나뿐이다).
	for i in range(1, n):
		var k := float(i) / float(n - 1)   # 0=가장 오래됨, 1=현재
		var c := Color(base.r, base.g, base.b, 0.55 * k * k)
		draw_line(buf[i - 1], buf[i], c, 2.0 + 12.0 * k, true)


## 즉발 피드백. 2프레임 뒤에 원복한다 — 200ms 토스트면 이미 늦다.
## Tween 을 안 쓰는 이유는 여기서도 같다: 시간축을 늘리지 않는다.
func flash(color: Color) -> void:
	var n: Node2D = _b if _a_is_pivot else _a
	n.modulate = color
	await get_tree().process_frame
	await get_tree().process_frame
	n.modulate = Color.WHITE


## 두 행성의 중점. 카메라가 이걸 따라간다.
##
## 왜 타일 lerp 가 아니라 중점인가:
##   타일 lerp 는 행성이 실제로 그리는 호가 아니라 직선을 따라가고,
##   타일이 바뀔 때마다 진행 방향이 불연속으로 꺾인다(U턴에선 아예 뒤로 간다).
##   실측 결과 프레임당 이동량이 중앙값의 13.8배까지 튀었다.
##
##   중점은 역할 교체 순간에 '정확히' 연속이다:
##     교체 직전  pivot=P[i-1], 도는 쪽이 P[i] 에 도착 -> 중점 = (P[i-1]+P[i])/2
##     교체 직후  pivot=P[i],   도는 쪽이 P[i-1]       -> 중점 = (P[i]+P[i-1])/2
##   같은 점이다. 위치 점프가 원천적으로 없어진다.
##   (속도는 첨점이 생기지만 위치 점프보다 훨씬 덜 보이고, 카메라 스무딩이 먹는다.)
func midpoint() -> Vector2:
	return (_a.position + _b.position) * 0.5
