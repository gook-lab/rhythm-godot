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
