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

	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(_fail)


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
	j.free()


func t_judge_classify() -> void:
	print("판정 등급 — 7등급 경계와 부호")
	var j := Judge.new()
	j.set_gaps(INF, INF)   # 기준창 30/60/110
	ok(j.classify(0.0) == Judge.Verdict.PERFECT, "0ms -> PERFECT")
	ok(j.classify(30.0) == Judge.Verdict.PERFECT, "경계 +30 -> PERFECT")
	ok(j.classify(-30.0) == Judge.Verdict.PERFECT, "경계 -30 -> PERFECT")
	ok(j.classify(45.0) == Judge.Verdict.LATE_PERFECT, "+45 -> LATE PERFECT")
	ok(j.classify(-45.0) == Judge.Verdict.EARLY_PERFECT, "-45 -> EARLY PERFECT")
	ok(j.classify(90.0) == Judge.Verdict.VERY_LATE, "+90 -> LATE!")
	ok(j.classify(-90.0) == Judge.Verdict.VERY_EARLY, "-90 -> EARLY!")
	ok(j.classify(200.0) == Judge.Verdict.TOO_LATE, "+200 -> TOO LATE")
	ok(j.classify(-200.0) == Judge.Verdict.TOO_EARLY, "-200 -> TOO EARLY")
	ok(Judge.is_miss(Judge.Verdict.TOO_LATE), "TOO_LATE 는 미스")
	ok(Judge.is_miss(Judge.Verdict.TOO_EARLY), "TOO_EARLY 는 미스")
	ok(not Judge.is_miss(Judge.Verdict.VERY_LATE), "VERY_LATE 는 미스 아님")
	# 창이 좁아져도 등급 판정은 같은 규칙을 따른다
	j.set_gaps(100.0, 100.0)   # miss 45, perfect ~12.3
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
