extends Node

## 헤드리스 통합 스모크 테스트.
##   godot --headless --audio-driver CoreAudio res://tests/SmokeScene.tscn
##
## !! --script 로는 못 돌린다. 그 모드에선 autoload 가 등록되지 않아서
##    AudioClock 식별자를 못 찾고, Main.gd 자체가 컴파일에 실패한다.
##    그래서 '씬'으로 만들어 정상 실행 경로에 태운다.
##
## !! --audio-driver CoreAudio 를 반드시 붙인다.
##    기본 Dummy 는 클럭이 벽시계 대비 -4% 로 드리프트해서 결론이 무효가 된다.
##
## 단위 테스트가 못 잡는 것을 본다:
##   감시자가 무입력 Miss 로 실제 전진하는가 · 곡 종료에 도달하는가 · 클럭 역행 크기

const MAX_SECONDS := 95.0

## 자동 플레이. 각 타일의 정확한 시각에 스페이스를 눌러 판정 체인 전체를 검증한다.
## 무입력만 돌리면 '전부 미스' 경로만 보게 되고, 콤보·정확도·랭크·흔들림이
## 한 번도 안 불린다.
##   godot --headless --audio-driver CoreAudio res://tests/SmokeScene.tscn -- --autoplay
## 일부러 놓칠 타일 간격(0 이면 전부 친다). 콤보 끊김/흔들림을 보려면 쓴다.
var autoplay := false
var miss_every := 0
var _pressed := 0

var _main: Node
var _t0 := 0
var _frames := 0
var _max_idx := 0
var _last_sec := -1
var _pinned := 0     # 공전 진행률이 1.0 에 붙어 있던 프레임 수
var _moving := 0
var _cam_prev := Vector2.INF
var _cam_steps: Array[float] = []   # 프레임당 카메라 타깃 이동량(px)
var _cam_path := 0.0                # 카메라가 실제로 지나간 총 거리
var _cam_first := Vector2.INF
var _cam_last := Vector2.ZERO
var _far := 0.0
var _off_max := 0.0
var _seen_prev := Vector2.INF
var _seen_first := Vector2.INF
var _seen_last := Vector2.ZERO
var _seen_path := 0.0
var _shaking := 0                     # 카메라와 도는 행성 사이 최대 거리


func _ready() -> void:
	# !! 헤드리스 테스트가 실제 스피커로 소리를 내면 안 된다.
	#    --audio-driver CoreAudio 는 진짜 오디오 장치를 쓰기 때문에
	#    그냥 두면 테스트를 돌릴 때마다 곡이 흘러나온다.
	#    버스 음소거는 믹싱을 멈추지 않으므로 클럭 측정에 영향이 없다
	#    (실측: 지터 1.14ms -> 0.95ms, 실행 간 편차 범위 안).
	AudioServer.set_bus_mute(0, true)

	var args := OS.get_cmdline_user_args()
	autoplay = args.has("--autoplay")
	for a in args:
		if a.begins_with("--miss-every="):
			miss_every = int(a.split("=")[1])
	var scene: PackedScene = load("res://scenes/Main.tscn")
	_main = scene.instantiate()
	add_child(_main)
	_t0 = Time.get_ticks_usec()
	var chart: Chart = _main.get("chart")
	print("모드: %s%s" % ["자동플레이" if autoplay else "무입력",
		("  (%d 타일마다 일부러 놓침)" % miss_every) if miss_every > 0 else ""])
	print("드라이버 %s · 차트 %s · 타일 %d · 오디오 %.1fs"
		% [AudioServer.get_driver_name(), chart.title,
		   chart.angles.size(), chart.audio.get_length()])
	print("  경과(s)  클럭(ms)  타일  판정  역행")


func _process(_d: float) -> void:
	_frames += 1
	var wall := float(Time.get_ticks_usec() - _t0) / 1_000_000.0
	var idx: int = _main.get("_idx")
	# 렌더가 얼어 있는지 잰다. 렌더 커서를 판정 커서에 묶어두면
	# 매 타일 miss_ms 만큼 u=1.0 에 붙어 있게 된다(0.5박@120bpm 이면 시간의 44%).
	# 카메라 타깃의 프레임간 이동량. 경로가 불연속이면 여기 스파이크가 뜬다.
	# 연속성은 '타깃'(position)으로 잰다 — 경로가 끊기는지의 문제다.
	# 흔들림은 '실제로 보이는 것'(position+offset)으로 잰다 — 화면이 떨리는지의 문제다.
	# 둘을 한 지표로 섞으면 정당한 흔들림이 연속성 실패로 오인된다.
	var camnode: Camera2D = _main.get_node("World/Camera2D")
	var cam: Vector2 = camnode.position
	var seen: Vector2 = camnode.position + camnode.offset
	if _seen_prev != Vector2.INF:
		_seen_path += _seen_prev.distance_to(seen)
	else:
		_seen_first = seen
	_seen_prev = seen
	_seen_last = seen
	_off_max = maxf(_off_max, camnode.offset.length())
	if camnode.offset.length() > 0.5:
		_shaking += 1
	if _cam_prev != Vector2.INF:
		var st := _cam_prev.distance_to(cam)
		_cam_steps.append(st)
		_cam_path += st
	else:
		_cam_first = cam
	_cam_prev = cam
	_cam_last = cam
	# 액션이 화면 밖으로 나가는지. 카메라가 행성을 놓치면 이 값이 커진다.
	var pair: Node2D = _main.get_node("World/PlanetPair")
	_far = maxf(_far, cam.distance_to(pair.get_node("PlanetA").position))
	_far = maxf(_far, cam.distance_to(pair.get_node("PlanetB").position))

	# 자동 플레이: 해당 타일의 시각이 지나면 스페이스를 한 번 보낸다.
	if autoplay and AudioClock.is_warm():
		var ht: PackedFloat32Array = _main.get("_hit_times")
		var ji: int = _main.get("_idx")
		if ji < ht.size() and float(AudioClock.judged_ms()) >= ht[ji]:
			var skip := miss_every > 0 and ji % miss_every == 0
			if not skip:
				var ev := InputEventKey.new()
				ev.keycode = KEY_SPACE
				ev.physical_keycode = KEY_SPACE
				ev.pressed = true
				Input.parse_input_event(ev)
				_pressed += 1

	var u: float = _main.get("_last_u")
	if u >= 0.999:
		_pinned += 1
	else:
		_moving += 1
	var fin: bool = _main.get("_finished")
	_max_idx = maxi(_max_idx, idx)

	var sec := int(wall)
	if sec != _last_sec and sec % 5 == 0 and sec > 0:
		_last_sec = sec
		var warm: bool = AudioClock.is_warm()
		var clk: float = AudioClock.now_ms() if warm else -1.0
		print("  %7d  %8.0f  %4d  %4d  %d" % [sec, clk, idx,
			int(_main.get_node("Score").total), int(AudioClock.clamp_hits)])

	if fin or wall > MAX_SECONDS:
		_finish(fin, wall)


func _finish(reached_end: bool, wall: float) -> void:
	set_process(false)
	var score: Score = _main.get_node("Score")
	var chart: Chart = _main.get("chart")
	var n := chart.angles.size() - 1
	print("\n결과")
	print("  %.1fs · %d 프레임 (%.0f fps)" % [wall, _frames, _frames / maxf(wall, 0.001)])
	print("  도달 타일 %d / %d · 판정 %d 건 · 입력 %d 회" % [_max_idx, n, score.total, _pressed])
	if autoplay:
		var st2: Dictionary = score.delta_stats()
		print("  랭크 %s · 정확도 %.2f%% · 최대콤보 %d · 표본 %d 평균 %+.1fms σ %.1fms"
			% [score.rank(), score.accuracy(), score.max_combo,
			   st2.n, st2.mean, st2.sd])
	print("  클럭 역행 %d회 · 최대 %.3fms" % [int(AudioClock.clamp_hits),
		float(AudioClock.max_backstep_ms)])
	# 카메라 부드러움: 프레임당 이동량의 중앙값 대비 최대값.
	# 등속이면 1 에 가깝고, 불연속으로 튀면 크게 벌어진다.
	var steps := _cam_steps.duplicate()
	steps.sort()
	var med: float = steps[steps.size() / 2] if steps.size() > 0 else 0.0
	var mx: float = steps[steps.size() - 1] if steps.size() > 0 else 0.0
	var p99: float = steps[int(steps.size() * 0.99)] if steps.size() > 0 else 0.0
	# 경로 낭비 배수 = 실제 지나간 거리 / 순 이동거리.
	# 1 에 가까우면 곧게 따라간다. 카메라가 원을 그리면 크게 뛴다.
	var net := _cam_first.distance_to(_cam_last)
	var waste := _cam_path / maxf(net, 1.0)
	var seen_net := _seen_first.distance_to(_seen_last)
	var seen_waste := _seen_path / maxf(seen_net, 1.0)
	print("  카메라 프레임이동 중앙 %.2fpx · p99 %.2fpx · 최대 %.2fpx · 튐배수 %.1fx"
		% [med, p99, mx, mx / maxf(med, 0.001)])
	print("  타깃 경로 낭비 %.2fx · 실제로 보이는 낭비 %.2fx · 행성까지 최대 %.0fpx"
		% [waste, seen_waste, _far])
	print("  흔들림(offset) 최대 %.1fpx · 흔들리는 프레임 %.1f%% (%d)"
		% [_off_max, 100.0 * _shaking / maxf(float(_frames), 1.0), _shaking])

	var pin_pct := 100.0 * _pinned / maxf(float(_pinned + _moving), 1.0)
	print("  공전 정지 프레임 %.1f%% (%d / %d)" % [pin_pct, _pinned, _pinned + _moving])

	var fails := 0
	if _max_idx < 2:
		print("  FAIL 감시자가 타일을 전진시키지 못했다 (idx %d)" % _max_idx); fails += 1
	if not reached_end:
		print("  FAIL %.0fs 안에 곡 종료 미도달" % MAX_SECONDS); fails += 1
	if autoplay and miss_every == 0 and score.total > 0:
		# 정확한 시각에 눌렀으니 프레임 granularity(~7ms) 안에서 전부 Perfect 여야 한다.
		if score.accuracy() < 99.0:
			print("  FAIL 자동플레이인데 정확도가 %.2f%% 다" % score.accuracy()); fails += 1
		if score.count_of(Judge.Verdict.TOO_LATE) > 0:
			print("  FAIL 자동플레이인데 미스가 %d 건"
				% score.count_of(Judge.Verdict.TOO_LATE)); fails += 1
	if score.total < n:
		print("  FAIL 판정 수(%d)가 타일 수(%d)보다 적다" % [score.total, n]); fails += 1
	# 역행은 구조적으로 일어난다. 횟수가 아니라 크기로 본다.
	# 한 청크(~6ms)를 크게 넘으면 그건 다른 문제다.
	# 카메라 경로가 불연속이면 프레임당 이동량이 중앙값 대비 크게 튄다.
	# 타일 사이 직선 lerp 를 쓰면 p99 가 25px(중앙 2px) 까지 올라갔다.
	if p99 > maxf(med * 4.0 + 1.0, 6.0):
		print("  FAIL 카메라 p99 %.1fpx 가 중앙 %.1fpx 대비 과도하다 — 경로가 불연속인가?"
			% [p99, med]); fails += 1
	if mx > 20.0:
		print("  FAIL 카메라가 한 프레임에 %.1fpx 튀었다" % mx); fails += 1
	# 흔들림. 순간 위치를 쫓으면 경로의 지그재그를 그대로 따라가 5.9~8.2x 가 된다.
	# 타깃이 지그재그를 그대로 쫓는지 (순간 위치 추적이면 5.9~8.2x)
	if waste > 3.0:
		print("  FAIL 카메라 타깃 낭비 %.2fx — 지그재그를 그대로 쫓고 있나?"
			% waste); fails += 1
	# 실제로 보이는 흔들림. 미스마다 흔들던 시절엔 18.01x 였다.
	if seen_waste > 4.0:
		print("  FAIL 화면 흔들림 낭비 %.2fx — 흔들림이 과하다" % seen_waste); fails += 1

	# 렌더 커서를 판정 커서에 묶으면 여기가 20~60% 로 뛴다.
	if pin_pct > 8.0:
		print("  FAIL 공전이 %.1f%% 의 프레임에서 멈춰 있다 — 렌더 커서가 판정 커서에 묶였나?"
			% pin_pct); fails += 1
	# 관측 분포(10회): 5.0 5.0 5.1 5.3 5.7 5.8 6.0 6.0 5.3 11.3 ms.
	# 대부분 한 믹스 청크(~6ms)인데 가끔 두 청크가 겹친다. 15 로 잡아야 안 흔들린다.
	if float(AudioClock.max_backstep_ms) > 15.0:
		print("  FAIL 클럭 역행이 %.1fms — 두 청크로도 설명 안 되는 크기"
			% float(AudioClock.max_backstep_ms)); fails += 1
	print("  %s" % ("PASS" if fails == 0 else "FAILED %d" % fails))
	get_tree().quit(fails)
