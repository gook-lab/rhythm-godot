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
## 항상 +7~13ms 늦게 누른다. 처음에 +45(당시 LATE PERFECT 창 30~60 의 중앙)를
## 줬더니 실측 +52~58 로 상한에 2~8ms 여유로 붙어서 프레임 히치 한 번에
## 등급이 넘어가는 플레이크가 났다. 항상 '띠의 중앙'을 겨냥한다.
##
## 판정창 25/45/80 기준: LATE_PERFECT 띠 (25,45] 중앙 35 · VERY 띠 (45,80] 중앙 62.
const OFFSETS := [-10.0, 25.0, -45.0, 52.0, -72.0, 999.0, -10.0, -10.0, -10.0]

var _main: Node
var _hit: PackedFloat32Array
var _pressed := {}
var _phase := "play"
var _fails := 0
var _log: Array[String] = []
var _echo_sent := false
var _t0 := 0

## 일시정지 검증 상태. idx==4 에 도달하면 ESC 로 멈추고 90프레임 뒤 재개한다.
## 90프레임(~0.6초)은 미스 창(±110ms)을 한참 넘는다 — 일시정지가 클럭을 못 얼리면
## 감시자가 그 사이 미스를 쏟아내므로 여기서 반드시 걸린다.
var _pause_state := 0      # 0 대기 · 1 정지 중 · 2 완료
var _pause_frames := 0
var _pause_idx := 0
var _pause_total := 0
var _pause_clk := 0.0

## 하네스 정밀도 — 누른 결과(판정 delta)와 무관하게 하네스 쪽에서만 잰다.
## 이 하네스는 _process 에서 클럭이 목표를 넘은 걸 보고 누르고, 그 이벤트는 다음
## 프레임에 디스패치된다. 그래서 실제로 눌린 시각의 오차는 '폴링 지연(보낼 때 클럭 -
## 목표) + 디스패치 프레임 간격'이다. 로컬(7ms 프레임)에선 합이 10~15ms 라 20ms 폭
## 등급 띠를 겨냥할 수 있지만, 부하 걸린 CI 러너(프레임 p99 50ms대)에선 불가능하다
## (실측: 오차 27~46ms 로 등급이 옆 띠로 넘어갔다). 그 상태의 등급 결과는 게임이 아니라
## 측정 환경을 말한다 — SmokeRunner 의 입력 산포 σ SKIP 과 같은 판단이다.
const HARNESS_BUDGET_MS := 20.0
var _sent := {}            # idx -> [보낼 때 클럭 오프셋(ms), 보낸 시각(usec)]
var _dispatch_ms := {}     # idx -> 보낸 뒤 다음 러너 프레임까지의 벽시계 간격(ms)
var _inputs: Array = []    # 입력 판정(delta 유한) [타일, delta] — Judge.judged 로 받는다
var _inject_every := 0     # --inject-hitch=N --inject-ms=M: 하네스 정밀도 판정 자체 검증용
var _inject_ms := 30
var _frames := 0


func _ready() -> void:
	AudioServer.set_bus_mute(0, true)   # 테스트가 스피커로 나가면 안 된다
	var scene: PackedScene = load("res://scenes/Main.tscn")
	_main = scene.instantiate()
	_main.set("chart", load("res://charts/t04_mixed.tres"))
	add_child(_main)
	_hit = _main.get("_hit_times")
	(_main.get_node("Judge") as Judge).judged.connect(
		func(_v: Judge.Verdict, d: float, tile: int) -> void:
			if is_finite(d) and _phase == "play":
				_inputs.append([tile, d]))
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--inject-hitch="):
			_inject_every = int(a.split("=")[1])
		elif a.begins_with("--inject-ms="):
			_inject_ms = int(a.split("=")[1])
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
	_frames += 1
	if _inject_every > 0 and _frames % _inject_every == 0:
		OS.delay_msec(_inject_ms)
	for i in _sent:
		if not _dispatch_ms.has(i):
			_dispatch_ms[i] = float(Time.get_ticks_usec() - int(_sent[i][1])) / 1000.0
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

		# ── 일시정지 검증 ──
		if _pause_state == 0 and idx == 4:
			_pause_state = 1
			_pause_idx = idx
			_pause_total = int(_main.get_node("Score").total)
			_pause_clk = float(AudioClock.judged_ms())
			_press(KEY_ESCAPE)
			return
		if _pause_state == 1:
			_pause_frames += 1
			if _pause_frames < 90:
				return
			var drift := absf(float(AudioClock.judged_ms()) - _pause_clk)
			_expect(int(_main.get("_idx")) == _pause_idx,
				"일시정지 중 타일 정지 (%s)" % _main.get("_idx"))
			_expect(int(_main.get_node("Score").total) == _pause_total,
				"일시정지 중 판정 없음 (%d)" % _main.get_node("Score").total)
			_expect(bool(_main.get("_paused")), "일시정지 상태 플래그")
			_expect(drift < 15.0,
				"일시정지 중 클럭 동결 (드리프트 %.1fms — 믹스 청크 이내)" % drift)
			_pause_state = 2
			_press(KEY_ESCAPE)   # 재개
			return
		if idx >= _hit.size():
			_check_play()
			return
		var k := idx - 1
		if k < OFFSETS.size() and not _pressed.has(idx):
			var off: float = OFFSETS[k]
			if off < 900.0 and float(AudioClock.judged_ms()) >= _hit[idx] + off:
				_pressed[idx] = true
				_sent[idx] = [float(AudioClock.judged_ms()) - _hit[idx], Time.get_ticks_usec()]
				# 타일 2 는 F 키 — 얼불춤처럼 거의 모든 키가 판정키여야 한다(양손 교타)
				_press(KEY_F if idx == 2 else KEY_SPACE)
				# 2) 키 리피트: 같은 프레임에 echo 를 세 번 더 보낸다.
				#    걸러지지 않으면 idx 가 폭주한다.
				if not _echo_sent:
					_echo_sent = true
					for i in range(3):
						_press(KEY_SPACE, true)


func _check_play() -> void:
	var score: Score = _main.get_node("Score")
	var ds: Array = score.deltas

	# 하네스 정밀도 — 계획한 입력마다 (보낼 때 클럭 - 목표) + 디스패치 프레임 간격.
	# 판정 결과와 무관하게 하네스 쪽 값만으로 잰다.
	var imprecise := 0
	for tile in _sent:
		var off: float = OFFSETS[int(tile) - 1]
		var sent_off: float = float(_sent[tile][0])
		var gap: float = float(_dispatch_ms.get(tile, 0.0))
		if (sent_off - off) + gap >= HARNESS_BUDGET_MS:
			imprecise += 1
			_log.append("  SKIP   타일 %d 오프셋 %+.0f — 하네스 정밀도 %.1fms (폴링 %.1f + 디스패치 %.1f) ≥ %.0fms"
				% [tile, off, (sent_off - off) + gap, sent_off - off, gap, HARNESS_BUDGET_MS])

	# 부하와 무관하게 성립해야 하는 것(입력 경로): 입력 판정의 클럭은 어떤 송신의
	# '보낸 시각 ~ 디스패치 프레임' 사이에 있어야 한다. 순서가 아니라 절대 클럭으로 짝짓는다 —
	# 부하로 한 입력이 미스 기한을 넘겨 보내지면 감시자가 그 타일을 미스로 닫고 입력은 다음
	# 타일에 판정된다(CI 실측: +52 의도가 +85 에 보내져 다음 타일 -25). 그건 하네스 지연이지
	# 판정 경로 버그가 아니다. 반대로 판정이 캐시된 옛 클럭을 쓰면 어느 송신과도 안 맞는다.
	# 여유 15ms = 클럭이 믹스 청크 단위로 벽시계보다 앞서 가는 몫(실측 p99 +4~5ms)의 3배.
	var used := {}
	var unmatched := 0
	for jd in _inputs:
		var at: float = _hit[int(jd[0])] + float(jd[1])
		var hit := -1
		for tile in _sent:
			if used.has(tile):
				continue
			var c: float = _hit[int(tile)] + float(_sent[tile][0])
			if at >= c - 1.0 and at <= c + float(_dispatch_ms.get(tile, 0.0)) + 15.0:
				hit = int(tile)
				break
		if hit < 0:
			unmatched += 1
			_log.append("  FAIL   타일 %d 판정 %+.1f (클럭 %.1f) — 어느 송신~디스패치 구간에도 없다"
				% [int(jd[0]), float(jd[1]), at])
		else:
			used[hit] = true
	_expect(unmatched == 0 and _inputs.size() <= _sent.size(),
		"입력 판정 %d건이 전부 송신~디스패치 구간의 클럭 (송신 %d건)" % [_inputs.size(), _sent.size()])

	var intended: Array[float] = []
	for o in OFFSETS:
		if o < 900.0:
			intended.append(o)
	if imprecise > 0:
		# 순서·개수·등급은 '모든 입력이 제 띠를 겨냥했다'는 전제 위에서만 뜻이 있다.
		# (띠 경계 자체는 run_tests.gd t_judge_classify 가 순수 함수로 검사한다)
		_log.append("  SKIP 오프셋·판정 수·등급 분포 — 입력 %d건이 하네스 정밀도 %.0fms 를 넘었다(부하로 측정이 무효)"
			% [imprecise, HARNESS_BUDGET_MS])
	else:
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
		_expect(score.count_of(Judge.Verdict.TOO_LATE) == 1,
			"무입력 1건이 TOO_LATE (%d건)" % score.count_of(Judge.Verdict.TOO_LATE))
		_expect(score.count_of(Judge.Verdict.PERFECT) == 4,
			"의도 -10ms 네 번이 PERFECT (%d건)" % score.count_of(Judge.Verdict.PERFECT))
		_expect(score.count_of(Judge.Verdict.LATE_PERFECT) == 1,
			"+35ms -> LATE PERFECT (%d건)" % score.count_of(Judge.Verdict.LATE_PERFECT))
		_expect(score.count_of(Judge.Verdict.EARLY_PERFECT) == 1,
			"-35ms -> EARLY PERFECT (%d건)" % score.count_of(Judge.Verdict.EARLY_PERFECT))
		_expect(score.count_of(Judge.Verdict.VERY_LATE) == 1,
			"+62ms -> LATE! (%d건)" % score.count_of(Judge.Verdict.VERY_LATE))
		_expect(score.count_of(Judge.Verdict.VERY_EARLY) == 1,
			"-62ms -> EARLY! (%d건)" % score.count_of(Judge.Verdict.VERY_EARLY))

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
	_expect(_pause_state == 2, "일시정지 검증이 실제로 수행됨")

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
