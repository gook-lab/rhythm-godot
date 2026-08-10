extends Node

## 리플레이 테스트.
##   godot --headless --audio-driver CoreAudio res://tests/ReplayScene.tscn
##
## 검증하는 약속: **재생은 원판의 판정을 비트 단위로 재현한다.**
## 기록이 키 입력이 아니라 '판정 결과(delta)'라서 가능한 약속이고,
## 프레임 양자화가 발화를 몇 ms 밀어도 delta 는 그대로라 판정이 안 흔들린다.
##
## 채보는 t06_hold — 짧고(3.5초) 홀드가 둘이다. 일부러 섞는다:
##   변칙 오프셋 탭 · 안 누르는 미스 하나 · 홀드 두 개(누르고-떼기)
## 그래야 '전부 Perfect' 같은 자명한 경우만 재현되는 가짜 통과를 못 한다.

const CHART := "res://charts/t06_hold.tres"
## 타일별 의도 오프셋. 4번 타일은 일부러 안 누른다(999 = 미스).
const OFFS := {1: -10.0, 2: 15.0, 3: -30.0, 4: 999.0, 5: -10.0, 6: 30.0, 7: -10.0}

var _main: Node
var _fails := 0
var _log: Array[String] = []
var _t0 := 0
var _hit: PackedFloat32Array
var _phase := "play"
var _tapped := {}
var _released := {}
var _orig := {}          # 원판 스냅샷
var _v_sent := false


func _ready() -> void:
	AudioServer.set_bus_mute(0, true)
	var scene: PackedScene = load("res://scenes/Main.tscn")
	_main = scene.instantiate()
	_main.set("chart", load(CHART))
	add_child(_main)
	_hit = _main.get("_hit_times")
	_t0 = Time.get_ticks_usec()
	print("리플레이 테스트 — %s · 타일 %d" % [CHART, _hit.size() - 1])


func _key(code: int, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)


func _process(_d: float) -> void:
	if float(Time.get_ticks_usec() - _t0) / 1e6 > 60.0:
		_expect(false, "타임아웃 (phase=%s)" % _phase)
		_finish()
		return
	if not AudioClock.is_warm():
		return
	var t := float(AudioClock.judged_ms())
	var chart: Chart = _main.get("chart")

	if _phase == "play" or _phase == "watch":
		# 원판에서만 손을 댄다. 리플레이 중에는 구경만 한다 —
		# 판정 입력이 막혔는지도 이걸로 같이 검증된다(막혔으면 결과가 같다).
		if _phase == "play":
			var idx: int = _main.get("_idx")
			if idx < _hit.size() and not _tapped.has(idx):
				var off: float = OFFS.get(idx, -10.0)
				if off < 900.0 and t + 8.0 >= _hit[idx] + off:
					_tapped[idx] = true
					_key(KEY_SPACE, true)
					if ChartRuntime.hold_orbits_at(chart, idx) <= 0.0:
						_key(KEY_SPACE, false)
			var ht: int = _main.get("_hold_tile")
			if ht >= 0 and not _released.has(ht):
				if t + 8.0 >= float(_main.get("_hold_end_ms")) - 20.0:
					_released[ht] = true
					_key(KEY_SPACE, false)

		if bool(_main.get("_finished")):
			if _phase == "play":
				_snapshot_and_start_replay()
			else:
				_check_replay()
				_finish()
		return


func _counts() -> Dictionary:
	var score: Score = _main.get_node("Score")
	var c := {}
	for v in Judge.Verdict.values():
		c[v] = score.count_of(v)
	return c


func _snapshot_and_start_replay() -> void:
	var score: Score = _main.get_node("Score")
	_orig = {
		"counts": _counts(),
		"total": score.total,
		"acc": score.accuracy(),
		"deltas": score.deltas.duplicate(),
		"rec_n": (_main.get("_last_replay") as Array).size(),
	}
	_expect(int(_orig.rec_n) > 0, "완주가 리플레이로 보관됐다 (%d개)" % int(_orig.rec_n))
	_expect(score.count_of(Judge.Verdict.TOO_LATE) == 1, "의도한 미스 1건이 원판에 있다")
	# 결과 화면에서 V — 실제 사용자 경로 그대로.
	_key(KEY_V, true)
	_key(KEY_V, false)
	_v_sent = true
	_phase = "watch"
	_log.append("  ..   원판 완료: 판정 %d건 · 정확도 %.2f%% — V 재생 시작"
		% [int(_orig.total), float(_orig.acc)])


func _check_replay() -> void:
	var score: Score = _main.get_node("Score")
	_expect(bool(_main.get("_replay_mode")), "리플레이 모드로 완주했다")
	_expect(score.total == int(_orig.total),
		"판정 수 재현 %d == %d" % [score.total, int(_orig.total)])
	var oc: Dictionary = _orig.counts
	var same := true
	for v in Judge.Verdict.values():
		if score.count_of(v) != int(oc[v]):
			same = false
			_expect(false, "등급 %s 불일치: %d != %d"
				% [Judge.verdict_name(v), score.count_of(v), int(oc[v])])
	if same:
		_expect(true, "7등급 전부 건수 일치")
	_expect(absf(score.accuracy() - float(_orig.acc)) < 1e-6,
		"정확도 비트 단위 재현 (%.4f%%)" % score.accuracy())
	# delta 는 세션 누적이라 리플레이 표본이 '뒤에 이어붙는다'.
	# 뒤쪽 표본이 원판과 원소 단위로 같아야 한다.
	var ds: Array = score.deltas
	var od: Array = _orig.deltas
	if ds.size() == od.size() * 2:
		var exact := true
		for i in range(od.size()):
			if absf(float(ds[od.size() + i]) - float(od[i])) > 1e-9:
				exact = false
		_expect(exact, "판정 오차 전 표본 원소 단위 재현")
	else:
		_expect(false, "표본 수 %d != 원판 x2 %d" % [ds.size(), od.size() * 2])
	_expect((_main.get("_last_replay") as Array).size() == int(_orig.rec_n),
		"리플레이가 기록을 덮어쓰지 않았다")


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
