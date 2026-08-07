extends Control

## 곡 선택. charts/ 의 .tres 를 스캔해 목록으로 보여준다.
##
## 조작: ↑↓ 이동 · Enter/Space 시작 · ESC 종료
##
## 익스포트 빌드 함정: PCK 안에서는 리소스가 "foo.tres.remap" 으로 보일 수 있다.
## 확장자를 자를 때 .remap 을 먼저 벗긴다.

const CHART_DIR := "res://charts"

var _entries: Array = []   # [{path, title, bpm, tiles, secs}]
var _sel := 0

## 테스트 시임. 헤드리스 테스트가 씬 전환을 억제하고 선택 로직만 검증한다 —
## change_scene 은 테스트 러너 자신(current_scene)을 갈아치워 테스트가 죽기 때문.
var suppress_scene_change := false

@onready var _list: VBoxContainer = $Margin/VBox/List
@onready var _info: Label = $Margin/VBox/Info


func _ready() -> void:
	_entries = _scan_charts()
	# 마지막에 고른 곡을 기억한다
	for i in range(_entries.size()):
		if _entries[i].path == GameState.selected_chart:
			_sel = i
	_rebuild()


## 차트 목록. 파일 이름이 아니라 리소스 안의 제목·수치를 보여준다 —
## 고르는 기준은 파일명이 아니라 '어떤 곡인가'다.
func _scan_charts() -> Array:
	var out: Array = []
	var d := DirAccess.open(CHART_DIR)
	if d == null:
		push_error("charts/ 를 열 수 없다")
		return out
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		var name := f.trim_suffix(".remap")
		if name.ends_with(".tres"):
			var path := CHART_DIR + "/" + name
			var c: Chart = load(path)
			if c != null and c.is_valid():
				# 길이는 오디오 파일이 아니라 '채보'의 마지막 히트 시각이다 —
				# 테스트 채보들이 60초짜리 클릭 트랙을 공유해서 오디오 길이는 오해를 부른다.
				var ht := ChartRuntime.hit_times_ms(c)
				out.append({
					"path": path,
					"title": c.title if c.title != "" else name.get_basename(),
					"bpm": c.bpm,
					"tiles": c.angles.size() - 1,
					"secs": ht[ht.size() - 1] / 1000.0 if ht.size() > 0 else 0.0,
					"speed": c.speed_changes.size() > 0,
				})
		f = d.get_next()
	out.sort_custom(func(a, b): return a.path < b.path)
	return out


func _rebuild() -> void:
	for ch in _list.get_children():
		ch.queue_free()
	for i in range(_entries.size()):
		var e: Dictionary = _entries[i]
		var l := Label.new()
		var mark := "▶ " if i == _sel else "   "
		var extra := "  🐇" if e.speed else ""
		l.text = "%s%s%s" % [mark, e.title, extra]
		l.add_theme_font_size_override("font_size", 24)
		if i == _sel:
			l.modulate = Color(1.15, 1.05, 0.7)
		else:
			l.modulate = Color(0.55, 0.6, 0.72)
		_list.add_child(l)
	if _entries.is_empty():
		_info.text = "차트가 없다 — python3 tools/make_charts.py"
		return
	var e: Dictionary = _entries[_sel]
	_info.text = "BPM %.0f   ·   타일 %d   ·   %d:%02d" % [
		e.bpm, e.tiles, int(e.secs) / 60, int(e.secs) % 60]


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo:
		return
	match k.keycode:
		KEY_UP:
			_sel = maxi(0, _sel - 1)
			_rebuild()
		KEY_DOWN:
			_sel = mini(_entries.size() - 1, _sel + 1)
			_rebuild()
		KEY_ENTER, KEY_SPACE, KEY_KP_ENTER:
			if not _entries.is_empty():
				GameState.selected_chart = _entries[_sel].path
				if not suppress_scene_change:
					get_tree().change_scene_to_file("res://scenes/Main.tscn")
		KEY_ESCAPE:
			get_tree().quit()
