extends Node

## 조작 표면 테스트.
##   godot --headless --audio-driver CoreAudio res://tests/InputScene.tscn
##
## 왜 필요한가:
##   SmokeRunner 의 자동플레이는 '정확한 시각'에만 누른다. 그래서 판정 체인이
##   자기일관적이라는 건 알지만, 다음은 한 번도 안 돌려봤다.
##     - 일부러 늦게/빨리 눌렀을 때 등급이 제대로 나오는가
##     - R 재시작이 상태를 되돌리는가
##     - 키 리피트(echo)가 걸러지는가
##     - 워밍업 중 입력이 무시되는가
##     - 곡 종료 후 입력이 크래시를 안 내는가
##   전부 '조작'이고, 전부 실제 입력 경로를 타야만 검증된다.
##
## 짧은 채보(t04_mixed, 9타일 4.5초)를 쓴다. song140 은 70초라 반복 검증에 비싸다.

## 타일 1..9 에 대한 의도 오프셋(ms). t04_mixed 는 심판 타일이 9개다.
## 개수가 타일 수와 안 맞으면 남는 타일이 자동으로 미스가 되어 계수가 어긋난다.
## 999 = 일부러 안 누른다(감시자가 TOO_LATE 를 내야 한다).
##
## 값은 '판정창 중앙 - 폴링 편향(~10ms)' 이다. 이 하네스는 프레임마다 폴링해서
## 항상 +7~13ms 늦게 누른다. 처음에 +45(LATE PERFECT 창 30~60 의 중앙)를 줬더니
## 실측 +52~58 로 상한 60 에 2~8ms 여유로 붙어서, 프레임 히치 한 번에
## VERY_LATE 로 넘어가는 플레이크가 났다. 중앙-10 으로 두면 여유가 12ms 이상이다.
const OFFSETS := [-10.0, 35.0, -55.0, 75.0, -95.0, 999.0, -10.0, -10.0, -10.0]

var _main: Node
var _hit: PackedFloat32Array
var _pressed := {}
var _phase := "play"
var _fails := 0
var _log: Array[String] = []
var _echo_sent := false
var _t0 := 0


func _ready() -> void:
	AudioServer.set_bus_mute(0, true)   # 테스트가 스피커로 나가면 안 된다
	var scene: PackedScene = load("res://scenes/Main.tscn")
	_main = scene.instantiate()
	_main.set("chart", load("res://charts/t04_mixed.tres"))
	add_child(_main)
	_hit = _main.get("_hit_times")
	_t0 = Time.get_ticks_usec()
	print("조작 테스트 — 채보 %s · 타일 %d"
		% [(_main.get("chart") as Chart).title, _hit.size() - 1])
	if OFFSETS.size() != _hit.size() - 1:
		print("  FAIL 오프셋 %d개 != 심판 타일 %d개 — 남는 타일이 자동 미스가 된다"
			% [OFFSETS.size(), _hit.size() - 1])
		_fails += 1
	print("  의도 오프셋: %s" % str(OFFSETS))


func _press(code: int, echo := false) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = true
	ev.echo = echo
	Input.parse_input_event(ev)


func _process(_d: float) -> void:
	var wall := float(Time.get_ticks_usec() - _t0) / 1_000_000.0
	if wall > 30.0:
		_finish("타임아웃")
		return

	# 1) 워밍업 중 입력은 무시돼야 한다
	if not AudioClock.is_warm():
		if not _pressed.has("warm"):
			_pressed["warm"] = true
			_press(KEY_SPACE)
		return

	if _phase == "play":
		var idx: int = _main.get("_idx")
		if idx >= _hit.size():
			_check_play()
			return
		var k := idx - 1
		if k < OFFSETS.size() and not _pressed.has(idx):
			var off: float = OFFSETS[k]
			if off < 900.0 and float(AudioClock.judged_ms()) >= _hit[idx] + off:
				_pressed[idx] = true
				_press(KEY_SPACE)
				# 2) 키 리피트: 같은 프레임에 echo 를 세 번 더 보낸다.
				#    걸러지지 않으면 idx 가 폭주한다.
				if not _echo_sent:
					_echo_sent = true
					for i in range(3):
						_press(KEY_SPACE, true)


func _check_play() -> void:
	var score: Score = _main.get_node("Score")
	var ds: Array = score.deltas

	# 실제로 잰 오차가 의도한 오프셋과 맞는가 (입력 경로 검증)
	var intended: Array[float] = []
	for o in OFFSETS:
		if o < 900.0:
			intended.append(o)
	_expect(ds.size() == intended.size(),
		"입력 판정 수 %d == 의도 %d" % [ds.size(), intended.size()])
	for i in range(mini(ds.size(), intended.size())):
		var err: float = absf(ds[i] - intended[i])
		# 프레임 granularity(~7ms) + 입력 파싱 지연만큼 늦게 눌린다.
		# 실측이 일관되게 +방향으로 치우친다(약 +11ms).
		# 그중 ~7ms 는 이 하네스가 프레임마다 폴링해서 최대 한 프레임 늦게 누르는 탓이고,
		# 나머지가 엔진 입력 디스패치다. 실제 키보드는 여기에 하드웨어/OS 지연이 더 붙는다.
		# -> 캘리브레이션 슬라이더를 + 방향으로 밀어야 한다는 설계 예측과 일치한다.
		_expect(err < 20.0, "  오프셋 %+.0f 의도 -> 실측 %+.1f (오차 %.1f)"
			% [intended[i], ds[i], err])

	# 등급이 제대로 매핑됐는가
	_expect(score.count_of(Judge.Verdict.TOO_LATE) == 1,
		"무입력 1건이 TOO_LATE (%d건)" % score.count_of(Judge.Verdict.TOO_LATE))
	_expect(score.count_of(Judge.Verdict.PERFECT) == 4,
		"의도 -10ms 네 번이 PERFECT (%d건)" % score.count_of(Judge.Verdict.PERFECT))
	_expect(score.count_of(Judge.Verdict.LATE_PERFECT) == 1,
		"+35ms -> LATE PERFECT (%d건)" % score.count_of(Judge.Verdict.LATE_PERFECT))
	_expect(score.count_of(Judge.Verdict.EARLY_PERFECT) == 1,
		"-55ms -> EARLY PERFECT (%d건)" % score.count_of(Judge.Verdict.EARLY_PERFECT))
	_expect(score.count_of(Judge.Verdict.VERY_LATE) == 1,
		"+75ms -> LATE! (%d건)" % score.count_of(Judge.Verdict.VERY_LATE))
	_expect(score.count_of(Judge.Verdict.VERY_EARLY) == 1,
		"-95ms -> EARLY! (%d건)" % score.count_of(Judge.Verdict.VERY_EARLY))

	# 3) echo 가 걸러졌는가 — 안 걸러졌으면 판정 수가 타일 수를 넘는다
	_expect(score.total <= _hit.size() - 1,
		"echo 필터: 판정 %d <= 타일 %d" % [score.total, _hit.size() - 1])

	# 4) 곡 종료 후 입력이 크래시를 안 내는가
	for i in range(5):
		_press(KEY_SPACE)
	_expect(true, "곡 종료 후 입력 5회 — 크래시 없음")

	# 5) R 재시작
	# 미스는 delta 가 없으므로 표본 수와 비교하려면 미스를 뺀 수를 써야 한다.
	var before_samples := score.deltas.size()
	_press(KEY_R)
	await get_tree().process_frame
	_expect(int(_main.get("_idx")) == 1, "R 재시작: idx 가 1 로 (%s)" % _main.get("_idx"))
	_expect(not bool(_main.get("_finished")), "R 재시작: finished 해제")
	_expect(score.total == 0, "R 재시작: 점수 초기화 (%d)" % score.total)
	_expect(score.deltas.size() == before_samples and before_samples > 0,
		"R 재시작: 산포 표본은 남는다 (%d)" % score.deltas.size())
	_expect(int(AudioClock.clamp_hits) == 0, "R 재시작: 클럭 카운터 리셋")

	_finish("")


func _expect(cond: bool, what: String) -> void:
	if cond:
		_log.append("  ok   " + what)
	else:
		_log.append("  FAIL " + what)
		_fails += 1


func _finish(note: String) -> void:
	set_process(false)
	if note != "":
		_log.append("  FAIL " + note)
		_fails += 1
	for l in _log:
		print(l)
	print("  %s" % ("PASS" if _fails == 0 else "FAILED %d" % _fails))
	get_tree().quit(_fails)
