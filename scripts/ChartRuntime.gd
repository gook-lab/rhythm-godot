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


## 각도를 0~360 으로 정규화한다.
## 주의: fmod 는 음수를 음수로 돌려준다. 반드시 fposmod 를 쓸 것.
##   fmod(-90, 360)    == -90   (틀림)
##   fposmod(-90, 360) == 270   (맞음)
static func normalize360(deg: float) -> float:
	return fposmod(deg, 360.0)


## 타일 prev 에서 타일 cur 로 넘어갈 때의 대기 박자 수.
static func beats_for_tile(prev: float, cur: float) -> float:
	var sweep := normalize360(cur - (prev + 180.0))
	if is_zero_approx(sweep):
		sweep = 360.0  # 제자리 = 한 바퀴 (U턴)
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
static func beats_to_reach(angles: PackedFloat32Array, i: int) -> float:
	if i <= 0 or i >= angles.size():
		return 0.0
	return beats_for_tile(incoming_deg(angles, i), angles[i - 1])


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
	out[0] = chart.start_offset_ms  # 타일 0 = 출발점, 판정 없음
	var spb := 60000.0 / chart.bpm  # ms per beat (배속 1.0 기준)
	for i in range(1, chart.angles.size()):
		# 타일 i 로 가는 공전은 축이 타일 i-1 이므로, 그 타일에 걸린 배속을 따른다.
		var mult := speed_mult_at(chart, i - 1)
		out[i] = out[i - 1] + beats_to_reach(chart.angles, i) * spb / mult
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
static func orbit_start_deg(angles: PackedFloat32Array, i: int) -> float:
	if i <= 0 or i >= angles.size():
		return 0.0
	return normalize360(incoming_deg(angles, i) + 180.0)


## 타일 i 로 가는 공전의 스윕각(도). 대기 박자와 같은 양을 도 단위로 준다.
static func orbit_sweep_deg(angles: PackedFloat32Array, i: int) -> float:
	return beats_to_reach(angles, i) * 180.0


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
