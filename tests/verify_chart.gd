extends SceneTree

## 교차 언어 채보 검증.
##   godot --headless --script res://tests/verify_chart.gd -- --chart=res://charts/test_song.tres
##
## midi2song.py 가 템포 맵을 직접 적분해 만든 '정답 벽시계'(*.expected.json)를,
## 실제 엔진의 ChartRuntime.hit_times_ms 가 재현하는지 비교한다.
##
## 이게 왜 결정적인가: Python 쪽 검증(되계산)은 같은 수학을 두 번 쓰는 것이라
## '의미론을 똑같이 잘못 이해'하면 통과해 버린다. 여기는 게임이 실제로 쓰는
## 코드가 정답을 내는지를 본다 — 변환기와 엔진 사이의 계약이 파일(.tres)을
## 건너 유지되는지의 최종 시험이다.
##
## 허용 오차 1.5ms: hit_times 는 PackedFloat32Array(float32 저장)라
## 누적 반올림이 ~0.1ms 나올 수 있고, %.9g 직렬화가 ~0.005ms 를 더한다.
## 의미론 버그는 밀리초 단위로 어긋나므로 1.5ms 는 여전히 유의미한 게이트다.

const TOL_MS := 1.5


func _init() -> void:
	var chart_path := "res://charts/test_song.tres"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--chart="):
			chart_path = a.split("=")[1]
	var expected_path := "res://assets/%s.expected.json" % \
		chart_path.get_file().get_basename()

	var chart: Chart = load(chart_path)
	if chart == null:
		print("FAIL 차트 로드 실패: %s" % chart_path)
		quit(1)
		return
	var f := FileAccess.open(expected_path, FileAccess.READ)
	if f == null:
		print("FAIL 정답 파일 없음: %s (midi2song.py 를 먼저 돌려라)" % expected_path)
		quit(1)
		return
	var expected: Array = JSON.parse_string(f.get_as_text())["hit_times_ms"]

	var got := ChartRuntime.hit_times_ms(chart)
	print("차트 %s · 타일 %d · 정답 %d" % [chart_path, got.size(), expected.size()])

	var fails := 0
	if got.size() != expected.size():
		print("FAIL 타일 수 불일치")
		fails += 1
	else:
		var worst := 0.0
		var worst_i := 0
		for i in range(got.size()):
			var d: float = absf(got[i] - float(expected[i]))
			if d > worst:
				worst = d
				worst_i = i
			if got[i] < got[maxi(i - 1, 0)] - 0.001:
				print("FAIL 타일 %d 에서 시각 역행" % i)
				fails += 1
		print("엔진 vs 템포맵 정답 — 최대 오차 %.4f ms (타일 %d)" % [worst, worst_i])
		if worst > TOL_MS:
			print("FAIL 오차가 %.1fms 허용을 넘는다 — 변환기/엔진 의미론이 갈라졌다" % TOL_MS)
			fails += 1

	print("PASS" if fails == 0 else "FAILED %d" % fails)
	quit(fails)
