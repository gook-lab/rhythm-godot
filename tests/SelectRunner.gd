extends Node

## 곡 선택 화면 검증.
##   godot --headless res://tests/SelectScene.tscn
##
## change_scene 은 current_scene(이 러너)을 갈아치우므로 suppress_scene_change
## 시임으로 억제하고, 스캔·탐색·선택 로직만 본다.

var _fails := 0


func ok(c: bool, w: String) -> void:
	print("  %s %s" % ["ok  " if c else "FAIL", w])
	if not c:
		_fails += 1


func key(code: int) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = code
	e.pressed = true
	return e


func _ready() -> void:
	var sel: Control = load("res://scenes/SongSelect.tscn").instantiate()
	sel.suppress_scene_change = true
	add_child(sel)
	await get_tree().process_frame

	var entries: Array = sel.get("_entries")
	print("차트 %d개 스캔" % entries.size())
	ok(entries.size() >= 8, "차트 8개 이상 (t01~t05·demo·song140·test_song)")
	for e in entries:
		ok(e.bpm > 0 and e.tiles > 0 and e.secs > 0.0,
			"%s — bpm %.0f · 타일 %d · %.1fs" % [e.title, e.bpm, e.tiles, e.secs])
	var has_speed := false
	for e in entries:
		if e.speed:
			has_speed = true
	ok(has_speed, "속도 타일 곡 표시(🐇) 존재")

	# 탐색: ↓↓↑ = 인덱스 1
	sel._input(key(KEY_DOWN))
	sel._input(key(KEY_DOWN))
	sel._input(key(KEY_UP))
	ok(int(sel.get("_sel")) == 1, "↓↓↑ -> 인덱스 1")
	# 위 경계
	for i in range(20):
		sel._input(key(KEY_UP))
	ok(int(sel.get("_sel")) == 0, "위 경계 고정")
	# 아래 경계
	for i in range(99):
		sel._input(key(KEY_DOWN))
	ok(int(sel.get("_sel")) == entries.size() - 1, "아래 경계 고정")

	sel._input(key(KEY_ENTER))
	ok(GameState.selected_chart == entries[entries.size() - 1].path,
		"Enter -> GameState 에 선택 저장 (%s)" % GameState.selected_chart)

	print("PASS" if _fails == 0 else "FAILED %d" % _fails)
	get_tree().quit(_fails)
