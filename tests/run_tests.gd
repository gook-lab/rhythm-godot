extends SceneTree

## 의존성 0 테스트 러너.
##   godot --headless --script res://tests/run_tests.gd
## 실패 건수를 exit code 로 반환한다.
##
## 설계문서는 gdUnit4 를 1순위로 두되 "15분 안에 안 붙으면 즉시 폴백"이라고 정했다.
## 이 파일이 그 폴백이고, 미리 짜 두는 이유는 막힌 그 자리에서 설계하면
## 15분 손절이 1시간이 되기 때문이다.
##
## 단위 테스트 대상은 ChartRuntime 뿐이다 — M1 에서 순수 함수는 그것뿐이고,
## AudioClock 은 오디오 하드웨어 상태에, Judge/Main 은 씬에 의존한다.

var _fail := 0
var _pass := 0


func _init() -> void:
	print("=== ChartRuntime 단위 테스트 ===\n")

	t_normalize360()
	t_straight()
	t_uturn()
	t_ninety()
	t_wraparound()
	t_empty()
	t_single()
	t_two()
	t_bad_bpm()
	t_monotonic()
	t_tile_positions()
	t_landing()
	t_beats_to_reach()
	t_judge_windows()
	t_judge_classify()
	t_score()
	t_speed_tiles()
	t_twirl()
	t_health()
	t_records()
	t_planets()

	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(_fail)


## 삼행성 — 행성 수가 박자와 각도의 관계를 바꾼다.
## 여기서 잠그는 것: (1) 오프셋 공식 (2) 기본값 2 가 예전과 완전히 같다
## (3) 오프셋이 껴도 착지가 정확하다 (4) 요청한 박자가 그대로 벽시계가 된다.
func t_planets() -> void:
	print("삼행성 — 시작 오프셋 (P-2)*180/P")
	eq(ChartRuntime.planet_offset_deg(2), 0.0, "2행성 -> 0도 (예전과 동일)")
	eq(ChartRuntime.planet_offset_deg(3), 60.0, "3행성 -> 60도")
	eq(ChartRuntime.planet_offset_deg(4), 90.0, "4행성 -> 90도")
	eq(ChartRuntime.planet_offset_deg(1), 0.0, "1 이하는 2로 취급")

	print("삼행성 — 직선 타일이 1박이 아니라 2/3박")
	eq(ChartRuntime.beats_for_tile(0.0, 0.0, 1, false, 0.0), 1.0, "2행성 직선 = 1박")
	eq(ChartRuntime.beats_for_tile(0.0, 0.0, 1, false, 60.0), 2.0 / 3.0,
		"3행성 직선 = 2/3박")

	print("삼행성 — 착지 불변식 (오프셋이 껴도 성립)")
	const R := 96.0
	var angles := PackedFloat32Array([0.0, 60.0, 120.0, 180.0, 240.0, 300.0, 0.0])
	var pos := ChartRuntime.tile_positions(angles, R)
	var worst := 0.0
	for off in [0.0, 60.0, 90.0]:
		for spin in [1, -1]:
			for mid in [false, true]:
				for i in range(1, angles.size()):
					var a := ChartRuntime.orbit_start_deg(angles, i, mid, off)
					var sw := ChartRuntime.orbit_sweep_deg(angles, i, spin, mid, off)
					var e := deg_to_rad(a + sw)
					var landed: Vector2 = pos[i - 1] + Vector2(cos(e), -sin(e)) * R
					worst = maxf(worst, landed.distance_to(pos[i]))
	ok(worst < 0.01, "오프셋 x spin x 중간회전 12조합 최대 오차 %.4fpx" % worst)

	print("삼행성 — 생성기가 만든 채보의 벽시계가 요청한 박자와 맞는다")
	var c: Chart = load("res://charts/t07_three.tres")
	if c == null:
		ok(false, "t07_three.tres 없음 — python3 tools/make_charts.py 를 먼저")
		return
	ok(c.planet_count == 3, "planet_count 3 (%d)" % c.planet_count)
	var h := ChartRuntime.hit_times_ms(c)
	# 요청한 홉이 전부 1박(120bpm -> 500ms)이었다. 첫 홉만 기하상 2/3박이다.
	var bad := 0
	for i in range(2, h.size()):
		if absf((h[i] - h[i - 1]) - 500.0) > 1.0:
			bad += 1
	ok(bad == 0, "요청한 1박 홉이 전부 500ms (어긋난 홉 %d개)" % bad)
	# hit_times 는 PackedFloat32Array 라 저장 자체가 float32 다.
	# 333.3333... 은 그 격자에 정확히 안 앉는다(한 칸 3e-5ms) — 정밀도지 오류가 아니다.
	eq(h[1] - h[0], 500.0 * 2.0 / 3.0, "첫 홉은 기하상 2/3박", 1e-3)

	print("삼행성 — 기본값 2 는 예전 계산과 한 치도 안 다르다")
	var c2 := make_chart([0.0, 90.0, 0.0, 270.0, 0.0])
	var h2 := ChartRuntime.hit_times_ms(c2)
	ok(c2.planet_count == 2, "기본 행성 수 2")
	eq(h2[1] - h2[0], 500.0, "직선 1박")
	eq(h2[2] - h2[1], 750.0, "90도 1.5박")


# ---------------------------------------------------------------- 도우미
func ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s" % what)


func eq(a: float, b: float, what: String, eps := 1e-5) -> void:
	ok(absf(a - b) < eps, "%s  (got %.6f, want %.6f)" % [what, a, b])


func make_chart(angles: Array, bpm := 120.0, offset := 0.0) -> Chart:
	var c := Chart.new()
	c.bpm = bpm
	c.start_offset_ms = offset
	c.angles = PackedFloat32Array(angles)
	return c


# ---------------------------------------------------------------- 테스트
func t_normalize360() -> void:
	print("normalize360 — fmod 가 아니라 fposmod 여야 한다")
	eq(ChartRuntime.normalize360(-90.0), 270.0, "-90 -> 270")
	eq(ChartRuntime.normalize360(450.0), 90.0, "450 -> 90")
	eq(ChartRuntime.normalize360(0.0), 0.0, "0 -> 0")
	eq(ChartRuntime.normalize360(-360.0), 0.0, "-360 -> 0")


func t_straight() -> void:
	print("직선 — 계속 같은 방향이면 1박")
	eq(ChartRuntime.beats_for_tile(0.0, 0.0), 1.0, "0 -> 0")
	eq(ChartRuntime.beats_for_tile(90.0, 90.0), 1.0, "90 -> 90")
	eq(ChartRuntime.beats_for_tile(213.0, 213.0), 1.0, "213 -> 213")


func t_uturn() -> void:
	print("U턴 — 되돌아가면 2박 (is_zero_approx 분기)")
	eq(ChartRuntime.beats_for_tile(0.0, 180.0), 2.0, "0 -> 180")
	eq(ChartRuntime.beats_for_tile(270.0, 90.0), 2.0, "270 -> 90")


func t_ninety() -> void:
	print("90도 꺾임 — 1.5박")
	eq(ChartRuntime.beats_for_tile(0.0, 90.0), 1.5, "0 -> 90")
	eq(ChartRuntime.beats_for_tile(0.0, 270.0), 0.5, "0 -> 270 (반대쪽은 0.5박)")


func t_wraparound() -> void:
	print("360 경계 랩어라운드 — 같은 상대각이면 같은 값이어야 한다")
	# 350 -> 10 은 +20도 회전이고, 0 -> 20 과 상대각이 같다.
	eq(ChartRuntime.beats_for_tile(350.0, 10.0),
		ChartRuntime.beats_for_tile(0.0, 20.0), "350->10 == 0->20")
	eq(ChartRuntime.beats_for_tile(10.0, 350.0),
		ChartRuntime.beats_for_tile(20.0, 0.0), "10->350 == 20->0")


func t_empty() -> void:
	print("빈 배열 — 크래시 없이 빈 배열")
	var c := make_chart([])
	ok(ChartRuntime.hit_times_ms(c).size() == 0, "angles 0개 -> 빈 배열")
	ok(ChartRuntime.hit_times_ms(null).size() == 0, "chart null -> 빈 배열")
	ok(ChartRuntime.tile_positions(PackedFloat32Array(), 96.0).size() == 0,
		"tile_positions 빈 배열")


func t_single() -> void:
	print("타일 1개 — 루프 미실행, 출발점만")
	var h := ChartRuntime.hit_times_ms(make_chart([0.0], 120.0, 250.0))
	ok(h.size() == 1, "길이 1")
	if h.size() == 1:
		eq(h[0], 250.0, "[0] == start_offset_ms")


func t_two() -> void:
	print("타일 2개 — 심판 대상이 딱 1개인 최소 게임 (루프 경계 off-by-one)")
	var h := ChartRuntime.hit_times_ms(make_chart([0.0, 0.0], 120.0, 0.0))
	ok(h.size() == 2, "길이 2")
	if h.size() == 2:
		eq(h[0], 0.0, "[0] 출발점")
		eq(h[1], 500.0, "[1] 직선 1박 @ bpm120 = 500ms")


func t_bad_bpm() -> void:
	print("bpm <= 0 — assert 가 아니라 실제 분기로 막는다")
	ok(ChartRuntime.hit_times_ms(make_chart([0.0, 0.0], 0.0)).size() == 0, "bpm 0")
	ok(ChartRuntime.hit_times_ms(make_chart([0.0, 0.0], -5.0)).size() == 0, "bpm 음수")


func t_monotonic() -> void:
	print("누적 단조증가 — 어떤 각도 배열에서도 시각이 줄면 안 된다")
	var angles: Array = []
	var seed := 12345
	for i in range(200):
		seed = (seed * 1103515245 + 12345) % 2147483648
		angles.append(float((seed / 65536) % 24) * 15.0)
	var h := ChartRuntime.hit_times_ms(make_chart(angles, 175.0))
	var mono := true
	for i in range(1, h.size()):
		if h[i] < h[i - 1]:
			mono = false
			break
	ok(mono, "200타일 무작위 각도에서 단조증가")
	ok(h.size() == 200, "길이 보존")

	# 누적 정밀도. hit_times 는 PackedFloat32Array 라서, out[i-1] 을 되읽어
	# 더하면 매 타일 float32 로 반올림되고 그 오차가 무작위 보행으로 쌓인다.
	# 긴 곡에서만 드러난다 — 실측(mureka_08, 200초 848타일)에서 1.011ms 까지
	# 벌어져 엔진 교차검증 허용치 1.5ms 에 붙었다. 누적을 double 로 바꾼 뒤
	# 0.0078ms(= 그 지점 float32 한 칸)로 떨어졌고 곡 길이와 무관해졌다.
	#
	# 직선 900타일을 double 로 직접 적분한 값과 대조한다. 누적이 float32 로
	# 되돌아가면 여기가 즉시 깨진다.
	var straight: Array = []
	for i in range(900):
		straight.append(0.0)
	var hs := ChartRuntime.hit_times_ms(make_chart(straight, 137.0, 1234.5))
	var step := 60000.0 / 137.0          # 직선은 전부 1박
	var worst_err := 0.0
	for i in range(hs.size()):
		worst_err = maxf(worst_err, absf(hs[i] - (1234.5 + step * i)))
	ok(worst_err < 0.05,
		"900타일 누적 오차 %.4fms — float32 로 누적하면 1ms 급으로 벌어진다" % worst_err)


func t_tile_positions() -> void:
	print("타일 좌표 — 렌더도 같은 각도 배열에서 파생된다")
	var p := ChartRuntime.tile_positions(PackedFloat32Array([0.0, 0.0, 0.0]), 100.0)
	ok(p.size() == 3, "길이 3")
	if p.size() == 3:
		eq(p[0].x, 0.0, "[0] 원점")
		eq(p[1].x, 100.0, "[1] 오른쪽 100")
		eq(p[2].x, 200.0, "[2] 오른쪽 200")
		eq(p[2].y, 0.0, "직선이면 y 불변")
	var q := ChartRuntime.tile_positions(PackedFloat32Array([90.0, 90.0]), 100.0)
	if q.size() == 2:
		eq(q[1].y, -100.0, "90도는 화면 위쪽(-y)")


## 이 게임에서 가장 중요한 불변식:
## 도는 행성이 공전을 마쳤을 때 반드시 '다음 타일 위'에 있어야 한다.
##
## 이게 깨지면 직선 구간에선 멀쩡해 보이고 꺾이는 데서만 튄다 —
## 눈으로 잡기 어렵고, 잡아도 원인이 공식인지 렌더인지 판정인지 헷갈린다.
## 실제로 첫 구현이 여기서 한 타일 밀려 있었고(angles[i-1],angles[i] 를 썼다),
## 90도 턴 네 번이 연속되는 사각 구간에서 눈에 띄어서 발견됐다.
## 좌표로 잠근다.
func t_landing() -> void:
	print("착지 불변식 — 공전 끝점이 정확히 다음 타일 좌표여야 한다")
	const R := 96.0
	var cases := {
		"직선": [0.0, 0.0, 0.0, 0.0],
		"90도 계단": [0.0, 90.0, 0.0, 270.0, 0.0],
		"사각형(90도 4연속)": [0.0, 270.0, 180.0, 90.0, 0.0],
		"U턴": [0.0, 180.0, 0.0],
		"랩어라운드": [350.0, 10.0, 350.0, 10.0],
		"임의 15도격자": [15.0, 105.0, 240.0, 60.0, 330.0, 195.0],
	}
	for name in cases:
		var angles := PackedFloat32Array(cases[name])
		var pos := ChartRuntime.tile_positions(angles, R)
		var worst := 0.0
		for i in range(1, angles.size()):
			var pivot: Vector2 = pos[i - 1]
			var a := ChartRuntime.orbit_start_deg(angles, i)
			var s := ChartRuntime.orbit_sweep_deg(angles, i)
			var end := deg_to_rad(a + s)
			var landed := pivot + Vector2(cos(end), -sin(end)) * R
			worst = maxf(worst, landed.distance_to(pos[i]))
		ok(worst < 0.01, "%s — 최대 착지 오차 %.4f px" % [name, worst])

	# 중간회전은 공전 '시작각'을 180도 옮긴다. 끝각은 정의상 angles[i-1] 이라
	# 착지는 그대로여야 하는데, 시작각과 스윕을 따로 고치면 여기서 어긋난다.
	# spin 과 조합해도(4가지) 전부 성립해야 한다.
	print("착지 불변식 — 중간회전·twirl 을 섞어도 성립한다")
	for name in cases:
		var angles := PackedFloat32Array(cases[name])
		var pos := ChartRuntime.tile_positions(angles, R)
		var worst := 0.0
		for spin in [1, -1]:
			for mid in [false, true]:
				for i in range(1, angles.size()):
					var pivot: Vector2 = pos[i - 1]
					var a := ChartRuntime.orbit_start_deg(angles, i, mid)
					var s := ChartRuntime.orbit_sweep_deg(angles, i, spin, mid)
					var end := deg_to_rad(a + s)
					var landed := pivot + Vector2(cos(end), -sin(end)) * R
					worst = maxf(worst, landed.distance_to(pos[i]))
		ok(worst < 0.01, "%s — spin x 중간회전 4조합 최대 오차 %.4f px" % [name, worst])

	print("중간회전 — 같은 기하가 다른 박자가 된다 (그 반대도)")
	# 직선 배열: 보통이면 1박, 중간회전이면 sweep 0 = U턴 취급이라 2박.
	eq(ChartRuntime.beats_for_tile(0.0, 0.0, 1, false), 1.0, "직선 · 보통 = 1박")
	eq(ChartRuntime.beats_for_tile(0.0, 0.0, 1, true), 2.0, "직선 · 중간회전 = 2박")
	eq(ChartRuntime.beats_for_tile(0.0, 180.0, 1, false), 2.0, "U턴 · 보통 = 2박")
	eq(ChartRuntime.beats_for_tile(0.0, 180.0, 1, true), 1.0, "U턴 · 중간회전 = 1박")
	# 0.25박(45도 스윕)에서 진행방향 변화가 225도 -> 45도 로 완만해진다.
	# 이 차이가 촘촘한 구간의 코일을 푼다.
	eq(ChartRuntime.beats_for_tile(0.0, 225.0, 1, false), 0.25, "0.25박 · 보통")
	eq(ChartRuntime.beats_for_tile(0.0, 45.0, 1, true), 0.25, "0.25박 · 중간회전")

	print("중간회전 — hit_times 에 반영된다")
	var cm := make_chart([0.0, 0.0, 0.0, 0.0])
	var t_plain := ChartRuntime.hit_times_ms(cm)
	cm.midspin_tiles = PackedInt32Array([2])
	var t_mid := ChartRuntime.hit_times_ms(cm)
	eq(t_mid[1], t_plain[1], "중간회전 앞 타일은 그대로")
	eq(t_mid[2] - t_mid[1], (t_plain[2] - t_plain[1]) * 2.0,
		"중간회전 타일은 1박(직선) 대신 2박이 된다")
	ok(ChartRuntime.is_midspin(cm, 2) and not ChartRuntime.is_midspin(cm, 1),
		"is_midspin 은 그 타일만 (누적 아님)")


func t_beats_to_reach() -> void:
	print("도달 박자 — 진입방향(angles[i-2])과 나갈방향(angles[i-1])으로 정해진다")
	# 타일 1 은 진입 방향이 없다. 직선으로 간주해 1박.
	var straight := PackedFloat32Array([0.0, 0.0, 0.0])
	eq(ChartRuntime.beats_to_reach(straight, 1), 1.0, "첫 홉은 항상 1박")
	eq(ChartRuntime.beats_to_reach(straight, 2), 1.0, "직선 2번째 홉 1박")

	# 타일 1 에서 90도 꺾으면, 그 영향은 '타일 2 로 가는 홉'에 나타난다.
	# 타일 1 로 가는 홉이 아니다 — 한 칸 밀리면 여기서 걸린다.
	var turn := PackedFloat32Array([0.0, 90.0, 90.0])
	eq(ChartRuntime.beats_to_reach(turn, 1), 1.0, "턴 전 홉은 여전히 1박")
	eq(ChartRuntime.beats_to_reach(turn, 2), 1.5, "타일1의 +90도가 타일2 홉에 나타난다")

	# 범위 밖은 0
	eq(ChartRuntime.beats_to_reach(straight, 0), 0.0, "i=0 은 0")
	eq(ChartRuntime.beats_to_reach(straight, 9), 0.0, "범위 밖은 0")


## 판정창이 이웃 타일에 절대 닿지 않아야 한다.
##
## 고정 ±110ms 로 두면 인접 간격이 220ms 밑으로 내려가는 순간 창이 겹치고,
## 한 번 누른 입력이 두 타일 모두에 유효해진다.
##   0.5박 @140bpm -> 214ms 간격 -> -6ms 겹침
##   1/6박 @340bpm -> 29ms 간격  -> 완전 붕괴
## 겹침이 '구조적으로 불가능'한지를 여러 템포에서 확인한다.
func t_judge_windows() -> void:
	print("판정창 — 이웃 타일에 닿지 않도록 캡된다")
	var j := Judge.new()
	j.base_perfect_ms = 30.0
	j.base_very_ms = 60.0
	j.base_miss_ms = 110.0

	# 느린 구간: 캡이 안 걸려 기준값 그대로
	j.set_gaps(500.0, 500.0)
	eq(j.miss_ms, 110.0, "간격 500ms — 기준값 유지")
	eq(j.perfect_ms, 30.0, "간격 500ms — Perfect 30")

	# 겹치는 케이스들: 창 폭이 간격의 절반을 못 넘어야 한다
	for gap in [250.0, 214.0, 125.0, 29.0, 8.0]:
		j.set_gaps(gap, gap)
		ok(j.miss_ms * 2.0 <= gap,
			"간격 %.0fms — 창 폭 %.1fms <= 간격" % [gap, j.miss_ms * 2.0])
		ok(j.perfect_ms <= j.very_ms and j.very_ms <= j.miss_ms,
			"간격 %.0fms — 사다리 순서 보존 (%.1f<=%.1f<=%.1f)"
			% [gap, j.perfect_ms, j.very_ms, j.miss_ms])

	# 사다리 비율은 눌려도 보존된다
	j.set_gaps(100.0, 100.0)
	var r_before := 30.0 / 110.0
	var r_after := j.perfect_ms / j.miss_ms
	eq(r_after, r_before, "눌려도 Perfect/Miss 비율 보존", 1e-4)

	# 비대칭 간격이면 좁은 쪽을 따른다
	j.set_gaps(500.0, 100.0)
	ok(j.miss_ms * 2.0 <= 100.0, "앞뒤가 다르면 좁은 쪽 기준")

	# 끝 타일(이웃 없음)은 기준값
	j.set_gaps(INF, INF)
	eq(j.miss_ms, 110.0, "이웃 없으면 기준값")

	# 판정 엄격도(설정): 기준창에만 곱하고 이웃-간격 캡은 배율 무관이다 —
	# 관대 모드라도 겹친 판정창은 물리적으로 안 된다.
	print("판정창 — 엄격도 배율은 기준에만, 캡은 불변")
	j.strict_scale = 1.4
	j.set_gaps(INF, INF)
	eq(j.miss_ms, 154.0, "관대 x1.4 — 미스 154")
	eq(j.perfect_ms, 42.0, "관대 x1.4 — Perfect 42")
	j.set_gaps(100.0, 100.0)
	ok(j.miss_ms * 2.0 <= 100.0, "관대여도 캡은 간격의 절반 (%.1f)" % j.miss_ms)
	j.strict_scale = 0.7
	j.set_gaps(INF, INF)
	eq(j.miss_ms, 77.0, "엄격 x0.7 — 미스 77")
	j.strict_scale = 1.0
	j.free()


func t_judge_classify() -> void:
	print("판정 등급 — 7등급 경계와 부호")
	var j := Judge.new()
	j.set_gaps(INF, INF)   # 기준창 25/45/80
	ok(j.classify(0.0) == Judge.Verdict.PERFECT, "0ms -> PERFECT")
	ok(j.classify(25.0) == Judge.Verdict.PERFECT, "경계 +25 -> PERFECT")
	ok(j.classify(-25.0) == Judge.Verdict.PERFECT, "경계 -25 -> PERFECT")
	ok(j.classify(35.0) == Judge.Verdict.LATE_PERFECT, "+35 -> LATE PERFECT")
	ok(j.classify(-35.0) == Judge.Verdict.EARLY_PERFECT, "-35 -> EARLY PERFECT")
	ok(j.classify(60.0) == Judge.Verdict.VERY_LATE, "+60 -> LATE!")
	ok(j.classify(-60.0) == Judge.Verdict.VERY_EARLY, "-60 -> EARLY!")
	ok(j.classify(200.0) == Judge.Verdict.TOO_LATE, "+200 -> TOO LATE")
	ok(j.classify(-200.0) == Judge.Verdict.TOO_EARLY, "-200 -> TOO EARLY")
	ok(Judge.is_miss(Judge.Verdict.TOO_LATE), "TOO_LATE 는 미스")
	ok(Judge.is_miss(Judge.Verdict.TOO_EARLY), "TOO_EARLY 는 미스")
	ok(not Judge.is_miss(Judge.Verdict.VERY_LATE), "VERY_LATE 는 미스 아님")
	# 창이 좁아져도 등급 판정은 같은 규칙을 따른다
	j.set_gaps(100.0, 100.0)   # cap 45 < 80 -> miss 45, perfect ~14
	ok(j.classify(0.0) == Judge.Verdict.PERFECT, "좁은 창에서도 0ms -> PERFECT")
	ok(j.classify(50.0) == Judge.Verdict.TOO_LATE, "좁은 창에서 +50 -> TOO LATE")
	j.free()


func t_score() -> void:
	print("점수 — 정확도·콤보·랭크")
	var s := Score.new()
	s.reset()
	ok(s.rank() == "-", "판정 전엔 랭크 없음")

	# 전부 일반 Perfect 면 P
	for i in range(10):
		s.on_judged(Judge.Verdict.PERFECT, 1.0, i)
	eq(s.accuracy(), 100.0, "전부 Perfect -> 100%")
	ok(s.rank() == "P", "전부 Perfect -> P 랭크")
	ok(s.combo == 10, "콤보 10")

	# E/L Perfect 가 섞이면 100% 가 아니다 — 이게 있어야 개선을 알 수 있다
	s.reset()
	for i in range(10):
		s.on_judged(Judge.Verdict.LATE_PERFECT, 40.0, i)
	ok(s.accuracy() < 100.0, "L Perfect 만 -> 100%% 미만 (%.1f%%)" % s.accuracy())
	ok(s.rank() != "P", "L Perfect 만 -> P 아님 (%s)" % s.rank())

	# 미스는 콤보를 끊는다
	s.reset()
	s.on_judged(Judge.Verdict.PERFECT, 0.0, 0)
	s.on_judged(Judge.Verdict.PERFECT, 0.0, 1)
	ok(s.combo == 2, "콤보 2")
	s.on_judged(Judge.Verdict.TOO_LATE, INF, 2)
	ok(s.combo == 0, "미스 후 콤보 0")
	ok(s.max_combo == 2, "최대 콤보 2 유지")

	# reset() 은 표본을 '일부러' 남긴다.
	# 성공기준 3 이 "같은 구간 10회 반복 -> 모든 delta 를 한 표본으로" 라서,
	# 재시작마다 표본을 날리면 산포를 잴 수가 없다.
	ok(s.delta_stats().n == 22, "reset() 을 거쳐도 표본은 누적된다 (n=%d)"
		% s.delta_stats().n)

	# 표본만 따로 비운다
	s.clear_samples()
	ok(s.delta_stats().n == 0, "clear_samples() 로 표본만 비움")

	# 미스(INF)는 산포 표본에 안 들어간다 — 시각이 없으므로
	s.on_judged(Judge.Verdict.PERFECT, 5.0, 0)
	s.on_judged(Judge.Verdict.TOO_LATE, INF, 1)
	s.on_judged(Judge.Verdict.PERFECT, -5.0, 2)
	var st := s.delta_stats()
	ok(st.n == 2, "표본에 미스 제외 (n=%d)" % st.n)
	ok(absf(st.mean) < 1e-6, "평균 %.3f (5 와 -5 라 0)" % st.mean)
	s.free()


## 토끼/달팽이 타일 (얼불춤의 SetSpeed).
## 배속이 올라가면 타일 간격이 좁아지고, 판정창도 같이 좁아져야 한다.
func t_speed_tiles() -> void:
	print("속도 타일 — 배율이 그 타일부터 적용된다")
	var c := make_chart([0.0, 0.0, 0.0, 0.0, 0.0], 120.0, 0.0)  # 전부 직선 = 1박씩

	# 변경 없으면 전부 1.0
	eq(ChartRuntime.speed_mult_at(c, 0), 1.0, "변경 없음 -> 1.0")
	eq(ChartRuntime.effective_bpm_at(c, 3), 120.0, "실효 BPM = chart.bpm")
	var h0 := ChartRuntime.hit_times_ms(c)
	eq(h0[1] - h0[0], 500.0, "120bpm 1박 = 500ms")
	eq(h0[4] - h0[3], 500.0, "끝까지 500ms")

	# 타일 2 부터 2배속(토끼)
	c.speed_changes = PackedVector2Array([Vector2(2, 2.0)])
	eq(ChartRuntime.speed_mult_at(c, 1), 1.0, "타일 1 은 아직 1.0")
	eq(ChartRuntime.speed_mult_at(c, 2), 2.0, "타일 2 부터 2.0")
	eq(ChartRuntime.speed_mult_at(c, 4), 2.0, "그 뒤로 계속 2.0")
	eq(ChartRuntime.effective_bpm_at(c, 3), 240.0, "실효 BPM 240")
	var h1 := ChartRuntime.hit_times_ms(c)
	eq(h1[1] - h1[0], 500.0, "타일1 도달: 축이 타일0 이라 1배속 500ms")
	eq(h1[2] - h1[1], 500.0, "타일2 도달: 축이 타일1 이라 아직 1배속")
	eq(h1[3] - h1[2], 250.0, "타일3 도달: 축이 타일2 라 2배속 250ms")
	eq(h1[4] - h1[3], 250.0, "그 뒤로 250ms")

	# 달팽이 (0.5배속)
	c.speed_changes = PackedVector2Array([Vector2(1, 0.5)])
	var h2 := ChartRuntime.hit_times_ms(c)
	eq(h2[2] - h2[1], 1000.0, "0.5배속 -> 1000ms")

	# 여러 변경: 마지막 것이 이긴다(누적 아님)
	c.speed_changes = PackedVector2Array([Vector2(1, 2.0), Vector2(3, 4.0)])
	eq(ChartRuntime.speed_mult_at(c, 2), 2.0, "타일 2 -> 2.0")
	eq(ChartRuntime.speed_mult_at(c, 3), 4.0, "타일 3 -> 4.0 (2*4 아님)")

	# 단조증가는 배속이 있어도 유지된다
	var h3 := ChartRuntime.hit_times_ms(c)
	var mono := true
	for i in range(1, h3.size()):
		if h3[i] < h3[i - 1]:
			mono = false
	ok(mono, "배속이 섞여도 단조증가")

	# 0 이나 음수 배율은 무시한다 (0 으로 나누면 inf 가 퍼진다)
	c.speed_changes = PackedVector2Array([Vector2(1, 0.0), Vector2(2, -3.0)])
	eq(ChartRuntime.speed_mult_at(c, 3), 1.0, "0/음수 배율은 무시")
	var h4 := ChartRuntime.hit_times_ms(c)
	var finite := true
	for i in range(h4.size()):
		if not is_finite(h4[i]):
			finite = false
	ok(finite, "잘못된 배율에도 inf 가 안 퍼진다")

	# 배속 구간에서 판정창이 이웃에 안 닿는지
	c.speed_changes = PackedVector2Array([Vector2(1, 4.0)])
	var h5 := ChartRuntime.hit_times_ms(c)
	var j := Judge.new()
	var gap := h5[3] - h5[2]
	j.set_gaps(gap, gap)
	ok(j.miss_ms * 2.0 <= gap, "4배속 구간(%.0fms)에서도 판정창(%.0fms)이 안 겹친다"
		% [gap, j.miss_ms * 2.0])
	j.free()


## Twirl — 회전 방향 반전.
##
## 장식이 아니라 경로 다양성의 유일한 수단이다.
## 0.5박 홉이 CCW 에서 항상 우회전이라 네 번 연속이면 닫힌 사각형이 되는데,
## twirl 로 뒤집으면 같은 0.5박이 좌회전이 되어 지그재그가 된다.
func t_twirl() -> void:
	print("twirl — 같은 박자가 반대로 꺾인다")
	# 0.5박: CCW 는 prev-90, CW 는 prev+90
	eq(ChartRuntime.beats_for_tile(0.0, 270.0, 1), 0.5, "CCW: 0->270 은 0.5박")
	eq(ChartRuntime.beats_for_tile(0.0, 90.0, -1), 0.5, "CW : 0->90 도 0.5박")
	# 직선과 U턴은 방향과 무관해야 한다
	eq(ChartRuntime.beats_for_tile(0.0, 0.0, 1), 1.0, "직선 CCW 1박")
	eq(ChartRuntime.beats_for_tile(0.0, 0.0, -1), 1.0, "직선 CW 도 1박")
	eq(ChartRuntime.beats_for_tile(0.0, 180.0, 1), 2.0, "U턴 CCW 2박")
	eq(ChartRuntime.beats_for_tile(0.0, 180.0, -1), 2.0, "U턴 CW 도 2박")

	print("twirl — spin_at 이 타일마다 뒤집힌다")
	var c := make_chart([0.0, 0.0, 0.0, 0.0, 0.0], 120.0, 0.0)
	ok(ChartRuntime.spin_at(c, 3) == 1, "twirl 없으면 +1")
	c.twirl_tiles = PackedInt32Array([2])
	ok(ChartRuntime.spin_at(c, 1) == 1, "타일 1 은 아직 +1")
	ok(ChartRuntime.spin_at(c, 2) == -1, "타일 2 부터 -1")
	c.twirl_tiles = PackedInt32Array([2, 4])
	ok(ChartRuntime.spin_at(c, 3) == -1, "타일 3 은 -1")
	ok(ChartRuntime.spin_at(c, 4) == 1, "두 번 뒤집으면 다시 +1")

	print("twirl — 착지 불변식은 방향이 뒤집혀도 유지된다")
	# 이게 깨지면 twirl 구간에서만 행성이 타일 밖에 내린다.
	const R := 96.0
	var cases := {
		"CW 0.5박 연속": [0.0, 90.0, 180.0, 270.0, 0.0],
		"CW 90도 계단": [0.0, 90.0, 0.0, 270.0, 0.0],
		"CW U턴": [0.0, 180.0, 0.0],
		"CW 15도격자": [15.0, 105.0, 240.0, 60.0, 330.0],
	}
	for name in cases:
		var angles := PackedFloat32Array(cases[name])
		var pos := ChartRuntime.tile_positions(angles, R)
		var worst := 0.0
		for i in range(1, angles.size()):
			var a := ChartRuntime.orbit_start_deg(angles, i)
			var sw := ChartRuntime.orbit_sweep_deg(angles, i, -1)   # 전 구간 twirl
			var e := deg_to_rad(a + sw)
			var landed: Vector2 = pos[i - 1] + Vector2(cos(e), -sin(e)) * R
			worst = maxf(worst, landed.distance_to(pos[i]))
		ok(worst < 0.01, "%s — 착지 오차 %.4f px" % [name, worst])

	print("twirl — 히트타임에 반영된다")
	# 같은 각도 배열이라도 twirl 이 걸리면 박자가 달라진다.
	var c2 := make_chart([0.0, 270.0, 180.0], 120.0, 0.0)   # CCW 로 0.5박씩
	var h_no := ChartRuntime.hit_times_ms(c2)
	c2.twirl_tiles = PackedInt32Array([1])
	var h_tw := ChartRuntime.hit_times_ms(c2)
	ok(not is_equal_approx(h_no[2], h_tw[2]),
		"twirl 이 히트타임을 바꾼다 (%.0f -> %.0f)" % [h_no[2], h_tw[2]])
	# CCW 0.5박이 CW 에선 1.5박이 된다 (270도 상대각의 반대편)
	eq(h_tw[2] - h_tw[1], 750.0, "CW 에서 같은 기하는 1.5박 = 750ms")


## 체력 — 실패 조건.
##
## 정확도 기반 실패를 대체한 이유: 정확도는 누적이라 한 번 떨어지면 회복이 안 된다.
## 초반에 감 잡느라 몇 개 놓치면 그걸로 끝인데 리듬게임에서 그건 가혹하다.
func t_health() -> void:
	print("체력 — 안 눌렀으면 안 깎인다")
	var s := Score.new()
	s.reset()
	ok(is_equal_approx(s.health, Score.HEALTH_MAX), "시작 체력 만땅")
	ok(not s.started, "아직 시작 안 함")
	# 보고만 있는 상태: 미스가 쌓여도 체력이 안 깎여야 한다
	for i in range(50):
		s.on_judged(Judge.Verdict.TOO_LATE, INF, i)
	ok(is_equal_approx(s.health, Score.HEALTH_MAX), "무입력 미스 50회 — 체력 유지")
	ok(not s.is_dead(), "무입력으로는 안 죽는다")

	print("체력 — 한 번 누르면 그때부터 깎인다")
	s.reset()
	s.on_judged(Judge.Verdict.PERFECT, 0.0, 0)     # 첫 입력
	ok(s.started, "입력 후 started")
	var h0 := s.health
	s.on_judged(Judge.Verdict.TOO_LATE, INF, 1)
	ok(s.health < h0, "미스로 체력 감소 (%.1f -> %.1f)" % [h0, s.health])
	eq(h0 - s.health, Score.DMG_MISS_PER_SEC * s.interval_sec,
		"감소량 = 초당 데미지 x 그 타일이 차지한 시간")

	print("체력 — 잘 치면 돌아온다")
	s.reset()
	s.on_judged(Judge.Verdict.PERFECT, 0.0, 0)
	for i in range(5):
		s.on_judged(Judge.Verdict.TOO_LATE, INF, i)
	var low := s.health
	ok(low < Score.HEALTH_MAX, "5미스로 떨어짐 (%.1f)" % low)
	for i in range(20):
		s.on_judged(Judge.Verdict.PERFECT, 0.0, i)
	ok(s.health > low, "정확으로 회복 (%.1f -> %.1f)" % [low, s.health])
	ok(s.health <= Score.HEALTH_MAX, "만땅을 안 넘는다 (%.1f)" % s.health)

	print("체력 — 연속 미스로 죽는다")
	s.reset()
	s.on_judged(Judge.Verdict.PERFECT, 0.0, 0)
	var n := 0
	while not s.is_dead() and n < 400:
		s.on_judged(Judge.Verdict.TOO_LATE, INF, n)
		n += 1
	ok(s.is_dead(), "연속 미스로 사망")
	# 기본 간격 0.5초 x 12.5 = 6.25 데미지. 정확 1회분 회복을 감안해 16~18회.
	ok(n >= 15 and n <= 19, "%d 연속 미스에 사망 (15~19 기대)" % n)

	# 이게 이 규칙의 존재 이유다. 밀도가 두 배여도 '죽기까지 걸리는 시간'은
	# 그대로여야 한다 — 안 그러면 촘촘한 곡이 시작하자마자 결과창이 뜬다
	# (실측 회귀: 초당 2.0 -> 3.5탭에서 7.5초 -> 4.2초).
	print("체력 — 사망까지 걸리는 '시간'은 밀도와 무관하다")
	var secs: Array[float] = []
	for gap in [0.5, 0.28, 0.18]:
		s.reset()
		s.interval_sec = gap
		s.on_judged(Judge.Verdict.PERFECT, 0.0, 0)
		var k := 0
		while not s.is_dead() and k < 2000:
			s.on_judged(Judge.Verdict.TOO_LATE, INF, k)
			k += 1
		secs.append(k * gap)
		ok(s.is_dead(), "  간격 %.2fs — %d미스 = %.1f초에 사망" % [gap, k, k * gap])
	var spread: float = secs.max() - secs.min()
	ok(spread < 1.0,
		"세 밀도의 사망 시간 편차 %.2f초 (< 1.0 기대: %.1f / %.1f / %.1f)"
		% [spread, secs[0], secs[1], secs[2]])

	# 간격 자르기: 걸음 타일(1.8초) 하나에 체력이 통째로 날아가면 안 된다.
	print("체력 — 아주 긴/짧은 간격은 잘린다")
	s.reset()
	s.interval_sec = 5.0
	s.on_judged(Judge.Verdict.PERFECT, 0.0, 0)
	var before_h: float = s.health
	s.on_judged(Judge.Verdict.TOO_LATE, INF, 1)
	var dmg: float = before_h - s.health
	ok(dmg <= Score.DMG_MISS_PER_SEC * Score.INTERVAL_MAX + 0.01,
		"5초 간격도 상한(%.1f)까지만 깎인다 (%.1f)"
		% [Score.DMG_MISS_PER_SEC * Score.INTERVAL_MAX, dmg])

	print("체력 — 리셋")
	s.reset()
	ok(is_equal_approx(s.health, Score.HEALTH_MAX) and not s.started, "reset 이 체력·started 복구")
	s.free()


func t_records() -> void:
	# autoload 이지만 --script 모드 검증을 위해 직접 인스턴스한다.
	# save_path 를 갈아끼워 실제 기록 파일(user://records.json)을 건드리지 않는다.
	print("\nRecords — 기록 갱신 · 랭크 서열 · 저장 왕복 · 판정키")
	const TEST_PATH := "user://test_records.json"
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	var r: Node = load("res://scripts/Records.gd").new()
	r.save_path = TEST_PATH
	r.load_file()

	# 첫 플레이(미클리어 40%) -> 클리어 -> 하향 플레이
	var imp: Dictionary = r.record_play("c1", 62.0, "D", 10, 40.0, false)
	ok(not imp.has("first_clear"), "미클리어는 first_clear 없음")
	imp = r.record_play("c1", 91.5, "A", 55, 100.0, true)
	ok(imp.has("first_clear"), "첫 클리어 감지")
	ok(imp.has("acc") and absf(float(imp.acc) - 62.0) < 1e-4, "정확도 갱신 시 이전값 반환")
	ok(imp.has("combo") and int(imp.combo) == 10, "콤보 갱신 시 이전값 반환")
	imp = r.record_play("c1", 70.0, "C", 20, 100.0, true)
	ok(imp.is_empty(), "하향 플레이는 갱신 없음")

	# 랭크는 정확도와 독립이다 — P(전부 일반 Perfect)는 정확도가 낮아도 SS 위.
	r.record_play("c2", 99.2, "SS", 100, 100.0, true)
	imp = r.record_play("c2", 99.0, "P", 90, 100.0, true)
	ok(imp.has("rank") and str(imp.rank) == "SS", "P 가 SS 를 이긴다 (정확도 무관)")
	var rec: Dictionary = r.get_record("c2")
	ok(str(rec.best_rank) == "P" and absf(float(rec.best_acc) - 99.2) < 1e-4,
		"랭크·정확도 최고치가 독립으로 유지")

	# 레이팅 (adofai.gg 차용): 난이도·정확도에 단조 증가, 70% 이하 0, 실패 0.
	print("Records — 레이팅 · 배지")
	# --script 모드엔 autoload 가 없어 인스턴스(r)로 정적 함수를 부른다.
	var rt: float = r.play_rating(10.0, 100.0)
	ok(absf(rt - pow(10.0, 1.6)) < 1e-6, "만점 레이팅 = 난이도^1.6 (%.1f)" % rt)
	ok(r.play_rating(10.0, 95.0) < rt
		and r.play_rating(10.0, 95.0) > r.play_rating(10.0, 90.0),
		"정확도에 단조 증가")
	ok(r.play_rating(12.0, 95.0) > r.play_rating(10.0, 95.0),
		"난이도에 단조 증가")
	ok(r.play_rating(10.0, 70.0) == 0.0 and r.play_rating(0.0, 100.0) == 0.0,
		"70% 이하·미산정 난이도는 0")
	# 배지 서열 PP > FC > 없음, 기록은 최고 배지만 유지.
	imp = r.record_play("c3", 96.0, "S", 80, 100.0, true, 20.0, "FC")
	ok(imp.has("badge") and imp.has("rating"), "첫 FC·레이팅 갱신 감지")
	imp = r.record_play("c3", 94.0, "A", 70, 100.0, true, 15.0, "")
	ok(not imp.has("badge") and not imp.has("rating"), "하향 배지·레이팅은 갱신 없음")
	imp = r.record_play("c3", 99.0, "P", 90, 100.0, true, 30.0, "PP")
	ok(imp.has("badge") and str(imp.badge) == "FC", "PP 가 FC 를 덮으며 이전값 반환")
	ok(str(r.get_record("c3").best_badge) == "PP", "최고 배지 PP 유지")
	# 종합 레이팅: 내림차순 0.9^i 감쇠 합 — 최고 한 곡 < 종합 <= 산술 합.
	r.record_play("c4", 100.0, "P", 50, 100.0, true, 10.0, "PP")
	var total: float = r.total_rating()
	ok(absf(total - (30.0 + 10.0 * 0.9)) < 1e-6,
		"종합 = 30 + 10x0.9 (%.1f)" % total)

	# 저장 -> 새 인스턴스로 로드 (왕복)
	var r2: Node = load("res://scripts/Records.gd").new()
	r2.save_path = TEST_PATH
	r2.load_file()
	var rec2: Dictionary = r2.get_record("c1")
	ok(int(rec2.plays) == 3 and int(rec2.clears) == 2, "왕복: plays 3 · clears 2")
	ok(absf(float(rec2.best_acc) - 91.5) < 1e-4, "왕복: best_acc 유지")
	ok(float(rec2.best_progress) >= 100.0 - 1e-4, "왕복: best_progress 유지")
	ok(r2.sfx_enabled, "왕복: 입력음 기본값은 켬")

	# 입력음 토글도 디스크에 남아야 한다 — 껐는데 다음 실행에 다시 켜지면
	# 설정이 아니라 그냥 잡음이다.
	r.sfx_enabled = false
	# 설정 창(판정 엄격도·음량)도 같은 왕복 계약이다.
	r.judge_mode = "lenient"
	r.music_vol = 0.35
	r.sfx_vol = 0.6
	r.save()
	var r3: Node = load("res://scripts/Records.gd").new()
	r3.save_path = TEST_PATH
	r3.load_file()
	ok(not r3.sfx_enabled, "왕복: 입력음 끔이 유지된다")
	ok(str(r3.judge_mode) == "lenient" and absf(float(r3.judge_scale()) - 1.4) < 1e-6,
		"왕복: 판정 모드 관대(x1.4) 유지")
	ok(absf(float(r3.music_vol) - 0.35) < 1e-6 and absf(float(r3.sfx_vol) - 0.6) < 1e-6,
		"왕복: 음량 유지")
	r3.judge_mode = "없는모드"
	r3.save()
	var r4: Node = load("res://scripts/Records.gd").new()
	r4.save_path = TEST_PATH
	r4.load_file()
	ok(str(r4.judge_mode) == "normal", "모르는 판정 모드는 보통으로 복구")

	# 판정키: 기본은 전부, 바인딩하면 그 키만, 예약키는 어느 쪽에서도 안 된다
	ok(r.is_judgment_key(KEY_SPACE), "기본: SPACE 허용")
	ok(not r.is_judgment_key(KEY_ESCAPE), "예약키 ESC 거부")
	ok(not r.toggle_key(KEY_R), "예약키 R 바인딩 불가")
	r.toggle_key(KEY_D)
	r.toggle_key(KEY_F)
	ok(r.is_judgment_key(KEY_F) and not r.is_judgment_key(KEY_SPACE),
		"바인딩 후: F 허용 · SPACE 거부")
	r.toggle_key(KEY_F)
	ok(not r.is_judgment_key(KEY_F), "토글 해제")

	r.free()
	r2.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
