extends Node

## 체크포인트 부활 테스트.
##   godot --headless --audio-driver CoreAudio res://tests/CheckpointScene.tscn
##
## 왜 씬이어야 하나: AudioClock 이 autoload 라 --script 모드에선 없다
## (SmokeRunner 머리말과 같은 이유).
##
## 여기서만 잡을 수 있는 것:
##   AudioClock.seek() 는 이 게임에서 유일하게 '시간을 되감는' 경로다.
##   now_ms() 의 단조 클램프가 되감기를 전제하지 않기 때문에, seek 가
##   _last_ms 이력을 안 버리면 클럭이 옛 값에 영원히 얼어붙는다 —
##   크래시가 아니라 '그 뒤 판정이 전부 미스'가 되는 조용한 고장이라
##   단위 테스트로는 절대 안 잡힌다. 실제로 곡을 틀고 되감아 봐야 한다.

var _main: Node
var _fails := 0
var _log: Array[String] = []
var _t0 := 0
var _phase := "wait_cp"      # 체크포인트를 지날 때까지 정상 플레이
var _cp := -1
var _died_at := 0.0
var _clock_after := -1.0
var _idx_after := -1
var _revive_frames := 0


func _ready() -> void:
	AudioServer.set_bus_mute(0, true)
	var scene: PackedScene = load("res://scenes/Main.tscn")
	_main = scene.instantiate()
	_main.set("chart", load("res://charts/mureka_01.tres"))
	add_child(_main)
	_t0 = Time.get_ticks_usec()
	var chart: Chart = _main.get("chart")
	if chart.checkpoint_tiles.size() == 0:
		_expect(false, "차트에 체크포인트가 없다 — 생성기를 먼저 돌려라")
		_finish()
		return
	_cp = int(chart.checkpoint_tiles[0])
	print("차트 %s · 첫 체크포인트 타일 %d / %d"
		% [chart.title, _cp, chart.angles.size() - 1])


func _process(_d: float) -> void:
	if float(Time.get_ticks_usec() - _t0) / 1e6 > 120.0:
		_expect(false, "타임아웃")
		_finish()
		return
	if not AudioClock.is_warm():
		return

	var idx: int = _main.get("_idx")

	# 1) 체크포인트를 넘길 때까지는 정확히 쳐서 살아 있는다.
	if _phase == "wait_cp":
		_autoplay()
		if idx > _cp + 6:
			_phase = "die"
			_died_at = float(AudioClock.judged_ms())
			_log.append("  ..   체크포인트 %d 통과 (타일 %d · 클럭 %.0fms)"
				% [_cp, idx, _died_at])
		return

	# 2) 손을 놓는다. 감시자가 미스를 쌓아 체력이 바닥나고 부활해야 한다.
	if _phase == "die":
		if bool(_main.get("_finished")):
			_expect(false, "부활하지 않고 곡이 끝나 버렸다 (체크포인트 미작동)")
			_finish()
			return
		if int(_main.get("_checkpoints_used")) > 0:
			_phase = "check"
			_clock_after = float(AudioClock.judged_ms())
			_idx_after = int(_main.get("_idx"))
		return

	# 3) 되살아난 뒤 클럭이 실제로 흐르는지 본다. 단조 클램프가 얼면 여기서 걸린다.
	if _phase == "check":
		_revive_frames += 1
		if _revive_frames < 60:
			return
		var score: Score = _main.get_node("Score")
		var now := float(AudioClock.judged_ms())
		_expect(_clock_after < _died_at - 500.0,
			"부활이 곡을 되감았다 (%.0fms -> %.0fms)" % [_died_at, _clock_after])
		_expect(_idx_after <= _cp,
			"판정 커서가 체크포인트로 돌아갔다 (%d <= %d)" % [_idx_after, _cp])
		_expect(now > _clock_after + 300.0,
			"부활 뒤 클럭이 계속 흐른다 (%.0f -> %.0fms) — 단조 클램프 이력이 안 남았다"
				% [_clock_after, now])
		_expect(is_equal_approx(score.health, Score.HEALTH_MAX),
			"부활 시 체력 만땅 (%.1f)" % score.health)
		_expect(score.total > 0, "판정 기록은 남는다 (%d건)" % score.total)
		_expect(not bool(_main.get("_finished")), "곡이 안 끝났다")
		_expect(int(AudioClock.clamp_hits) < 20,
			"부활 뒤 역행 카운터가 폭주하지 않는다 (%d회)" % int(AudioClock.clamp_hits))
		# 되살아난 자리에서 다시 칠 수 있는가 — 부활이 입력을 죽이면 의미가 없다.
		var before := score.total
		_phase = "replay"
		_replay_left = 12
		_log.append("  ..   부활 확인. 다시 칠 수 있는지 검사 (판정 %d건에서 시작)"
			% before)
		return

	if _phase == "replay":
		_autoplay()
		if _replay_left <= 0:
			var score2: Score = _main.get_node("Score")
			_expect(score2.combo >= 8,
				"부활 뒤 연속으로 다시 칠 수 있다 (콤보 %d)" % score2.combo)
			_finish()
		return


var _replay_left := 0
var _pressed := {}


func _autoplay() -> void:
	var ht: PackedFloat32Array = _main.get("_hit_times")
	var ji: int = _main.get("_idx")
	if ji >= ht.size() or _pressed.has(ji):
		return
	if float(AudioClock.judged_ms()) + 10.0 >= ht[ji]:
		_pressed[ji] = true
		var ev := InputEventKey.new()
		ev.keycode = KEY_SPACE
		ev.physical_keycode = KEY_SPACE
		ev.pressed = true
		Input.parse_input_event(ev)
		if _phase == "replay":
			_replay_left -= 1


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
