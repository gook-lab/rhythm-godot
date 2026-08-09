extends SceneTree

## "소리가 안 난다"를 진단하는 프로브. 실제 스피커로 소리를 낸다.
##   godot --audio-driver CoreAudio --script res://tests/probe_audio.gd -- --chart=res://charts/mureka_07.tres
##
## probe_clock.gd 와 정반대다. 저건 버스를 음소거하고 '클럭이 흐르는지'만 보고,
## 이건 음소거하지 않고 '소리가 실제로 나가는지'를 본다.
##
## 소리가 안 날 때 용의자는 셋이고, 이 프로브가 셋을 갈라낸다:
##   1. 스트림이 비었다        -> 길이 0 · 임포트/경로 문제
##   2. 재생이 안 된다         -> playing false · 재생 위치 안 흐름
##   3. 재생은 되는데 안 들린다 -> 아래 값이 다 정상 -> OS 볼륨/출력장치 문제
##
## 마지막 경우가 제일 헷갈린다. 엔진은 아무 잘못이 없어서 로그에 아무것도 안 남는다.

const SECONDS := 5.0


func _init() -> void:
	var chart_path := "res://charts/mureka_07.tres"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--chart="):
			chart_path = a.split("=")[1]

	var chart: Chart = load(chart_path)
	if chart == null:
		print("FAIL 차트 로드 실패: %s" % chart_path)
		quit(1)
		return
	print("차트 %s  (%s)" % [chart_path, chart.describe()])

	# ── 용의자 1: 스트림 ──────────────────────────────────────
	if chart.audio == null:
		print("FAIL chart.audio 가 null — .tres 의 오디오 경로/임포트를 봐라")
		quit(1)
		return
	print("스트림 %s · 길이 %.2fs" % [chart.audio.get_class(), chart.audio.get_length()])
	if chart.audio.get_length() <= 0.0:
		print("FAIL 스트림 길이가 0 — wav 는 있는데 임포트가 비었다")
		quit(1)
		return

	# ── 출력 경로 상태 ────────────────────────────────────────
	print("드라이버 %s · 믹스레이트 %d · 출력지연 %.1fms"
		% [AudioServer.get_driver_name(), AudioServer.get_mix_rate(),
		   AudioServer.get_output_latency() * 1000.0])
	print("마스터 버스: 음소거 %s · 볼륨 %.1fdB · 출력장치 %s"
		% [AudioServer.is_bus_mute(0), AudioServer.get_bus_volume_db(0),
		   AudioServer.get_output_device()])
	if AudioServer.get_driver_name() == "Dummy":
		print("  !! Dummy 드라이버다 — 소리가 안 나는 게 정상이다."
			+ " --audio-driver CoreAudio 를 붙여라")

	# ── 용의자 2: 재생 ────────────────────────────────────────
	var player := AudioStreamPlayer.new()
	root.add_child(player)
	# add_child 직후엔 아직 트리 밖이라 play() 가 실패한다(probe_clock 과 같은 함정).
	await process_frame
	player.stream = chart.audio
	player.play()

	print("\n  경과(s)   재생위치(s)  playing   진폭추정")
	var t0 := Time.get_ticks_usec()
	var moved := 0
	var last_pos := -1.0
	while float(Time.get_ticks_usec() - t0) / 1e6 < SECONDS:
		await process_frame
		var wall := float(Time.get_ticks_usec() - t0) / 1e6
		var pos := player.get_playback_position()
		if pos > last_pos + 0.0001:
			moved += 1
		last_pos = pos
		if int(wall * 2.0) != int((wall - 0.02) * 2.0):   # 0.5초마다
			# 버스 피크는 '실제로 믹서를 통과한 신호'라 스트림이 무음이면 -200dB 다.
			var peak := AudioServer.get_bus_peak_volume_left_db(0, 0)
			print("  %7.1f   %10.3f  %-7s  %.1f dB"
				% [wall, pos, player.playing, peak])

	print("\n재생 위치가 움직인 프레임 %d개" % moved)
	if moved == 0:
		print("FAIL 재생 위치가 전혀 안 움직였다 — 재생 자체가 안 되고 있다")
		quit(1)
		return
	print("PASS 엔진은 정상 재생 중이다.")
	print("     여기까지 정상인데 귀에 안 들리면 엔진 밖이다 —")
	print("     macOS 출력장치 · 시스템 볼륨 · 앱별 볼륨(사운드 설정)을 봐라.")
	player.stop()
	quit(0)
