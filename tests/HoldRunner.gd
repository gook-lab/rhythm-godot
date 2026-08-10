extends Node

## 홀드 타일 테스트.
##   godot --headless --audio-driver CoreAudio res://tests/HoldScene.tscn
##
## 여기서만 잡히는 것:
##   홀드는 이 게임 최초의 '누르고 있는' 입력이다. 뗌 이벤트(pressed=false)는
##   그 전까지 _input 첫 줄에서 통째로 버려지던 값이라, 경로가 하나 새로 생겼다.
##   그리고 홀드는 히트타임을 뒤로 민다 — 채보 전체의 시간축이 바뀌는 유일한 타일이라
##   "붙였더니 뒤가 다 밀렸다" 를 실제로 재보지 않으면 알 수 없다.
##
## 채보: t06_hold — 타일 2 에서 1바퀴, 타일 5 에서 2바퀴.
## 120bpm 이라 1박 = 500ms, 한 바퀴 = 2박 = 1000ms.

const CHART := "res://charts/t06_hold.tres"

var _main: Node
var _fails := 0
var _log: Array[String] = []
var _t0 := 0
var _hit: PackedFloat32Array
var _tapped := {}
var _released := {}
var _done := false


func _ready() -> void:
	AudioServer.set_bus_mute(0, true)
	var scene: PackedScene = load("res://scenes/Main.tscn")
	_main = scene.instantiate()
	_main.set("chart", load(CHART))
	add_child(_main)
	_hit = _main.get("_hit_times")
	_t0 = Time.get_ticks_usec()
	var chart: Chart = _main.get("chart")

	# ── 시간축 검증은 입력 없이 지금 할 수 있다 ──────────────────
	# 전부 1박(500ms) 직선인데 타일 2 뒤에 1바퀴(1000ms), 타일 5 뒤에 2바퀴(2000ms).
	print("홀드 채보 %s · 타일 %d" % [chart.title, _hit.size() - 1])
	_expect(_hit.size() >= 8, "타일 수 (%d)" % _hit.size())
	_gap(1, 2, 500.0, "타일1->2 홀드 앞 = 1박")
	_gap(2, 3, 1500.0, "타일2->3 = 1박 + 홀드 1바퀴(2박)")
	_gap(3, 4, 500.0, "타일3->4 홀드 뒤 = 다시 1박")
	_gap(5, 6, 2500.0, "타일5->6 = 1박 + 홀드 2바퀴(4박)")
	_expect(is_equal_approx(ChartRuntime.hold_beats_at(chart, 2), 2.0),
		"1바퀴 = 2박 (%.1f)" % ChartRuntime.hold_beats_at(chart, 2))
	_expect(is_equal_approx(ChartRuntime.hold_beats_at(chart, 4), 0.0),
		"홀드 아닌 타일은 0박")

	# 착지 불변식: 홀드는 360도의 배수라 좌표가 안 바뀌어야 한다.
	var pos := ChartRuntime.tile_positions(chart.angles, 96.0)
	var worst := 0.0
	for i in range(1, chart.angles.size()):
		var spin := ChartRuntime.spin_at(chart, i - 1)
		var mid := ChartRuntime.is_midspin(chart, i)
		var extra := 360.0 * ChartRuntime.hold_orbits_at(chart, i - 1) \
			* (1.0 if spin >= 0 else -1.0)
		var a := ChartRuntime.orbit_start_deg(chart.angles, i, mid)
		var sw := ChartRuntime.orbit_sweep_deg(chart.angles, i, spin, mid) + extra
		var end := deg_to_rad(a + sw)
		var landed: Vector2 = pos[i - 1] + Vector2(cos(end), -sin(end)) * 96.0
		worst = maxf(worst, landed.distance_to(pos[i]))
	_expect(worst < 0.01, "홀드 바퀴를 더해도 착지가 그대로 (%.4fpx)" % worst)


func _gap(a: int, b: int, want: float, what: String) -> void:
	if b >= _hit.size():
		_expect(false, what + " (타일 없음)")
		return
	var got: float = _hit[b] - _hit[a]
	_expect(absf(got - want) < 2.0, "%s — %.0fms (기대 %.0f)" % [what, got, want])


func _key(code: int, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)


func _process(_d: float) -> void:
	if _done:
		return
	if float(Time.get_ticks_usec() - _t0) / 1e6 > 40.0:
		_expect(false, "타임아웃")
		_finish()
		return
	if not AudioClock.is_warm():
		return
	var t := float(AudioClock.judged_ms())
	var chart: Chart = _main.get("chart")

	# 밟기: 판정 커서가 가리키는 타일의 시각에 누른다.
	var idx: int = _main.get("_idx")
	if idx < _hit.size() and not _tapped.has(idx) and t + 8.0 >= _hit[idx]:
		_tapped[idx] = true
		_key(KEY_SPACE, true)
		# 홀드가 아니면 바로 뗀다(다음 탭을 위해). 홀드면 계속 붙들고 있는다.
		if ChartRuntime.hold_orbits_at(chart, idx) <= 0.0:
			_key(KEY_SPACE, false)

	# 떼기: 홀드가 끝나는 시각에 뗀다.
	var ht: int = _main.get("_hold_tile")
	if ht >= 0 and not _released.has(ht):
		var end: float = float(_main.get("_hold_end_ms"))
		if t + 8.0 >= end:
			_released[ht] = true
			_key(KEY_SPACE, false)

	if bool(_main.get("_finished")) or idx >= _hit.size():
		_check()
		_finish()


func _check() -> void:
	var score: Score = _main.get_node("Score")
	_expect(_released.size() == 2, "홀드 두 개를 다 뗐다 (%d)" % _released.size())
	# 밟기 7 + 떼기 2 = 9 판정. 홀드가 판정을 하나 더 만든다는 게 핵심이다.
	_expect(score.total == int(_main.get("_judged_total")),
		"판정 수 %d == 분모 %d (홀드는 두 번 센다)"
			% [score.total, int(_main.get("_judged_total"))])
	_expect(score.count_of(Judge.Verdict.TOO_LATE) == 0,
		"미스 없음 (%d)" % score.count_of(Judge.Verdict.TOO_LATE))
	_expect(score.accuracy() > 95.0, "정확도 %.1f%%" % score.accuracy())


func _expect(cond: bool, what: String) -> void:
	_log.append(("  ok   " if cond else "  FAIL ") + what)
	if not cond:
		_fails += 1


func _finish() -> void:
	_done = true
	set_process(false)
	for l in _log:
		print(l)
	print("  %s" % ("PASS" if _fails == 0 else "FAILED %d" % _fails))
	get_tree().quit(_fails)
