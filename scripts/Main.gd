extends Node2D

## 배선 + TileCursor 상태. 이 게임의 상태는 여기 한 곳에만 있다.
##
## 두 주체가 시간을 본다:
##   _process  = 감시자. 무입력 Miss 를 확정하고 공전각을 갱신한다.
##   _input    = 입력자. 스페이스 입력을 판정한다.
##
## 감시자가 왜 필요한가:
##   플레이어가 버튼을 누르면 _input 이 터진다. 근데 안 누르면 아무 일도 안 일어난다.
##   이벤트가 없으니까. 그러면 타일 인덱스가 그 자리에 멈춰 있고,
##   한참 뒤의 입력이 "오래전에 지나간 타일에 대한 입력"으로 채점된다.
##   Miss 는 이벤트가 없는 유일한 판정이라 시간을 감시하는 주체가 따로 있어야 한다.

const TILE_SPACING := 96.0

@export var chart: Chart

@onready var _path: Line2D = $World/Path
@onready var _camera: Camera2D = $World/Camera2D
@onready var _planets: PlanetPair = $World/PlanetPair
@onready var _popup: Label = $World/JudgmentPopup
@onready var _judge: Judge = $Judge
@onready var _offset_slider: HSlider = $UI/CalibrationPanel/VBox/OffsetSlider
@onready var _offset_label: Label = $UI/CalibrationPanel/VBox/OffsetLabel
@onready var _debug: Label = $UI/DebugOverlay/DebugLabel

var _hit_times := PackedFloat32Array()
var _positions := PackedVector2Array()
## 다음에 밟을 타일. 0 은 출발점이라 1 에서 시작한다.
var _idx := 1
var _finished := false

## 판정 오차 표본. 재시작을 넘어 누적된다 — 성공기준 3(같은 구간 10회 반복)이
## 재시작마다 표본을 날리면 잴 수가 없다.
var _deltas: Array[float] = []


func _ready() -> void:
	if chart == null or not chart.is_valid():
		push_error("Main.chart 가 비었거나 불완전하다. 인스펙터에서 .tres 를 물려라.")
		set_process(false)
		set_process_input(false)
		return

	_hit_times = ChartRuntime.hit_times_ms(chart)
	_positions = ChartRuntime.tile_positions(chart.angles, TILE_SPACING)
	_draw_path()

	_offset_slider.value_changed.connect(_on_offset_changed)
	_on_offset_changed(_offset_slider.value)
	_judge.judged.connect(_on_judged)
	AudioClock.song_finished.connect(_on_song_finished)

	_restart()


func _restart() -> void:
	_idx = 1
	_finished = false
	_popup.text = ""
	_planets.configure(
		_positions[0],
		ChartRuntime.orbit_start_deg(chart.angles, 1),
		ChartRuntime.orbit_sweep_deg(chart.angles, 1),
		TILE_SPACING)
	_planets.set_orbit_progress(0.0)
	AudioClock.start(chart.audio)


func _draw_path() -> void:
	_path.clear_points()
	for p in _positions:
		_path.add_point(p)


# ------------------------------------------------------------------ 감시자
func _process(_delta: float) -> void:
	if _finished or not AudioClock.is_warm():
		return
	var t := AudioClock.judged_ms()

	# 기한이 지난 타일을 전부 Miss 로 확정하고 전진한다.
	# while 인 이유: 랙 스파이크가 나면 한 프레임에 여러 타일이 동시에 만료된다.
	while _idx < _hit_times.size() and t > _hit_times[_idx] + _judge.miss_ms:
		_judge.emit_miss(_idx)
		_advance()

	if _idx >= _hit_times.size():
		_on_song_finished()
		return

	# 공전각도 판정과 같은 t 에서 파생한다.
	var t0 := _hit_times[_idx - 1]
	var t1 := _hit_times[_idx]
	var span := t1 - t0
	var u := 0.0 if span <= 0.0 else clampf((t - t0) / span, 0.0, 1.0)
	_planets.set_orbit_progress(u)

	# 카메라도 같은 t 에서 파생한다. 별도 트윈을 두면 그게 또 하나의 시간축이 된다.
	_camera.position = _positions[_idx - 1].lerp(_positions[_idx], u)

	_update_debug(t)


# ------------------------------------------------------------------ 입력자
func _input(event: InputEvent) -> void:
	if _finished:
		return
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	# echo 는 OS 키 리피트다. 안 막으면 가만히 눌러만 있어도 idx 가 폭주한다.
	# 크래시가 아니라 조용히 틀리는 종류라 가장 찾기 어렵다.
	if not k.pressed or k.echo:
		return
	if k.keycode == KEY_R:
		_restart()
		return
	if k.keycode != KEY_SPACE:
		return
	# 워밍업 중 입력을 여기서 막는다. 안 막으면 곡 맨 앞 입력이
	# 이유 없이 Miss 로 기록되어 산포 표본을 오염시킨다.
	if not AudioClock.is_warm():
		return
	if _idx >= _hit_times.size():
		return  # 곡 종료 후 입력

	var delta := AudioClock.judged_ms() - _hit_times[_idx]

	# 공전 중 입력: 판정창 밖의 극단적 조기 입력은 무시한다.
	# Miss 도 아니고 전진도 안 한다 — "너무 빨리 눌렀다"가 Miss 가 되면
	# 손가락이 교정되지 않는다.
	if delta < -_judge.miss_ms:
		return

	_judge.judge_input(delta, _idx)
	_deltas.append(delta)
	_advance()


func _advance() -> void:
	_idx += 1
	_planets.swap_roles()
	if _idx < chart.angles.size():
		_planets.configure(
			_positions[_idx - 1],
			ChartRuntime.orbit_start_deg(chart.angles, _idx),
			ChartRuntime.orbit_sweep_deg(chart.angles, _idx),
			TILE_SPACING)


func _on_judged(v: Judge.Verdict, delta_ms: float, _tile: int) -> void:
	_popup.text = Judge.verdict_name(v)
	_popup.position = _positions[mini(_idx, _positions.size() - 1)] + Vector2(-40, -70)
	match v:
		Judge.Verdict.PERFECT:
			_planets.flash(Color(0.6, 1.0, 0.7))
		Judge.Verdict.MISS:
			_planets.flash(Color(1.0, 0.4, 0.4))
		_:
			_planets.flash(Color(1.0, 0.9, 0.5))
	if is_finite(delta_ms):
		_popup.text += " %+.0fms" % delta_ms


func _on_song_finished() -> void:
	if _finished:
		return
	_finished = true
	AudioClock.stop()
	_popup.text = "FINISHED  —  R 로 재시작"


func _on_offset_changed(v: float) -> void:
	AudioClock.user_offset_ms = v
	_offset_label.text = "오프셋 %+.0f ms" % v


# ------------------------------------------------------------------ 계측
func _update_debug(t: float) -> void:
	var mean := 0.0
	var sd := 0.0
	var n := _deltas.size()
	if n > 0:
		for d in _deltas:
			mean += d
		mean /= n
		for d in _deltas:
			sd += (d - mean) * (d - mean)
		sd = sqrt(sd / n)
	_debug.text = (
		"tile %d/%d   t %.0fms\n" % [_idx, _hit_times.size() - 1, t]
		+ "표본 %d   평균 %+.1fms   표준편차 %.1fms\n" % [n, mean, sd]
		+ "clamp_hits %d   (0 이어야 함 — 하드 게이트)\n" % AudioClock.clamp_hits
		+ "output_latency %.1fms   fps %d" % [AudioClock.output_latency_ms(), Engine.get_frames_per_second()]
	)
