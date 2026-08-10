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

## 자동플레이 앞보기 상한(ms). Judge 의 Perfect 창(±30ms) 절반 아래로 둔다 —
## 보정이 판정을 흔들면 안 된다. 144fps 의 정상 보정치는 10.4ms 라 안 걸린다.
const MAX_LOOKAHEAD_MS := 15.0

## 이보다 긴 프레임은 '히치'로 센다. 144fps 정상 프레임이 6.9ms 이므로
## 25ms 는 3배 이상 밀린 것 — 머신 부하지 게임 문제가 아니다.
const HITCH_MS := 25.0

## 기본 상한. 긴 곡은 --max-sec= 로 늘린다 (mureka 곡 149초).
var max_seconds := 95.0

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
var _hitches := 0                     # delta 가 크게 튄 프레임 수 (미스의 알리바이)


func _ready() -> void:
	# !! 헤드리스 테스트가 실제 스피커로 소리를 내면 안 된다.
	#    --audio-driver CoreAudio 는 진짜 오디오 장치를 쓰기 때문에
	#    그냥 두면 테스트를 돌릴 때마다 곡이 흘러나온다.
	#    버스 음소거는 믹싱을 멈추지 않으므로 클럭 측정에 영향이 없다
	#    (실측: 지터 1.14ms -> 0.95ms, 실행 간 편차 범위 안).
	AudioServer.set_bus_mute(0, true)

	var args := OS.get_cmdline_user_args()
	autoplay = args.has("--autoplay")
	var chart_path := ""
	for a in args:
		if a.begins_with("--miss-every="):
			miss_every = int(a.split("=")[1])
		elif a.begins_with("--chart="):
			chart_path = a.split("=")[1]
		elif a.begins_with("--max-sec="):
			max_seconds = float(a.split("=")[1])
	var scene: PackedScene = load("res://scenes/Main.tscn")
	_main = scene.instantiate()
	if chart_path != "":
		# add_child 전에 바꿔야 _ready 가 이 차트로 초기화된다 (InputRunner 와 같은 패턴)
		_main.set("chart", load(chart_path))
	add_child(_main)
	_t0 = Time.get_ticks_usec()
	var chart: Chart = _main.get("chart")
	print("모드: %s%s" % ["자동플레이" if autoplay else "무입력",
		("  (%d 타일마다 일부러 놓침)" % miss_every) if miss_every > 0 else ""])
	print("드라이버 %s · 차트 %s · 타일 %d · 오디오 %.1fs"
		% [AudioServer.get_driver_name(), chart.title,
		   chart.angles.size(), chart.audio.get_length()])
	print("  경과(s)  클럭(ms)  타일  판정  역행")


func _process(delta: float) -> void:
	_frames += 1
	# 프레임이 크게 밀린 순간. 그 사이에 히트타임이 들어오면 자동플레이는
	# 아무리 정확해도 늦게 누를 수밖에 없다 — 미스 허용치의 근거가 된다.
	if delta > HITCH_MS / 1000.0:
		_hitches += 1
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

	# 자동 플레이: 해당 타일의 시각에 맞춰 스페이스를 한 번 보낸다.
	#
	# '지금 시각이 히트타임을 넘었으면' 누르면 안 된다. 두 가지가 겹쳐 늦어진다:
	#   1. 프레임 양자화 — 평균 +½프레임
	#   2. parse_input_event 는 큐에 쌓여 '다음 프레임'에 배달된다 — +1프레임
	# 합쳐서 평균 +1.5프레임. 실측 145fps 에서 정확히 +10.4ms 였고, 헤드리스를
	# 32000fps 로 돌리면 +0.3ms 로 사라져 프레임 탓임이 확인됐다.
	# 이건 하네스의 지연이지 게임의 지연이 아니다 — 실제 키 입력은 OS 가
	# 발생 시각을 찍어 준다. 그대로 두면 촘촘한 곡에서 판정창이 좁아질 때
	# '자동플레이인데 정확도 95%' 라는 거짓 실패가 나서 진짜 회귀를 가린다.
	#
	# 보정: 프레임 k 에서 C_k + aD >= ht 일 때 누르면 배달은 C_k+D 이므로
	# 평균 오차가 (1.5-a)D 가 된다. a=0 이면 +1.5D(원래), a=1.5 면 0 이다.
	# 실측으로 확인했다: a=0 -> +10.4ms · a=1 -> +3.5ms · 145fps(D=6.9ms).
	if autoplay and AudioClock.is_warm():
		var ht: PackedFloat32Array = _main.get("_hit_times")
		var ji: int = _main.get("_idx")
		# 앞보기는 상한을 둔다. 프레임이 한 번 크게 튀면(부하·로딩) delta 가
		# 커지면서 그만큼 '일찍' 눌러 버려 멀쩡한 타일이 미스가 된다 —
		# 실측: 5개를 연달아 돌려 머신이 밀렸을 때 같은 채보가 P/100% 에서
		# D/64.7%(미스 43) 으로 무너졌고, 단독 실행에서는 재현되지 않았다.
		# 히치 뒤에는 어차피 정확히 맞출 수 없으니, 조금 늦는 쪽이 옳다.
		var look: float = minf(delta * 1500.0, MAX_LOOKAHEAD_MS)
		if ji < ht.size() and float(AudioClock.judged_ms()) + look >= ht[ji]:
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
		# 끝난 뒤에는 클럭을 읽지 않는다 — 정지 상태의 값은 의미가 없다.
		var warm: bool = AudioClock.is_warm() and not fin
		var clk: float = AudioClock.now_ms() if warm else -1.0
		print("  %7d  %8.0f  %4d  %4d  %d" % [sec, clk, idx,
			int(_main.get_node("Score").total), int(AudioClock.clamp_hits)])

	if fin or wall > max_seconds:
		_finish(fin, wall)


## 채보의 타일 경로 자체가 얼마나 헤매는가. 카메라 배수의 기준선이 된다.
func _tile_path_waste() -> float:
	# get() 결과를 타입 지정 변수에 바로 넣지 않는다. 종료 중이거나 Main 이
	# 유효하지 않으면 Nil 이 와서 'Nil 을 PackedVector2Array 에 대입' 으로 죽는다 —
	# SIGTERM 으로 스위트가 끊겼을 때 같은 모양의 에러가 실제로 났다.
	var raw = _main.get("_positions") if is_instance_valid(_main) else null
	if not (raw is PackedVector2Array):
		return 1.0
	var pos: PackedVector2Array = raw
	if pos.size() < 2:
		return 1.0
	var d := 0.0
	for i in range(1, pos.size()):
		d += pos[i - 1].distance_to(pos[i])
	return d / maxf(pos[0].distance_to(pos[pos.size() - 1]), 1.0)


func _finish(reached_end: bool, wall: float) -> void:
	set_process(false)
	var score: Score = _main.get_node("Score")
	var chart: Chart = _main.get("chart")
	# 고스트(자동 통과) 타일은 판정이 없다 — 완주 기대치에서 뺀다.
	var n := chart.angles.size() - 1 - chart.ghost_tiles.size()
	print("\n결과")
	print("  %.1fs · %d 프레임 (%.0f fps)" % [wall, _frames, _frames / maxf(wall, 0.001)])
	print("  도달 타일 %d / %d · 판정 %d 건 · 입력 %d 회" % [_max_idx, n, score.total, _pressed])
	if autoplay:
		var st2: Dictionary = score.delta_stats()
		print("  랭크 %s · 정확도 %.2f%% · 최대콤보 %d · 표본 %d 평균 %+.1fms σ %.1fms"
			% [score.rank(), score.accuracy(), score.max_combo,
			   st2.n, st2.mean, st2.sd])
	print("  체력 %.1f / %.0f · started %s" % [score.health, Score.HEALTH_MAX, score.started])
	print("  프레임 히치 %d회 (>%.0fms)" % [_hitches, HITCH_MS])
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
		print("  FAIL %.0fs 안에 곡 종료 미도달" % max_seconds); fails += 1
	if autoplay and miss_every == 0 and score.total > 0:
		# 정확한 시각에 눌렀으니 프레임 granularity(~7ms) 안에서 전부 Perfect 여야 한다.
		if score.accuracy() < 99.0:
			print("  FAIL 자동플레이인데 정확도가 %.2f%% 다" % score.accuracy()); fails += 1
		# 미스는 히치 수까지만 봐준다. 정확한 시각에 눌러도 프레임이 통째로
		# 밀린 구간에서는 늦을 수밖에 없다(실측: 5개 연속 실행으로 머신이
		# 밀리면 524타일 곡에서 1건). 0 으로 못 박으면 부하에 따라 깜빡이는
		# 테스트가 되고, 깜빡이는 테스트는 곧 무시당한다.
		# 반대로 히치가 없는데 미스가 나면 그건 진짜다.
		var misses := score.count_of(Judge.Verdict.TOO_LATE)
		if misses > _hitches:
			print("  FAIL 자동플레이인데 미스가 %d 건 (히치 %d 프레임으로 설명 안 됨)"
				% [misses, _hitches]); fails += 1
	# 실패는 체력으로 판정한다. 그리고 한 번도 안 누른 플레이어는 체력이 안 깎인다
	# (Score.started) — 보고만 있는 걸 실패로 치면 안 되기 때문이다.
	# 따라서 무입력은 '전부 미스지만 완주' 가 정상이다.
	if not autoplay:
		if score.total < n:
			print("  FAIL 무입력인데 완주 못 함 (판정 %d < 타일 %d) — started 가드가 깨졌나?"
				% [score.total, n]); fails += 1
		if score.health < Score.HEALTH_MAX - 0.01:
			print("  FAIL 무입력인데 체력이 깎였다 (%.1f)" % score.health); fails += 1
	elif miss_every == 0:
		if score.total < n:
			print("  FAIL 자동플레이인데 판정 %d < 타일 %d" % [score.total, n]); fails += 1
		if score.health < Score.HEALTH_MAX - 0.01:
			print("  FAIL 전부 정확인데 체력이 깎였다 (%.1f)" % score.health); fails += 1
	# 역행은 구조적으로 일어난다. 횟수가 아니라 크기로 본다.
	# 한 청크(~6ms)를 크게 넘으면 그건 다른 문제다.
	# 카메라 경로가 불연속이면 프레임당 이동량이 중앙값 대비 크게 튄다.
	# 타일 사이 직선 lerp 를 쓰면 p99 가 25px(중앙 2px) 까지 올라갔다.
	if p99 > maxf(med * 4.0 + 1.0, 6.0):
		print("  FAIL 카메라 p99 %.1fpx 가 중앙 %.1fpx 대비 과도하다 — 경로가 불연속인가?"
			% [p99, med]); fails += 1
	# '한 프레임 최대 이동'으로 가드하면 안 된다. 그건 카메라 설계가 아니라
	# 프레임 시간 안정성을 재는 값이라, OS 히치 한 번에 터진다.
	# 실측: 같은 코드로 4회 돌려 최대값이 5.2 / 10.0 / 17.5 / 36.3px 로 흩어졌고
	# p99 는 3.0~3.3px 로 일관됐다.
	# 진짜 불연속이면 '여러 프레임'에 걸쳐 나타난다 — 그 비율로 본다.
	var spikes := 0
	for st in _cam_steps:
		if st > med * 8.0 + 2.0:
			spikes += 1
	var spike_pct := 100.0 * spikes / maxf(float(_cam_steps.size()), 1.0)
	print("  카메라 스파이크 %d프레임 (%.2f%%)" % [spikes, spike_pct])
	if spike_pct > 0.3:
		print("  FAIL 카메라 스파이크가 %.2f%% — 산발적 히치가 아니라 구조적이다"
			% spike_pct); fails += 1
	# 카메라가 경로를 '그대로 쫓는지'는 절대 배수로 잴 수 없다. 배수에는
	# 카메라의 행동과 채보 경로의 모양이 같이 들어 있기 때문이다 — 채보가
	# 원래 구불구불하면 카메라가 아무리 부드러워도 절대값은 크게 나온다.
	# 실측(2026-08-10): mureka_06 은 타일 경로 자체가 22.5x 인데 카메라는 8.5x 로
	# 줄여 놓고도 절대 기준 3.0 에 걸렸다. 창을 ±2에서 ±12로 넓혀도 9.4->6.0 에
	# 그치고 행성만 402px 멀어졌다 — 카메라의 문제가 아니라는 뜻이다.
	#
	# 그래서 '감쇠비'로 잰다: 카메라 배수 / 타일 경로 배수.
	# 순간 위치를 그대로 쫓으면 1.0 근처(혹은 그 이상)가 되고, 평활하면 내려간다.
	# 실측 감쇠비 — 직선 0.89 · song140 0.69 · mureka_01 0.55 · mureka_06 0.38.
	# 기준선은 1.0 — '카메라가 타일 경로보다 더 많이 움직이면 안 된다'.
	# 감쇠비를 더 조이면 안 된다. 평활이 얼마나 먹히는지는 경로의 '파장'에
	# 달려 있어서(창 ±3보다 긴 파장의 배회는 못 줄인다) 채보마다 정당하게
	# 달라진다 — 실측 감쇠비 0.38(잔지그재그) ~ 0.77(완만한 배회) 전부 정상이다.
	# 반면 회귀(순간 위치 추적)는 공전 원까지 얹혀 타일 경로보다 커진다:
	# 당시 5.9~8.2x 는 같은 채보의 타일 경로 2.6~3.2x 위였으니 감쇠비 1.8~3.2 다.
	# 날카로운 평활 지표는 따로 있다 — 튐배수와 카메라 스파이크.
	var raw_waste := _tile_path_waste()
	if raw_waste > 2.0:
		var atten := waste / raw_waste
		if atten > 1.0:
			print("  FAIL 카메라가 타일 경로보다 멀리 돈다 — 감쇠비 %.2f (타일경로 %.1fx -> 카메라 %.1fx)"
				% [atten, raw_waste, waste]); fails += 1
	elif waste > 3.0:
		# 곧은 경로인데 카메라만 크게 돈다 = 확실히 카메라 문제다.
		print("  FAIL 카메라 타깃 낭비 %.2fx — 곧은 경로(%.1fx)인데 카메라가 돈다"
			% [waste, raw_waste]); fails += 1
	# 실제로 보이는 흔들림. 미스마다 흔들던 시절엔 18.01x 였다.
	# 흔들림은 타깃 위에 얹히는 것이므로 타깃 대비로 본다.
	if seen_waste > waste * 1.35 + 0.5:
		print("  FAIL 화면 흔들림 낭비 %.2fx — 타깃 %.2fx 대비 과하다"
			% [seen_waste, waste]); fails += 1

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
