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

const MAX_SECONDS := 45.0

var _main: Node
var _t0 := 0
var _frames := 0
var _max_idx := 0
var _last_sec := -1


func _ready() -> void:
	var scene: PackedScene = load("res://scenes/Main.tscn")
	_main = scene.instantiate()
	add_child(_main)
	_t0 = Time.get_ticks_usec()
	var chart: Chart = _main.get("chart")
	print("드라이버 %s · 차트 %s · 타일 %d · 오디오 %.1fs"
		% [AudioServer.get_driver_name(), chart.title,
		   chart.angles.size(), chart.audio.get_length()])
	print("  경과(s)  클럭(ms)  타일  판정  역행")


func _process(_d: float) -> void:
	_frames += 1
	var wall := float(Time.get_ticks_usec() - _t0) / 1_000_000.0
	var idx: int = _main.get("_idx")
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
	print("  도달 타일 %d / %d · 판정 %d 건" % [_max_idx, n, score.total])
	print("  클럭 역행 %d회 · 최대 %.3fms" % [int(AudioClock.clamp_hits),
		float(AudioClock.max_backstep_ms)])

	var fails := 0
	if _max_idx < 2:
		print("  FAIL 감시자가 타일을 전진시키지 못했다 (idx %d)" % _max_idx); fails += 1
	if not reached_end:
		print("  FAIL %.0fs 안에 곡 종료 미도달" % MAX_SECONDS); fails += 1
	if score.total < n:
		print("  FAIL 판정 수(%d)가 타일 수(%d)보다 적다" % [score.total, n]); fails += 1
	# 역행은 구조적으로 일어난다. 횟수가 아니라 크기로 본다.
	# 한 청크(~6ms)를 크게 넘으면 그건 다른 문제다.
	if float(AudioClock.max_backstep_ms) > 10.0:
		print("  FAIL 클럭 역행이 %.1fms — 믹스 청크로 설명 안 되는 크기"
			% float(AudioClock.max_backstep_ms)); fails += 1
	print("  %s" % ("PASS" if fails == 0 else "FAILED %d" % fails))
	get_tree().quit(fails)
