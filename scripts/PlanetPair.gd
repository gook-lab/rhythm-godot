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
##    프레임 드롭이 나도 다음 프레임에 올바른 위치로 자동 복구된다.

@onready var _a: Node2D = $PlanetA
@onready var _b: Node2D = $PlanetB

var _pivot_pos := Vector2.ZERO
var _start_deg := 0.0
var _sweep_deg := 180.0
var _radius := 96.0
## true 면 A 가 축이고 B 가 돈다. 타일마다 뒤집힌다.
var _a_is_pivot := true


func configure(pivot_pos: Vector2, start_deg: float, sweep_deg: float, radius: float) -> void:
	_pivot_pos = pivot_pos
	_start_deg = start_deg
	_sweep_deg = sweep_deg
	_radius = radius


func swap_roles() -> void:
	_a_is_pivot = not _a_is_pivot


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


## 즉발 피드백. 2프레임 뒤에 원복한다 — 200ms 토스트면 이미 늦다.
## Tween 을 안 쓰는 이유는 여기서도 같다: 시간축을 늘리지 않는다.
func flash(color: Color) -> void:
	var n: Node2D = _b if _a_is_pivot else _a
	n.modulate = color
	await get_tree().process_frame
	await get_tree().process_frame
	n.modulate = Color.WHITE
