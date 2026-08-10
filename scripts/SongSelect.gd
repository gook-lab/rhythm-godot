extends Control

## 곡 선택. charts/ 의 .tres 를 스캔해 목록으로 보여주고,
## Records 의 곡별 기록(최고 랭크·정확도·진행도)을 함께 붙인다.
##
## 조작: ↑↓ 이동 · Enter/Space 시작 · K 판정키 설정 · ESC 종료
##
## 익스포트 빌드 함정: PCK 안에서는 리소스가 "foo.tres.remap" 으로 보일 수 있다.
## 확장자를 자를 때 .remap 을 먼저 벗긴다.

const CHART_DIR := "res://charts"

var _entries: Array = []   # [{path, title, bpm, tiles, secs}]
var _sel := 0

## 판정키 설정 모드. true 인 동안 키 입력은 전부 바인딩 토글로 간다.
var _binding := false

## 테스트 시임. 헤드리스 테스트가 씬 전환을 억제하고 선택 로직만 검증한다 —
## change_scene 은 테스트 러너 자신(current_scene)을 갈아치워 테스트가 죽기 때문.
var suppress_scene_change := false

@onready var _list: VBoxContainer = $Margin/VBox/List
@onready var _info: Label = $Margin/VBox/Info
@onready var _keybind_panel: PanelContainer = $KeybindPanel
@onready var _keys_label: Label = $KeybindPanel/Margin/VBox/Keys


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
					# 원곡 오디오 여부. 채보 스키마엔 없지만 채널 수가 그대로
					# 구분자다 — 신스 렌더는 전부 모노(write_wav 기본), 원곡
					# 채택(midi2song --audio)은 전부 스테레오로 굽는다.
					# 신스가 스테레오가 되는 날엔 이 배지가 과표시될 뿐 안 깨진다.
					"original": c.audio is AudioStreamWAV
						and (c.audio as AudioStreamWAV).stereo,
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
		# 🎵 = 원곡 오디오가 흐르는 곡. 어느 곡이 '진짜 노래'인지 고르기 전에 보여야
		# 원곡 도입(README 원곡 채택 섹션)이 목록에서 체감된다.
		var extra := ("  🎵" if e.original else "") + ("  🐇" if e.speed else "")
		l.text = "%s%s%s%s" % [mark, e.title, extra, _record_tail(e.path)]
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
	_info.text = "BPM %.0f   ·   타일 %d   ·   %d:%02d   ·   [M] 입력음 %s\n%s" % [
		e.bpm, e.tiles, int(e.secs) / 60, int(e.secs) % 60,
		"켬" if Records.sfx_enabled else "끔", _record_line(e.path)]


## 목록 행 끝에 붙는 기록 요약. 클리어했으면 랭크가, 못 했으면 진행도가 성적표다.
func _record_tail(path: String) -> String:
	var r := Records.get_record(path)
	if r.is_empty():
		return ""
	if int(r.get("clears", 0)) > 0:
		return "   —   %s %.2f%%" % [r.get("best_rank", "-"), float(r.get("best_acc", 0.0))]
	return "   —   진행 %.0f%%" % float(r.get("best_progress", 0.0))


## 선택된 곡의 기록 상세(Info 두 번째 줄).
func _record_line(path: String) -> String:
	var r := Records.get_record(path)
	if r.is_empty():
		return "기록 없음 — 첫 도전"
	return "최고 %s %.2f%%   ·   콤보 %d   ·   진행 %.0f%%   ·   클리어 %d / 플레이 %d" % [
		r.get("best_rank", "-"), float(r.get("best_acc", 0.0)),
		int(r.get("best_combo", 0)), float(r.get("best_progress", 0.0)),
		int(r.get("clears", 0)), int(r.get("plays", 0))]


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo:
		return
	if _binding:
		_binding_input(k.keycode)
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
		KEY_K:
			_binding = true
			_keybind_panel.visible = true
			_refresh_keys()
		KEY_M:
			# 입력 효과음 토글. 플레이 중(Main)이 아니라 여기 두는 이유:
			# 바인딩이 비어 있으면 M 도 판정키다. 토글을 Main 에 두면 M 을
			# 예약키로 뺏어야 하고, 그만큼 양손 교타에서 쓸 키가 줄어든다.
			Records.sfx_enabled = not Records.sfx_enabled
			Records.save()
			_rebuild()
		KEY_ESCAPE:
			get_tree().quit()


## 판정키 설정 모드의 키 처리. 아무 키나 누르면 토글 —
## '치고 싶은 키를 그냥 쳐 본다'가 곧 설정이다.
func _binding_input(code: int) -> void:
	match code:
		KEY_ENTER, KEY_KP_ENTER, KEY_ESCAPE:
			_binding = false
			_keybind_panel.visible = false
			Records.save()
		KEY_BACKSPACE:
			Records.bound_keys = PackedInt32Array()
			_refresh_keys()
		_:
			if Records.toggle_key(code):
				_refresh_keys()


func _refresh_keys() -> void:
	if Records.bound_keys.is_empty():
		_keys_label.text = "(전부)\n예약키(ESC·R)와 수식키를 뺀 모든 키가 판정키다"
	else:
		var names := PackedStringArray()
		for c in Records.bound_keys:
			names.append(OS.get_keycode_string(c))
		_keys_label.text = "  ".join(names)
