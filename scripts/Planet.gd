class_name Planet
extends Node2D

## M1 은 스프라이트 애셋을 쓰지 않는다. "못생긴 도형 + 완벽한 지연"으로 시작한다.
## 그림은 마지막이다 — 예쁜 타일을 먼저 만들면 손맛이 나쁠 때
## 원인이 코드인지 눈속임인지 구분이 안 된다.

@export var radius: float = 18.0
@export var color: Color = Color(0.95, 0.4, 0.35)


func _draw() -> void:
	draw_circle(Vector2.ZERO, radius, color)
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 32, color.lightened(0.4), 2.0, true)
