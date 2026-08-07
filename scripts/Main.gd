extends Node2D

## 배선 + TileCursor 상태. 이 게임의 상태는 여기 한 곳에만 있다.
##
## 두 주체가 시간을 본다:
##   _process  = 감시자. 무입력 Miss 를 확정하고 공전각·카메라를 갱신한다.
##   _input    = 입력자. 스페이스 입력을 판정한다.
##
## 감시자가 왜 필요한가:
##   플레이어가 버튼을 누르면 _input 이 터진다. 근데 안 누르면 아무 일도 안 일어난다.
##   이벤트가 없으니까. 그러면 타일 인덱스가 그 자리에 멈춰 있고,
##   한참 뒤의 입력이 "오래전에 지나간 타일에 대한 입력"으로 채점된다.
##   Miss 는 이벤트가 없는 유일한 판정이라 시간을 감시하는 주체가 따로 있어야 한다.

const TILE_SPACING := 96.0

## 카메라가 평균낼 타일 범위(앞뒤). 크면 차분하지만 행성이 화면 중심에서 멀어진다.
##
## 실측 (창 / 경로낭비배수 / 행성까지 최대거리) — song140 기준:
##   twirl 없을 때  ±2 7.35x/212px · ±5 4.75x/274px · ±8 2.50x/370px
##   twirl 적용 후  ±1 2.52x/176px · ±2 2.05x/212px · ±3 1.75x/241px · ±5 1.46x/274px
##
## 뷰포트가 1280x720 이라 화면 반높이가 360px 다. 행성이 그보다 멀어지면 화면 밖이다.
##
## twirl 을 넣기 전에는 경로가 너무 루프를 그려서 ±5 까지 넓혀도 4.75x 였다.
## 근본 원인이 카메라가 아니라 경로였기 때문이다 —
## 0.5박 홉은 CCW 에서 '항상' -90도라 네 번 연속이면 닫힌 사각형이 된다.
## twirl 로 회전 방향을 뒤집으면 같은 0.5박이 +90도가 되어 지그재그가 된다.
## 그래서 지금은 ±3 으로 좁혀도 1.75x 다 — 흔들림도 줄고 행성도 중앙에 가깝다.
const CAMERA_WINDOW := 3

## 흔들림: 세기(px) · 감쇠(px/초) · 주파수(Hz) · 발동 최소 콤보
const SHAKE_STRENGTH := 7.0
const SHAKE_DECAY := 60.0
const SHAKE_HZ := 22.0
const SHAKE_MIN_COMBO := 3

## 정확도가 이 아래로 떨어지면 실패로 끝낸다.
## 초반 한두 번 미스로 끝나면 가혹하므로 유예 판정 수를 둔다 —
## 판정이 적을 때는 한 번만 놓쳐도 정확도가 크게 흔들린다.
@export var fail_below_accuracy: float = 55.0
@export var fail_grace_judgments: int = 12

## 시작 카운트다운을 보여줄 박자 수. 인트로가 16박이라 전부 세면 지루하다.
const COUNTDOWN_BEATS := 4

@export var chart: Chart

@onready var _path: TilePath = $World/Path
@onready var _markers: SpeedMarkers = $World/SpeedMarkers
@onready var _camera: Camera2D = $World/Camera2D
@onready var _planets: PlanetPair = $World/PlanetPair
@onready var _popup: Label = $World/JudgmentPopup
@onready var _judge: Judge = $Judge
@onready var _score: Score = $Score
@onready var _offset_slider: HSlider = $UI/CalibrationPanel/VBox/OffsetSlider
@onready var _offset_label: Label = $UI/CalibrationPanel/VBox/OffsetLabel
@onready var _debug: Label = $UI/DebugOverlay/DebugLabel
@onready var _hud_score: Label = $UI/HUD/ScoreLabel
@onready var _hud_info: Label = $UI/HUD/InfoLabel
@onready var _timing_bar: TimingBar = $UI/TimingPanel/VBox/Bar
@onready var _timing_label: Label = $UI/TimingPanel/VBox/TimingLabel
@onready var _verdict_label: Label = $UI/ComboBox/VerdictLabel
@onready var _combo_label: Label = $UI/ComboBox/ComboLabel
@onready var _countdown: Label = $UI/CountdownLabel
@onready var _result: PanelContainer = $UI/ResultPanel
@onready var _r_headline: Label = $UI/ResultPanel/Margin/VBox/Headline
@onready var _r_rank: Label = $UI/ResultPanel/Margin/VBox/Rank
@onready var _r_acc: Label = $UI/ResultPanel/Margin/VBox/Accuracy
@onready var _r_break: Label = $UI/ResultPanel/Margin/VBox/Breakdown

var _hit_times := PackedFloat32Array()
var _positions := PackedVector2Array()
## 판정 커서 — 입력 또는 미스 기한으로 전진한다. 0 은 출발점이라 1 에서 시작.
var _idx := 1

## 렌더 커서 — 순수하게 시간으로만 전진한다.
##
## 왜 나눴나: 감시자는 hit_time + miss_ms 에 전진한다(그래야 늦은 입력을 받아준다).
## 그런데 렌더까지 그 커서를 따라가면 행성이 u=1 에 도달한 뒤 miss_ms 동안 얼어붙는다.
## 0.5박 @120bpm 구간이면 250ms 중 110ms, 즉 시간의 44% 를 멈춰 있다 —
## 움직임이 끊겨 보이는 원인이 이거였다.
## 둘 다 now_ms() 에서 파생되므로 시간축은 여전히 하나다.
var _vis := 1
var _finished := false
var _song_len_ms := 0.0

## 미스 화면 흔들림 잔량(px)과 경과 시간.
##
## 미스마다 흔들면 안 된다. 리듬게임에서 미스는 흔한 일이고,
## 타일 간격(250~500ms)보다 흔들림이 길면 사실상 상시 진동이 된다.
## 실측: 14px/233ms 로 매 미스마다 흔들었더니 전체 프레임의 47% 가 흔들리고
## 카메라 경로 낭비가 2.65x -> 18.01x 로 뛰었다.
## 그래서 '콤보가 끊길 때만' 짧게 흔든다.
var _shake := 0.0
var _shake_t := 0.0

## 마지막 프레임의 공전 진행률. 회귀 테스트가 읽는다 —
## 이 값이 1.0 에 오래 붙어 있으면 행성이 얼어 있다는 뜻이다.
var _last_u := 0.0


func _ready() -> void:
	if chart == null or not chart.is_valid():
		push_error("Main.chart 가 비었거나 불완전하다. 인스펙터에서 .tres 를 물려라.")
		set_process(false)
		set_process_input(false)
		return

	_hit_times = ChartRuntime.hit_times_ms(chart)
	_positions = ChartRuntime.tile_positions(chart.angles, TILE_SPACING)
	_song_len_ms = chart.audio.get_length() * 1000.0
	_draw_path()
	_markers.setup(chart, _positions)

	_offset_slider.value_changed.connect(_on_offset_changed)
	_on_offset_changed(_offset_slider.value)
	# 순서 중요: Main 이 '끊기기 직전 콤보'를 알아야 하므로 Score 보다 먼저 받는다.
	_judge.judged.connect(_on_judged)
	_judge.judged.connect(_score.on_judged)
	AudioClock.song_finished.connect(_on_song_finished)

	_restart()


func _restart() -> void:
	_idx = 1
	_vis = 1
	_finished = false
	_shake = 0.0
	_shake_t = 0.0
	_prev_combo = 0
	_popup.text = ""
	_score.reset()   # 표본(deltas)은 남긴다 — 산포 측정이 세션 단위다
	_planets.clear_trails()
	_path.clear_impacts()
	_result.visible = false
	_countdown.text = ""
	_verdict_label.text = ""
	_combo_label.text = ""
	_configure_orbit(1)
	_apply_windows(1)
	_planets.set_orbit_progress(0.0)
	# 카메라를 시작 위치에 미리 놓고 스무딩 이력을 지운다.
	# 안 하면 워밍업 동안 (0,0) 에 있다가 warm 되는 첫 프레임에
	# 미드포인트로 48px(반지름의 절반) 순간이동한다.
	_camera.position = _camera_target(1, 0.0)
	_camera.offset = Vector2.ZERO
	_camera.reset_smoothing()
	AudioClock.start(chart.audio)


func _draw_path() -> void:
	_path.setup(_positions, chart.angles, TILE_SPACING)


## 렌더: 타일 i 로 가는 공전을 세팅한다. (렌더 커서 _vis 를 따른다)
func _configure_orbit(i: int) -> void:
	if i <= 0 or i >= chart.angles.size():
		return
	# 회전 방향(twirl)은 축 타일(i-1)의 상태를 따른다. 스윕 부호가 곧 방향이다.
	var spin := ChartRuntime.spin_at(chart, i - 1)
	_planets.configure(
		_positions[i - 1],
		ChartRuntime.orbit_start_deg(chart.angles, i),
		ChartRuntime.orbit_sweep_deg(chart.angles, i, spin),
		TILE_SPACING)


## 판정: 타일 i 의 판정창을 이웃까지의 거리로 캡한다. (판정 커서 _idx 를 따른다)
## 이게 없으면 빠른 구간에서 창이 겹쳐 한 번 누른 입력이 두 타일 모두에 유효해진다.
func _apply_windows(i: int) -> void:
	if i >= _hit_times.size():
		return
	_judge.set_gaps(_gap_before(i), _gap_after(i))
	_timing_bar.set_windows(_judge.perfect_ms, _judge.very_ms, _judge.miss_ms)


func _gap_before(i: int) -> float:
	if i <= 0 or i >= _hit_times.size():
		return INF
	return _hit_times[i] - _hit_times[i - 1]


func _gap_after(i: int) -> float:
	if i + 1 >= _hit_times.size():
		return INF
	return _hit_times[i + 1] - _hit_times[i]


# ------------------------------------------------------------------ 감시자
func _process(delta: float) -> void:
	# 화면 흔들림은 오디오 클럭과 무관한 순수 연출이라 프레임 시간으로 감쇠시킨다.
	if _shake > 0.01:
		_shake_t += delta
		_shake = maxf(0.0, _shake - delta * SHAKE_DECAY)

	if _finished or not AudioClock.is_warm():
		return
	var t := AudioClock.judged_ms()

	# ── 판정 커서: 기한이 지난 타일을 Miss 로 확정하고 전진한다.
	# while 인 이유: 랙 스파이크가 나면 한 프레임에 여러 타일이 동시에 만료된다.
	while _idx < _hit_times.size() and t > _hit_times[_idx] + _judge.miss_ms:
		_judge.emit_miss(_idx)
		_advance()

	# ── 렌더 커서: 시간이 지나면 그냥 전진한다. 미스 기한을 기다리지 않는다.
	# 이게 판정 커서와 붙어 있으면 행성이 매 타일 miss_ms 만큼 얼어붙는다.
	while _vis < _hit_times.size() and t >= _hit_times[_vis]:
		_vis += 1
		_planets.swap_roles()
		_configure_orbit(_vis)

	# 정확도 실패. 유예 판정 수를 넘긴 뒤부터 본다.
	if _score.total >= fail_grace_judgments and _score.accuracy() < fail_below_accuracy:
		_on_song_finished(true)
		return

	if _idx >= _hit_times.size():
		_on_song_finished()
		return

	# 공전각은 렌더 커서로, 판정과 같은 t 에서 파생한다.
	var vi := mini(_vis, _hit_times.size() - 1)
	var t0 := _hit_times[vi - 1]
	var t1 := _hit_times[vi]
	var span := t1 - t0
	var u := 0.0 if span <= 0.0 else clampf((t - t0) / span, 0.0, 1.0)
	_last_u = u
	_path.set_cursor(vi)
	_planets.set_orbit_progress(u)

	# 흔들림은 position 이 아니라 offset 으로 준다 —
	# position 에 실으면 Camera2D 의 position_smoothing 이 흔들림을 뭉개서
	# '흔들림'이 아니라 '느린 표류'가 된다.
	_camera.position = _camera_target(vi, u)
	_camera.offset = _shake_offset()

	_update_hud(t)


## 카메라가 볼 지점.
##
## 순간 위치(행성이든 축이든 중점이든)를 쫓으면 경로의 지그재그를 그대로 따라가서
## 위아래로 튄다. demo 채보만 해도 90도 4연속(사각형)이 두 번, U턴이 세 번 있어서
## 길이 진짜로 되돌아온다 — 알고리즘을 뭘 쓰든 순간 위치를 쫓으면 흔들린다.
##
## 그래서 주변 타일들의 '평균'을 본다. 사각형 구간이면 사각형 중심에 머문다.
## 창이 대칭이라 앞으로 올 타일도 자연스럽게 반영된다(선행 시야).
##
## 실측 경로 낭비 배수(실제 이동거리 / 순 이동거리, 1 이면 곧게 따라감):
##   두 행성 중점        8.17x   (축 주위로 반지름 48px 원을 그린다)
##   축(현재 타일)만     6.50x   (타일마다 96px 점프)
##   타일 사이 직선 lerp 5.86x   (타일 경계에서 방향 불연속)
##   이 방식 (창 ±2)     3.32x
func _camera_target(i: int, u: float) -> Vector2:
	return _track_center(i - 1).lerp(_track_center(i), u)


func _track_center(i: int) -> Vector2:
	var lo := maxi(0, i - CAMERA_WINDOW)
	var hi := mini(_positions.size() - 1, i + CAMERA_WINDOW)
	var acc := Vector2.ZERO
	for k in range(lo, hi + 1):
		acc += _positions[k]
	return acc / float(hi - lo + 1)


func _shake_offset() -> Vector2:
	if _shake <= 0.01:
		return Vector2.ZERO
	# 고정 주파수 감쇠 진동. 프레임마다 randf() 를 쓰면 fps 에 따라 체감이 달라지고
	# (144fps 면 초당 144번 방향이 바뀐다) '충격'이 아니라 '떨림'으로 읽힌다.
	# 두 축의 주파수를 어긋나게 해서 한 방향으로만 왕복하지 않게 한다.
	var w := _shake_t * TAU * SHAKE_HZ
	return Vector2(sin(w), cos(w * 0.7)) * _shake


# ------------------------------------------------------------------ 입력자
func _input(event: InputEvent) -> void:
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
	if _finished or k.keycode != KEY_SPACE:
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
	_advance()


## 판정 커서만 전진시킨다. 행성 역할 교체와 공전 재설정은 렌더 커서가 한다.
func _advance() -> void:
	_idx += 1
	_apply_windows(_idx)


var _prev_combo := 0
var _go_until := 0.0


static func _verdict_color(v: Judge.Verdict) -> Color:
	match v:
		Judge.Verdict.PERFECT: return Color(0.50, 1.20, 0.72)
		Judge.Verdict.EARLY_PERFECT, Judge.Verdict.LATE_PERFECT: return Color(0.78, 1.12, 0.52)
		Judge.Verdict.VERY_EARLY, Judge.Verdict.VERY_LATE: return Color(1.15, 0.95, 0.44)
		_: return Color(1.20, 0.39, 0.39)


func _on_judged(v: Judge.Verdict, delta_ms: float, tile: int) -> void:
	_prev_combo = _score.combo   # Score 가 아직 갱신 전이라 '직전' 값이다
	_popup.text = Judge.verdict_name(v)
	if is_finite(delta_ms):
		_popup.text += "  %+.0fms" % delta_ms
		_timing_bar.push(delta_ms)
	_popup.position = _positions[mini(_vis, _positions.size() - 1)] + Vector2(-60, -80)

	var vc := _verdict_color(v)
	# 밟은 타일이 판정 색으로 부풀었다 사라진다. 어느 타일을 어떻게 밟았는지가
	# 경로 위에 그대로 남아서, 다음 구간을 준비하면서도 직전 결과를 읽을 수 있다.
	_path.impact(tile, vc)
	match v:
		Judge.Verdict.PERFECT:
			_planets.flash(vc)
		Judge.Verdict.EARLY_PERFECT, Judge.Verdict.LATE_PERFECT:
			_planets.flash(vc)
		Judge.Verdict.VERY_EARLY, Judge.Verdict.VERY_LATE:
			_planets.flash(vc)
		_:
			_planets.flash(vc)
			# 콤보가 실제로 끊길 때만 흔든다. 이미 끊긴 상태에서 계속 미스하는 건
			# 잃을 게 없으므로 흔들 이유도 없다. (on_judged 가 먼저 불려서
			# 여기 도달할 땐 combo 가 이미 0 이므로 직전 값을 쓴다)
			if _prev_combo >= SHAKE_MIN_COMBO:
				_shake = SHAKE_STRENGTH
				_shake_t = 0.0


func _on_song_finished(failed := false) -> void:
	if _finished:
		return
	_finished = true
	AudioClock.stop()
	_countdown.text = ""
	_popup.text = ""
	var s := _score.delta_stats()

	var acc := _score.accuracy()
	var rank := "F" if failed else _score.rank()
	_r_rank.text = rank
	_r_acc.text = "정확도 %.2f%%" % acc
	if failed:
		_r_headline.text = "실패 — 정확도 %.0f%% 아래" % fail_below_accuracy
		_r_headline.modulate = Color(1.2, 0.45, 0.45)
		_r_rank.modulate = Color(1.2, 0.45, 0.45)
	else:
		_r_headline.text = _headline_for(acc)
		_r_headline.modulate = Color(1.0, 0.95, 0.7)
		_r_rank.modulate = Color(1.15, 1.05, 0.7)
	_r_break.text = (
		"너무 빠름 %d    빠름 %d    빠름! %d\n" % [
			_score.count_of(Judge.Verdict.TOO_EARLY),
			_score.count_of(Judge.Verdict.VERY_EARLY),
			_score.count_of(Judge.Verdict.EARLY_PERFECT)]
		+ "정확 %d\n" % _score.count_of(Judge.Verdict.PERFECT)
		+ "느림! %d    느림 %d    너무 느림 %d\n\n" % [
			_score.count_of(Judge.Verdict.LATE_PERFECT),
			_score.count_of(Judge.Verdict.VERY_LATE),
			_score.count_of(Judge.Verdict.TOO_LATE)]
		+ "최대 콤보 %d    ·    타일 %d / %d\n" % [
			_score.max_combo, _score.total, _hit_times.size() - 1]
		+ "판정 오차 평균 %+.1fms   표준편차 %.1fms" % [s.mean, s.sd]
	)
	_result.visible = true

	print("[결과] %s%s | 표본 %d | 평균 %+.1fms | 표준편차 %.1fms | 역행 %d회 최대 %.3fms"
		% ["실패 " if failed else "", _score.summary_line(), s.n, s.mean, s.sd,
		   AudioClock.clamp_hits, AudioClock.max_backstep_ms])


static func _headline_for(acc: float) -> String:
	if acc >= 100.0: return "완벽한 플레이!"
	if acc >= 99.0: return "거의 완벽!"
	if acc >= 95.0: return "훌륭한 클리어"
	if acc >= 90.0: return "클리어"
	if acc >= 70.0: return "완주"
	return "완주 — 다시 해보자"


func _on_offset_changed(v: float) -> void:
	AudioClock.user_offset_ms = v
	_offset_label.text = "오프셋 %+.0f ms" % v


# ------------------------------------------------------------------ HUD
func _update_hud(t: float) -> void:
	_hud_score.text = _score.summary_line()
	_combo_label.text = str(_score.combo) if _score.combo > 0 else ""
	if _score.combo == 0:
		_verdict_label.text = ""

	# 시작 카운트다운 — 첫 타일까지 남은 박자
	if _hit_times.size() > 1 and t < _hit_times[1]:
		var spb := 60000.0 / chart.bpm
		var left := (_hit_times[1] - t) / spb
		if left <= COUNTDOWN_BEATS:
			_countdown.text = str(int(ceil(left)))
			_countdown.modulate = Color(1.0, 0.95, 0.7, clampf(left - floorf(left), 0.25, 1.0))
		else:
			_countdown.text = ""
	elif _countdown.text != "" and _countdown.text != "GO":
		_countdown.text = "GO"
		_countdown.modulate = Color(0.6, 1.2, 0.8)
		_go_until = t + 400.0
	elif _countdown.text == "GO" and t > _go_until:
		_countdown.text = ""

	# 체감 BPM = 타일 BPM / 현재 홉 박자.
	# 1/6박 홉을 340bpm 으로 밟으면 체감 2040 이다. 얼불춤 오버레이가 보여주는 값이고,
	# 판정창이 왜 좁아져야 하는지를 화면에서 바로 보여준다.
	# 타일 BPM 은 속도 타일(토끼/달팽이)이 적용된 '실효' 값이다.
	# 체감 BPM = 실효 BPM / 현재 홉 박자 — 1/6박 홉을 340 으로 밟으면 2040 이 된다.
	var hop := ChartRuntime.beats_to_reach(chart.angles, _idx,
		ChartRuntime.spin_at(chart, maxi(_idx - 1, 0)))
	var ebpm := ChartRuntime.effective_bpm_at(chart, maxi(_idx - 1, 0))
	var felt := ebpm / hop if hop > 0.0 else ebpm
	var mult := ChartRuntime.speed_mult_at(chart, maxi(_idx - 1, 0))
	var tag := ""
	if not is_equal_approx(mult, 1.0):
		tag = "  %s x%g" % ["토끼" if mult > 1.0 else "달팽이", mult]
	_hud_info.text = "음악 %s / %s\n타일 BPM %.0f%s   체감 BPM %.0f\n타일 %d / %d" % [
		_fmt_time(t), _fmt_time(_song_len_ms), ebpm, tag, felt,
		_idx, _hit_times.size() - 1]

	var s := _score.delta_stats()
	_timing_label.text = "판정창 ±%.0fms (Perfect ±%.0f)   표본 %d   평균 %+.1f   σ %.1f" % [
		_judge.miss_ms, _judge.perfect_ms, s.n, s.mean, s.sd]

	_debug.text = "역행 %d회 (최대 %.2fms)   output_latency %.1fms   fps %d" % [
		AudioClock.clamp_hits, AudioClock.max_backstep_ms,
		AudioClock.output_latency_ms(), Engine.get_frames_per_second()]


static func _fmt_time(ms: float) -> String:
	var sec := maxf(ms, 0.0) / 1000.0
	return "%d:%02d" % [int(sec) / 60, int(sec) % 60]
