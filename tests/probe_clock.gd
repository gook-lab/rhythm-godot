extends SceneTree

## 헤드리스에서 오디오 클럭이 실제로 흘러가는지 재는 프로브.
##   godot --headless --script res://tests/probe_clock.gd
##
## 왜 필요한가:
##   헤드리스는 Dummy 오디오 드라이버를 쓴다. get_playback_position() 이
##   전혀 안 움직이면 이 게임은 CI 자동 테스트가 원천적으로 불가능하고,
##   모든 통합 검증을 손으로 해야 한다. 그 사실을 지금 알아야 한다.
##
## 판정:
##   - 클럭이 벽시계와 비슷한 속도로 흐르면  -> 헤드리스 통합테스트 가능
##   - 0 에 머물거나 튀면                    -> 손으로만 검증 가능

const SECONDS := 3.0


func _init() -> void:
	var stream: AudioStream = load("res://assets/click_120.wav")
	if stream == null:
		print("click_120.wav 없음 — python3 tools/make_click.py 120 60 먼저 실행")
		quit(1)
		return

	# 헤드리스 테스트가 실제 스피커로 소리를 내면 안 된다.
	# 버스 음소거는 믹싱을 멈추지 않으므로 get_playback_position() 은 그대로 흐른다.
	AudioServer.set_bus_mute(0, true)

	var player := AudioStreamPlayer.new()
	root.add_child(player)
	# add_child 직후엔 아직 트리에 들어가기 전이라 play() 가 실패한다
	# ("Playback can only happen when a node is inside the scene tree").
	# 한 프레임 넘기고 재생한다.
	await process_frame
	player.stream = stream
	player.play()

	print("드라이버: %s   믹스레이트: %d" % [AudioServer.get_driver_name(), AudioServer.get_mix_rate()])
	print("출력지연: %.2f ms" % (AudioServer.get_output_latency() * 1000.0))
	print("")
	print("  벽시계(ms)   오디오클럭(ms)   차이(ms)")

	var t0 := Time.get_ticks_usec()
	var samples: Array[float] = []
	var samples1: Array[float] = []  # 1항 변형 (get_playback_position 만)
	var last_audio := -1.0
	var backward := 0

	while true:
		await process_frame
		var wall := float(Time.get_ticks_usec() - t0) / 1000.0
		if wall > SECONDS * 1000.0:
			break
		var pos := player.get_playback_position()
		var since := AudioServer.get_time_since_last_mix()
		var lat := AudioServer.get_output_latency()
		var audio := (pos + since - lat) * 1000.0
		if audio < last_audio:
			backward += 1
		last_audio = audio
		samples.append(audio - wall)
		samples1.append(pos * 1000.0 - wall)
		if samples.size() % 30 == 0:
			print("  %10.1f   %12.1f   %+8.2f" % [wall, audio, audio - wall])

	var n := samples.size()
	if n < 10:
		print("\n표본이 너무 적다 (%d)" % n)
		quit(1)
		return

	# 드리프트(추세)와 지터(추세를 뺀 잔차)를 갈라서 본다.
	# 이 게임이 죽는 건 지연이 크기 때문이 아니라 '흔들릴' 때다.
	# 드리프트는 클럭 속도가 틀린 것이고, 지터는 순간순간 튀는 것이다.
	# 드리프트는 캘리브레이션으로도 못 잡는다(시간이 갈수록 벌어지므로).
	var mean_x := 0.0
	var mean_y := 0.0
	for i in range(n):
		mean_x += float(i)
		mean_y += samples[i]
	mean_x /= n
	mean_y /= n
	var num := 0.0
	var den := 0.0
	for i in range(n):
		num += (float(i) - mean_x) * (samples[i] - mean_y)
		den += (float(i) - mean_x) * (float(i) - mean_x)
	var slope := 0.0 if is_zero_approx(den) else num / den   # ms 차이 / 프레임
	var jitter := 0.0
	for i in range(n):
		var fit := mean_y + slope * (float(i) - mean_x)
		jitter += (samples[i] - fit) * (samples[i] - fit)
	jitter = sqrt(jitter / n)
	var span_ms := samples[n - 1] - samples[0]
	var drift_pct := 100.0 * span_ms / (SECONDS * 1000.0)

	print("\n표본 %d개  (%.1f초)" % [n, SECONDS])
	print("  오디오클럭 - 벽시계  평균 %+.2f ms" % mean_y)
	print("  드리프트  구간 전체 %+.1f ms  =  속도 오차 %+.2f%%" % [span_ms, drift_pct])
	print("  지터      추세 제거 후 표준편차 %.2f ms" % jitter)
	print("  역행 횟수 %d" % backward)

	var moved := last_audio > 500.0
	print("\n판정:")
	if not moved:
		print("  FAIL  클럭이 안 흐른다 (마지막 %.1f ms). 통합테스트 불가." % last_audio)
	elif absf(drift_pct) > 1.0:
		print("  WARN  클럭이 흐르지만 벽시계 대비 %.2f%% 로 밀린다." % drift_pct)
		print("        드리프트는 캘리브레이션으로 못 잡는다 — 시간이 갈수록 벌어진다.")
		print("        Dummy 드라이버의 알려진 성질이면 무해하지만,")
		print("        실제 드라이버에서 이 값이 나오면 그건 진짜 문제다.")
	elif jitter > 15.0:
		print("  WARN  지터 %.1f ms. 성공기준 3(산포 <15ms)을 이 환경에선 못 맞춘다." % jitter)
	else:
		print("  PASS  드리프트 %.2f%%, 지터 %.1f ms." % [drift_pct, jitter])

	# ---- 3항 vs 1항: 크로스모델 논쟁을 숫자로 끝낸다 -------------------
	# 독립 리뷰어 주장: "3항은 과잉이다. get_playback_position() 만으로 시작하고
	#                   산포가 나쁘면 그때 복잡도를 추가하라."
	# 반박: "그 항은 변덕에 대한 보험이 아니라 상시 존재하는 계단 현상을 메우는 항이다.
	#        get_playback_position() 은 오디오 스레드가 믹싱할 때만 갱신되므로
	#        그 사이엔 같은 값을 돌려주고, 클럭이 믹스 버퍼만큼의 계단으로 뛴다."
	# 하네스가 있으니 의견 대신 재서 끝낸다.
	var jitter1 := _jitter_of(samples1)
	print("\n--- 3항 vs 1항 (같은 표본, 추세 제거 후 지터) ---")
	print("  %-34s %8.2f ms" % ["3항  pos + since_mix - latency", jitter])
	print("  %-34s %8.2f ms" % ["1항  pos 만", jitter1])
	var gain := jitter1 - jitter
	if gain > 0.5:
		print("  -> 3항이 지터를 %.2f ms 줄인다. 그 항은 값을 한다." % gain)
	elif gain < -0.5:
		print("  -> 1항이 오히려 낫다 (%.2f ms). 3항을 재검토할 것." % -gain)
	else:
		print("  -> 이 기계에선 차이가 %.2f ms 로 의미 없다." % absf(gain))
		print("     (믹스 버퍼가 작아서일 수 있다. 다른 기계에선 다시 재볼 것.)")

	print("\n  주의: 드라이버가 Dummy 면 이 수치는 실제 하드웨어와 무관하다.")
	print("        진짜 손맛 측정은 실제 오디오 드라이버로 할 것:")
	print("          godot --headless --audio-driver CoreAudio --script res://tests/probe_clock.gd")

	player.stop()
	quit(0)


## 추세(선형 드리프트)를 제거한 뒤의 표준편차. 드리프트와 지터를 갈라 보려고 쓴다.
static func _jitter_of(s: Array[float]) -> float:
	var n := s.size()
	if n < 3:
		return 0.0
	var mx := 0.0
	var my := 0.0
	for i in range(n):
		mx += float(i)
		my += s[i]
	mx /= n
	my /= n
	var num := 0.0
	var den := 0.0
	for i in range(n):
		num += (float(i) - mx) * (s[i] - my)
		den += (float(i) - mx) * (float(i) - mx)
	var sl := 0.0 if is_zero_approx(den) else num / den
	var acc := 0.0
	for i in range(n):
		var fit := my + sl * (float(i) - mx)
		acc += (s[i] - fit) * (s[i] - fit)
	return sqrt(acc / n)
