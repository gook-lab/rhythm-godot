class_name ChartRuntime
extends RefCounted

## 각도 -> 박자 변환. 상태 없는 순수 함수만 둔다. 단위 테스트 대상은 이 스크립트뿐이다.
##
## 이 게임의 심장:
##   타일 각도는 그림이 아니라 '대기 박자 수' 그 자체다.
##   공전 각속도가 박자당 180도로 고정이면 타일 사이 상대각이 곧 대기 시간이 된다.
##   따라서 별도의 노트 타임라인이라는 자료구조가 아예 필요 없다 —
##   각도 배열 하나가 렌더와 타이밍을 동시에 생성한다.
##
## angles[i] 의 의미 (이걸 헷갈리면 전부 어긋난다):
##   angles[i] = 타일 i 에 서 있는 상태에서 "다음 타일로 나갈" 절대 방향(도).
##   따라서 angles[0] 은 시작 타일에서 나가는 방향이고, 여기엔 진입 방향이 없다.
##   -> 타일 0 은 대기 계산 대상이 아니다. 첫 입력은 타일 1 을 밟는 입력이다.
##   -> 배열 길이 N 이면 밟는 타일은 N-1 개, hit_times 도 N 개이되 [0] 은 곡 시작점 표시용.
##
## 실측 검증 (tools/verify_formula.py, 2026-08-07):
##   ADOFAI 기본 레벨(직선 10타일 @ bpm 100)에서 정확히 1.0박 / 600ms 간격.
##   실제 채보 3,155타일에서 최빈값이 정확히 1.0(34%), 모든 값이 1/12 격자.
##   `+180` 을 빼면 직선이 2박이 되어 즉시 반증된다.
##
##          prev+180 (공전 시작 위치)
##               \
##                \   sweep
##                 \  ,-'`
##          [pivot] o------> cur (다음 타일 방향)
##
##   직선 (cur==prev)      -> sweep 180  -> 1.0박
##   U턴  (cur==prev+180)  -> sweep 360  -> 2.0박
##   90도 꺾임             -> sweep 270  -> 1.5박


## U턴 판정 여유(도). beats_for_tile 의 주석이 이 값을 고른 이유를 설명한다.
const TURN_EPS_DEG := 1.0


## 각도를 0~360 으로 정규화한다.
## 주의: fmod 는 음수를 음수로 돌려준다. 반드시 fposmod 를 쓸 것.
##   fmod(-90, 360)    == -90   (틀림)
##   fposmod(-90, 360) == 270   (맞음)
static func normalize360(deg: float) -> float:
	return fposmod(deg, 360.0)


## 타일 prev 에서 타일 cur 로 넘어갈 때의 대기 박자 수.
##
## spin = +1 이면 반시계(기본), -1 이면 시계(twirl 걸린 상태).
## 방향이 반대면 같은 기하가 다른 박자가 되고, 거꾸로 같은 박자가 반대로 꺾인다:
##   0.5박 -> CCW 는 prev-90(우회전) · CW 는 prev+90(좌회전)
## 착지 불변식은 양쪽 다 성립한다 — 끝각이 어느 쪽이든 angles[i-1] 이다.
## mid = true 면 중간회전이다. 공전이 반대쪽에서 시작하므로 기준각에서 180 을 뺀다
## (Chart.midspin_tiles 주석 참조). 박자는 여전히 스윕/180 이고 착지도 그대로다.
static func beats_for_tile(prev: float, cur: float, spin: int = 1,
		mid: bool = false, offset: float = 0.0) -> float:
	var base := (prev if mid else prev + 180.0) + offset
	var sweep := normalize360(cur - base) if spin >= 0 \
		else normalize360(base - cur)
	# U턴(제자리)은 sweep 이 정확히 0 = 360 인 경우다. 그런데 이 값은
	# fposmod 의 경계 위에 정확히 얹혀 있어서, 각도에 0.001도만 오차가 섞여도
	# 0.0006(-> 0.0박) 과 359.9994(-> 2.0박) 로 갈린다. 같은 U턴이 정반대가 된다.
	#
	# is_zero_approx(1e-6) 로는 한쪽 끝밖에 못 잡는다. 실측(2026-08-07, Mureka
	# 스템 317타일): 엔진(float32)은 0박, Python(float64)은 2박으로 갈려
	# 히트타임이 6.5초 어긋났다 — 테스트 채보는 각도가 정확해서 안 드러났다.
	#
	# 1.0도는 float 오차(~0.001도)보다 1000배 크고, 격자의 최소 홉(15도 = 1/12박)
	# 보다 15배 작다. 그 사이엔 정상적인 값이 존재하지 않는다.
	if sweep < TURN_EPS_DEG or sweep > 360.0 - TURN_EPS_DEG:
		sweep = 360.0
	return sweep / 180.0


## 타일 i 로 공전해 갈 때의 '들어온 방향'.
##
## 타일 i 로 가는 공전은 축이 타일 i-1 이고, 도는 행성이 타일 i-2 에서 출발해
## 타일 i 에 착지한다. 그러므로 스윕을 정하는 두 값은
##   들어온 방향 = angles[i-2]  ·  나갈 방향 = angles[i-1]
## 이다. angles[i] 가 아니다 — 그건 타일 i 에서 그 다음으로 나갈 방향이라 한 칸 미래다.
##
## i == 1 은 진입 방향이 없다(그 앞에 타일이 없다). 직선으로 들어온 것으로 친다.
static func incoming_deg(angles: PackedFloat32Array, i: int) -> float:
	if i >= 2:
		return angles[i - 2]
	return angles[0]


## 타일 i 에 도달하는 데 걸리는 박자.
static func beats_to_reach(angles: PackedFloat32Array, i: int, spin: int = 1,
		mid: bool = false, offset: float = 0.0) -> float:
	if i <= 0 or i >= angles.size():
		return 0.0
	return beats_for_tile(incoming_deg(angles, i), angles[i - 1], spin, mid, offset)


## 행성 P개일 때 공전 시작 오프셋(도). 원작과 같은 식이다.
##   P=2 -> 0  ·  P=3 -> 60  ·  P=4 -> 90
## 도는 행성이 정반대(180도)가 아니라 그보다 offset 만큼 더 돌아간 데서 출발한다.
## 스윕이 그만큼 짧아지므로 같은 기하가 더 적은 박자가 된다(직선: 1박 -> 2/3박).
static func planet_offset_deg(count: int) -> float:
	var p := maxi(count, 2)
	return float(p - 2) * 180.0 / float(p)


static func chart_offset_deg(chart: Chart) -> float:
	return planet_offset_deg(chart.planet_count) if chart != null else 0.0


## 타일 t 에서 홀드로 더 도는 바퀴 수(0 이면 홀드 아님).
static func hold_orbits_at(chart: Chart, tile: int) -> float:
	if chart == null:
		return 0.0
	for k in range(chart.hold_tiles.size()):
		var h := chart.hold_tiles[k]
		if int(h.x) == tile and h.y > 0.0:
			return h.y
	return 0.0


## 홀드로 추가되는 박자. 한 바퀴 = 360도 = 2박이다.
## 360도의 배수라 착지가 안 바뀐다 — 경로 기하는 홀드와 무관하다.
static func hold_beats_at(chart: Chart, tile: int) -> float:
	return hold_orbits_at(chart, tile) * 2.0


## 타일 i 가 중간회전인가. twirl 과 달리 누적이 아니라 그 타일만의 성질이다.
static func is_midspin(chart: Chart, tile: int) -> bool:
	if chart == null:
		return false
	for k in range(chart.midspin_tiles.size()):
		if chart.midspin_tiles[k] == tile:
			return true
	return false


## 타일에서의 회전 방향. +1 = 반시계(기본), -1 = 시계.
## twirl 타일을 하나 지날 때마다 뒤집힌다.
static func spin_at(chart: Chart, tile: int) -> int:
	if chart == null:
		return 1
	var s := 1
	for k in range(chart.twirl_tiles.size()):
		if chart.twirl_tiles[k] <= tile:
			s = -s
	return s


## 타일 i 에서 유효한 속도 배율. 그 타일까지의 마지막 변경을 따른다.
static func speed_mult_at(chart: Chart, tile: int) -> float:
	if chart == null:
		return 1.0
	var m := 1.0
	for k in range(chart.speed_changes.size()):
		var sc := chart.speed_changes[k]
		if int(sc.x) <= tile and sc.y > 0.0:
			m = sc.y
	return m


## 타일 i 에서의 실효 BPM. HUD 의 '타일 BPM' 표시가 이걸 쓴다.
static func effective_bpm_at(chart: Chart, tile: int) -> float:
	if chart == null:
		return 0.0
	return chart.bpm * speed_mult_at(chart, tile)


## 각 타일을 밟아야 하는 절대 시각(ms)의 누적 배열.
## 길이는 chart.angles.size() 와 같고, [0] 은 출발점이라 판정 대상이 아니다.
static func hit_times_ms(chart: Chart) -> PackedFloat32Array:
	var out := PackedFloat32Array()

	# 가드는 assert 가 아니라 실제 분기여야 한다.
	# assert 는 릴리스 빌드에서 통째로 제거되므로, 친구한테 보낸 빌드에서만
	# 조용히 크래시하거나 inf 가 퍼진다.
	if chart == null or chart.angles.size() == 0:
		return out
	if chart.bpm <= 0.0:
		push_error("Chart.bpm must be > 0, got %f" % chart.bpm)
		return out

	out.resize(chart.angles.size())
	var spb := 60000.0 / chart.bpm  # ms per beat (배속 1.0 기준)
	# 누적은 double 로 한다. out 은 PackedFloat32Array 라서 out[i-1] 을 되읽어
	# 더하면 매 타일 float32 로 반올림되고, 그 오차가 무작위 보행으로 쌓인다 —
	# 200초 곡(200,000ms)에서 float32 한 칸이 ~0.03ms 이고 800타일이면
	# 0.03*sqrt(800) ≈ 0.85ms. 실측 mureka_08 이 1.011ms 로 허용치 1.5ms 에
	# 붙어 있었던 이유가 이것이다. 저장값은 그대로 float32 지만 누적을 double 로
	# 두면 오차가 '쌓이지 않고' 각 항의 마지막 반올림 하나로 끝난다.
	var off := chart_offset_deg(chart)
	var t := float(chart.start_offset_ms)
	out[0] = t  # 타일 0 = 출발점, 판정 없음
	for i in range(1, chart.angles.size()):
		# 타일 i 로 가는 공전은 축이 타일 i-1 이므로, 그 타일의 배속과 회전방향을 따른다.
		var mult := speed_mult_at(chart, i - 1)
		var spin := spin_at(chart, i - 1)
		# 홀드는 '떠나기 전에 제자리에서 더 도는' 시간이라 축 타일(i-1)에 붙는다.
		# 이 게임에서 히트타임을 뒤로 미는 유일한 타일이다.
		t += (beats_to_reach(chart.angles, i, spin, is_midspin(chart, i), off)
			+ hold_beats_at(chart, i - 1)) * spb / mult
		out[i] = t
	return out


## 타일의 화면 좌표. 렌더도 같은 각도 배열에서 파생시킨다(전제 1).
## 별도의 좌표 데이터를 두면 그게 두 번째 진실 소스가 된다.
## y 를 뒤집는 이유: 각도는 수학 관례(CCW 양수, 위가 +)인데 화면은 아래가 +y 다.
static func tile_positions(angles: PackedFloat32Array, spacing: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	if angles.size() == 0:
		return out
	out.resize(angles.size())
	out[0] = Vector2.ZERO
	for i in range(1, angles.size()):
		var a := deg_to_rad(angles[i - 1])
		out[i] = out[i - 1] + Vector2(cos(a), -sin(a)) * spacing
	return out


## 타일 i 로 가는 공전의 시작 각도(도). 축(타일 i-1)에서 본 타일 i-2 의 방향이다.
static func orbit_start_deg(angles: PackedFloat32Array, i: int,
		mid: bool = false, offset: float = 0.0) -> float:
	if i <= 0 or i >= angles.size():
		return 0.0
	return normalize360(incoming_deg(angles, i) + (0.0 if mid else 180.0) + offset)


## 타일 i 로 가는 공전의 스윕각(도). 부호가 회전 방향이다.
## CW(twirl) 이면 음수 — 렌더가 반대로 돌아야 착지가 맞는다.
static func orbit_sweep_deg(angles: PackedFloat32Array, i: int, spin: int = 1,
		mid: bool = false, offset: float = 0.0) -> float:
	return beats_to_reach(angles, i, spin, mid, offset) * 180.0 \
		* (1.0 if spin >= 0 else -1.0)


## 공전이 끝나는 각도. 정의상 반드시 angles[i-1] 이어야 하고,
## 그래야 도는 행성이 정확히 타일 i 에 착지한다.
##   start + sweep = (in+180) + normalize360(out - (in+180)) = out = angles[i-1]
## 이 항등식이 깨지면 행성이 타일에서 벗어난 곳에 내렸다가 튄다 —
## 직선 구간에선 안 보이고 꺾이는 데서만 드러나는 종류의 버그다.
## tests/run_tests.gd 의 t_landing() 이 이걸 좌표로 잠근다.
static func orbit_end_deg(angles: PackedFloat32Array, i: int) -> float:
	if i <= 0 or i >= angles.size():
		return 0.0
	return normalize360(angles[i - 1])
