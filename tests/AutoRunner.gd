extends Node

## 오토플레이 데모 테스트.
##   godot --headless --audio-driver CoreAudio res://tests/AutoScene.tscn
##
## 잠그는 약속: **오토는 항상 정확하다** — 전 타일 delta 0, 정확도 100%, 랭크 P.
## 사람 입력 경로의 프레임 오차조차 안 타는 이유가 이 약속이다(_apply_press 에
## 0 을 직접 먹인다). 그리고 오토는 기록·리플레이에 아무것도 안 남긴다 —
## '본 것'이 '친 것'을 덮어쓰면 안 된다.
##
## 채보는 t06_hold — 홀드(밟고-떼기)까지 봇이 처리하는지 같이 본다.

var _main: Node
var _fails := 0
var _log: Array[String] = []
var _t0 := 0
var _o_sent := false


func _ready() -> void:
	AudioServer.set_bus_mute(0, true)
	var scene: PackedScene = load("res://scenes/Main.tscn")
	_main = scene.instantiate()
	_main.set("chart", load("res://charts/t06_hold.tres"))
	add_child(_main)
	_t0 = Time.get_ticks_usec()


func _key(code: int) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = true
	Input.parse_input_event(ev)
	var up := InputEventKey.new()
	up.keycode = code
	up.physical_keycode = code
	up.pressed = false
	Input.parse_input_event(up)


func _process(_d: float) -> void:
	if float(Time.get_ticks_usec() - _t0) / 1e6 > 40.0:
		_expect(false, "타임아웃")
		_finish()
		return
	if not AudioClock.is_warm():
		return
	# 시작하자마자 일시정지 -> O 로 오토 진입. 실제 사용자 경로 그대로다.
	if not _o_sent:
		_o_sent = true
		_key(KEY_ESCAPE)
		_key(KEY_O)
		return
	if bool(_main.get("_finished")):
		var score: Score = _main.get_node("Score")
		_expect(bool(_main.get("_auto_mode")), "오토 모드로 완주했다")
		_expect(score.accuracy() >= 100.0 - 1e-6,
			"정확도 100%% (%.4f%%)" % score.accuracy())
		_expect(score.rank() == "P", "랭크 P (%s)" % score.rank())
		_expect(score.count_of(Judge.Verdict.PERFECT) == score.total,
			"전부 일반 Perfect (%d/%d)"
				% [score.count_of(Judge.Verdict.PERFECT), score.total])
		_expect(score.total == int(_main.get("_judged_total")),
			"판정 수 %d == 분모 %d (홀드 뗌 포함)"
				% [score.total, int(_main.get("_judged_total"))])
		_expect((_main.get("_last_replay") as Array).is_empty(),
			"오토는 리플레이로 안 남는다")
		var ds: Array = score.deltas
		var worst := 0.0
		for d2 in ds:
			worst = maxf(worst, absf(float(d2)))
		_expect(worst < 1e-6, "모든 delta 가 정확히 0 (최대 %.4fms)" % worst)
		_finish()


func _expect(cond: bool, what: String) -> void:
	_log.append(("  ok   " if cond else "  FAIL ") + what)
	if not cond:
		_fails += 1


func _finish() -> void:
	set_process(false)
	for l in _log:
		print(l)
	print("  %s" % ("PASS" if _fails == 0 else "FAILED %d" % _fails))
	get_tree().quit(_fails)
