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

	# 입력 효과음 토글(M). 실제 음악에서는 타일이 멜로디 온셋 위라 효과음이
	# 겹쳐 들리는데, 채움 타일에는 멜로디가 없어서 끄면 무음이 된다 —
	# 그래서 끄고 켤 수 있어야 하고, 그 상태가 화면에 보여야 한다.
	var was: bool = Records.sfx_enabled
	sel._input(key(KEY_M))
	ok(Records.sfx_enabled != was, "M -> 입력음 토글")
	ok(sel.get("_info").text.contains("입력음"), "선택 화면에 입력음 상태 표시")
	sel._input(key(KEY_M))
	ok(Records.sfx_enabled == was, "M 두 번 -> 원래대로")

	# 목록이 화면을 넘지 않아야 한다. 넘으면 아래 곡들이 안 보이는데,
	# ↑↓ 로 선택은 되니까 '고를 수는 있지만 볼 수는 없는' 상태가 된다 —
	# 곡이 늘어야 드러나는 종류라 채보 수와 함께 자동으로 지키게 둔다.
	await get_tree().process_frame
	await get_tree().process_frame
	var vp := sel.get_viewport().get_visible_rect().size.y
	var vbox: Control = sel.get_node("Margin/VBox")
	var lst: Control = sel.get_node("Margin/VBox/List")
	var row_h: float = (lst.get_child(0) as Control).size.y if lst.get_child_count() > 0 else 0.0
	print("  목록 %d곡 · 리스트 %.0fpx (한 줄 %.0fpx) · VBox %.0fpx / 뷰포트 %.0fpx · 목록 외 %.0fpx"
		% [lst.get_child_count(), lst.size.y, row_h, vbox.size.y, vp, vbox.size.y - lst.size.y])
	ok(vbox.size.y <= vp,
		"목록이 화면 안에 들어온다 (%.0f <= %.0f)" % [vbox.size.y, vp])

	# 목록 창의 불변식: 어디를 고르든 '고른 줄이 실제로 그려져 있어야' 한다.
	# 창 계산이 틀리면 선택은 되는데 화면에 없는 상태가 되고, 그건 목록이
	# 넘쳐서 안 보이던 것과 증상이 똑같다.
	var n := entries.size()
	for target in [0, 1, n / 2, n - 2, n - 1]:
		if target < 0 or target >= n:
			continue
		while int(sel.get("_sel")) > target:
			sel._input(key(KEY_UP))
		while int(sel.get("_sel")) < target:
			sel._input(key(KEY_DOWN))
		var want: String = entries[target].title
		var shown := false
		var rows := 0
		for ch in sel.get_node("Margin/VBox/List").get_children():
			# 곡 줄은 HBox(난이도 배지 + 제목), '더 있음' 줄은 Label 하나다.
			var t := ""
			if ch is Label:
				t = (ch as Label).text
			else:
				for sub in ch.get_children():
					if sub is Label:
						t += (sub as Label).text
			if t.contains("▶ ") and t.contains(want):
				shown = true
			if not t.strip_edges().begins_with("▲") and not t.strip_edges().begins_with("▼"):
				rows += 1
		ok(shown, "%d번째 선택이 화면에 그려진다 (%s)" % [target, want])
		ok(rows <= sel.VISIBLE_ROWS, "그려진 곡 줄 %d <= %d" % [rows, sel.VISIBLE_ROWS])

	print("PASS" if _fails == 0 else "FAILED %d" % _fails)
	get_tree().quit(_fails)
