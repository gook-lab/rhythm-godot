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

## 실패는 체력으로 판정한다(Score.health). 정확도 기반이 아니다 —
## 정확도는 누적이라 한 번 떨어지면 회복이 안 되고, 초반 미스 몇 개로 끝나버린다.
## 체력은 미스 -7, 정확 +1.6 이라 14연속 미스면 죽지만 잘 치면 돌아온다.
## 그리고 플레이어가 한 번도 안 눌렀으면 아예 깎지 않는다(Score.started).

## 시작 카운트다운을 보여줄 박자 수. 인트로가 16박이라 전부 세면 지루하다.
const COUNTDOWN_BEATS := 4

## 체크포인트 부활 시 그 타일보다 얼마나 앞에서 다시 시작하나(ms).
## 정확히 그 타일에 떨어뜨리면 되살아나는 순간이 곧 판정 순간이라 못 친다.
const REVIVE_LEAD_MS := 1600.0

## 마지막 타일을 밟고 결과 화면이 뜨기까지의 여유(ms).
## 0 이면 마지막 히트와 동시에 결과가 떠서 곡이 잘리는 느낌이 난다 —
## 실플레이 피드백 그대로다. 이 동안(그리고 결과가 뜬 뒤에도) 음악은
## 끊지 않고 자연히 끝까지 재생한다. 끊는 건 실패했을 때뿐이다.
const OUTRO_GRACE_MS := 1500.0

@export var chart: Chart

@onready var _path: TilePath = $World/Path
@onready var _camera: Camera2D = $World/Camera2D
@onready var _planets: PlanetPair = $World/PlanetPair
@onready var _popup: Label = $World/JudgmentPopup
@onready var _keyviewer = $UI/KeyViewer
@onready var _bg_mat: ShaderMaterial = $Background/BgRect.material
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
@onready var _judge_mode_label: Label = $UI/JudgeModeLabel
@onready var _result: PanelContainer = $UI/ResultPanel
@onready var _r_headline: Label = $UI/ResultPanel/Margin/VBox/Headline
@onready var _r_rank: Label = $UI/ResultPanel/Margin/VBox/Rank
@onready var _r_acc: Label = $UI/ResultPanel/Margin/VBox/Accuracy
@onready var _r_break: Label = $UI/ResultPanel/Margin/VBox/Breakdown
@onready var _health: ProgressBar = $UI/HealthBar
@onready var _pause_panel: PanelContainer = $UI/PausePanel
@onready var _song_progress: ProgressBar = $UI/SongProgress
@onready var _hud_progress: Label = $UI/HUD/ProgressLabel
@onready var _hitsound: AudioStreamPlayer = $HitSound
@onready var _misssound: AudioStreamPlayer = $MissSound

var _hit_times := PackedFloat32Array()
var _positions := PackedVector2Array()
## 고스트(자동 통과) 타일 집합. 판정 커서가 여기엔 절대 머물지 않는다.
var _ghosts := {}
## 판정 대상 타일 수 (고스트 제외). HUD 의 '타일 x / y' 분모.
var _judged_total := 0
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

## 이번 판에 체크포인트를 몇 번 썼나. 결과 화면에 밝힌다 —
## 안 밝히면 무한 부활로 낸 S 랭크와 한 번에 낸 S 랭크가 구별되지 않는다.
var _checkpoints_used := 0

## 진행 중인 홀드. -1 이면 없음.
## _hold_key 를 같이 들고 있어야 하는 이유: 판정키가 거의 모든 키라서
## (양손 교타) '아무 키나 떼면 홀드 종료'로 하면 다른 손의 탭이 홀드를 끊는다.
var _hold_tile := -1
var _hold_key := 0
var _hold_end_ms := 0.0

## ── 리플레이 ─────────────────────────────────────────────────
## 기록은 키 입력이 아니라 '판정 결과'다 — (종류, 타일, delta).
## 재생은 기록된 delta 를 그대로 먹이므로 점수·등급·산포가 비트 단위로
## 재현된다. 프레임 양자화로 몇 ms 늦게 발화해도 판정은 안 흔들린다 —
## 시각을 다시 재는 게 아니라 delta 를 재판정하니까.
## 미스와 체크포인트 부활은 기록하지 않는다: 같은 판정 열이면 감시자와
## 체력이 알아서 같은 자리에서 재현한다(부활의 되감기도 순차 재생이 견딘다 —
## 발화 조건이 '클럭 >= 목표시각'이라 클럭이 되감겨도 다음 이벤트가 기다린다).
## 전 타일 판정 완료 후 결과 화면까지의 유예 상태.
var _outro := false
var _outro_at := 0.0

var _rec: Array = []            # 이번 판의 기록 [[종류, 타일, delta], ...]
var _last_replay: Array = []    # 마지막 실플레이 기록 (결과 화면 V)
var _replay_mode := false
var _replay_idx := 0

## 오토플레이 데모 — 매 타일을 delta 0 으로 밟는 봇. 채보 감상·검수용이다.
## "항상 정확"이 요구사항이라 사람 입력 경로의 프레임 오차조차 안 태운다:
## 기록된 delta 를 먹이는 리플레이와 같은 통로(_apply_press)에 0 을 먹인다.
var _auto_mode := false

## 마지막 프레임의 공전 진행률. 회귀 테스트가 읽는다 —
## 이 값이 1.0 에 오래 붙어 있으면 행성이 얼어 있다는 뜻이다.
var _last_u := 0.0

## 곡 선택 화면을 거친 실플레이인가. 테스트 러너들은 chart 를 직접 주입하고
## selected_chart 를 비워 둔다 — 그 경로에선 기록·바인딩·저장 오프셋을
## 일절 건드리지 않는다. 사용자의 저장 파일이 테스트 결과를 흔들지도
## (바인딩이 SPACE 를 막으면 InputRunner 가 깨진다), 테스트 플레이가
## 기록을 오염시키지도 않게 하기 위해서다.
var _real_play := false


func _ready() -> void:
	# 곡 선택 화면이 고른 차트가 있으면 그걸 쓴다. 없으면(테스트·직접 실행) 인스펙터 값.
	if GameState.selected_chart != "":
		var c: Chart = load(GameState.selected_chart)
		if c != null:
			chart = c
			_real_play = true
	if chart == null or not chart.is_valid():
		push_error("Main.chart 가 비었거나 불완전하다. 인스펙터에서 .tres 를 물려라.")
		set_process(false)
		set_process_input(false)
		return

	_hit_times = ChartRuntime.hit_times_ms(chart)
	_positions = ChartRuntime.tile_positions(chart.angles, TILE_SPACING)
	for g in chart.ghost_tiles:
		_ghosts[int(g)] = true
	# 홀드는 밟기와 떼기 두 번 판정된다 — 분모도 두 번 세야 100% 가 나온다.
	var hold_n := 0
	for k in range(chart.hold_tiles.size()):
		if chart.hold_tiles[k].y > 0.0:
			hold_n += 1
	_judged_total = _hit_times.size() - 1 - _ghosts.size() + hold_n
	_song_len_ms = chart.audio.get_length() * 1000.0
	_draw_path()

	# 저장된 캘리브레이션을 복원한다 — 잰 값을 매번 다시 재게 하면
	# 캘리브레이션이 아니라 고문이다. (connect 전이라 신호는 안 난다)
	if _real_play:
		_offset_slider.value = Records.offset_ms
		_load_replay()   # 지난 세션의 마지막 완주도 V 로 볼 수 있게
	_offset_slider.value_changed.connect(_on_offset_changed)
	_on_offset_changed(_offset_slider.value)
	# 순서 중요: Main 이 '끊기기 직전 콤보'를 알아야 하므로 Score 보다 먼저 받는다.
	_judge.judged.connect(_on_judged)
	_judge.judged.connect(_score.on_judged)
	AudioClock.song_finished.connect(_on_song_finished)

	_restart()


func _toggle_pause() -> void:
	_paused = not _paused
	AudioClock.set_paused(_paused)
	_pause_panel.visible = _paused


func _restart() -> void:
	_paused = false
	AudioClock.set_paused(false)
	_pause_panel.visible = false
	_idx = _next_judged(1)
	_vis = 1
	_finished = false
	_shake = 0.0
	_shake_t = 0.0
	_prev_combo = 0
	_checkpoints_used = 0
	_hold_tile = -1
	_replay_idx = 0
	_outro = false
	_keyviewer.reset()
	_bg_flash = 0.0
	# 설정 적용. 실플레이만 — 러너가 사용자의 판정 모드·볼륨에 좌우되면
	# 테스트가 기계마다 다르게 죽는다(save_path 격리와 같은 규약).
	_judge.strict_scale = Records.judge_scale() if _real_play else 1.0
	_refresh_judge_mode_label()
	AudioClock.set_music_volume(Records.music_vol if _real_play else 1.0)
	var sv := Records.sfx_vol if _real_play else 1.0
	# 기본 -4dB 트림: 히트 킥이 곡과 같은 크기면 매 탭이 곡을 덮는다
	# ("클릭이 너무 크다" 실사용 피드백). 세부는 설정의 효과음 볼륨으로.
	_hitsound.volume_db = (linear_to_db(maxf(sv, 0.001)) - 4.0) \
		if sv > 0.001 else -80.0
	_misssound.volume_db = _hitsound.volume_db
	if _bg_mat != null:
		_bg_mat.set_shader_parameter("tint",
			_SELECT._diff_color(chart.difficulty))
	if not _replay_mode:
		_rec = []
	_popup.text = ""
	_score.reset()   # 표본(deltas)은 남긴다 — 산포 측정이 세션 단위다
	_planets.clear_trails()
	_path.clear_impacts()
	_result.visible = false
	_song_progress.value = 0.0
	_hud_progress.text = ""
	_countdown.text = ""
	_verdict_label.text = ""
	_combo_label.text = ""
	_configure_orbit(1)
	_apply_windows(_idx)
	_planets.set_orbit_progress(0.0)
	# 카메라를 시작 위치에 미리 놓고 스무딩 이력을 지운다.
	# 안 하면 워밍업 동안 (0,0) 에 있다가 warm 되는 첫 프레임에
	# 미드포인트로 48px(반지름의 절반) 순간이동한다.
	_camera.position = _camera_target(1, 0.0)
	_camera.offset = Vector2.ZERO
	_camera.reset_smoothing()
	_path.set_view(_camera.position, 1050.0)
	AudioClock.start(chart.audio)


func _draw_path() -> void:
	_path.setup(_positions, chart.angles, TILE_SPACING, chart)


## 렌더: 타일 i 로 가는 공전을 세팅한다. (렌더 커서 _vis 를 따른다)
func _configure_orbit(i: int) -> void:
	if i <= 0 or i >= chart.angles.size():
		return
	# 회전 방향(twirl)은 축 타일(i-1)의 상태를 따른다. 스윕 부호가 곧 방향이다.
	# 중간회전은 그 타일 자신의 성질이라 i 로 조회한다 — 시작각이 180도 달라진다.
	var spin := ChartRuntime.spin_at(chart, i - 1)
	var mid := ChartRuntime.is_midspin(chart, i)
	var off := ChartRuntime.chart_offset_deg(chart)
	# 축 타일에 홀드가 걸려 있으면 떠나기 전에 그만큼 더 돈다.
	# 360도의 배수라 끝나는 각도가 같다 — 착지 불변식이 안 깨진다.
	var extra := 360.0 * ChartRuntime.hold_orbits_at(chart, i - 1) \
		* (1.0 if spin >= 0 else -1.0)
	# 삼행성이면 세 번째는 직전 타일에 선다. 연속 타일은 정의상 spacing 만큼
	# 떨어져 있어서 축에서 본 거리가 도는 행성과 같다.
	var third := Vector2.INF
	if chart.planet_count >= 3 and i >= 2:
		third = _positions[i - 2]
	_planets.configure(
		_positions[i - 1],
		ChartRuntime.orbit_start_deg(chart.angles, i, mid, off),
		ChartRuntime.orbit_sweep_deg(chart.angles, i, spin, mid, off) + extra,
		TILE_SPACING, third)


## 판정: 타일 i 의 판정창을 이웃까지의 거리로 캡한다. (판정 커서 _idx 를 따른다)
## 이게 없으면 빠른 구간에서 창이 겹쳐 한 번 누른 입력이 두 타일 모두에 유효해진다.
func _apply_windows(i: int) -> void:
	if i >= _hit_times.size():
		return
	var before := _gap_before(i)
	_judge.set_gaps(before, _gap_after(i))
	_timing_bar.set_windows(_judge.perfect_ms, _judge.very_ms, _judge.miss_ms)
	# 체력은 '타일 몇 개'가 아니라 '몇 초'로 센다(Score 주석 참조).
	# 이 타일이 차지한 음악 시간을 넘겨야 밀도가 사망 속도를 바꾸지 않는다.
	# 첫 타일은 앞이 카운트인이라 간격이 INF/과대다 — 기본값을 그대로 둔다.
	if is_finite(before):
		_score.interval_sec = before / 1000.0


## 판정창 캡은 '판정되는 이웃'까지의 거리여야 한다. 고스트는 밟지 않으므로
## 고스트까지의 간격으로 캡하면 창이 이유 없이 절반으로 좁아진다.
func _gap_before(i: int) -> float:
	if i <= 0 or i >= _hit_times.size():
		return INF
	var j := i - 1
	while j > 0 and _ghosts.has(j):
		j -= 1
	return _hit_times[i] - _hit_times[j]


func _gap_after(i: int) -> float:
	var j := i + 1
	while j < _hit_times.size() and _ghosts.has(j):
		j += 1
	if i >= _hit_times.size() or j >= _hit_times.size():
		return INF
	return _hit_times[j] - _hit_times[i]


## i 이상에서 첫 판정 대상(비고스트) 타일.
func _next_judged(i: int) -> int:
	while i < _hit_times.size() and _ghosts.has(i):
		i += 1
	return i


# ------------------------------------------------------------------ 감시자
func _process(delta: float) -> void:
	# 화면 흔들림은 오디오 클럭과 무관한 순수 연출이라 프레임 시간으로 감쇠시킨다.
	if _shake > 0.01:
		_shake_t += delta
		_shake = maxf(0.0, _shake - delta * SHAKE_DECAY)

	_bg_flash = maxf(0.0, _bg_flash - delta * 3.5)
	_update_background()

	if _paused or _finished or not AudioClock.is_warm():
		return
	var t := AudioClock.judged_ms()

	# ── 오토플레이 데모: 매 타일을 그 시각에 delta 0 으로 밟는다.
	if _auto_mode:
		while _idx < _hit_times.size() and t >= _hit_times[_idx]:
			_apply_press(_idx, 0.0, KEY_SPACE)
		if _hold_tile >= 0 and t >= _hold_end_ms:
			_release_hold(0.0)

	# ── 리플레이: 기록된 판정을 그 시각에 다시 먹인다.
	# 감시자보다 먼저 돌아야 한다 — 프레임 양자화로 발화가 몇 ms 밀릴 때
	# 같은 프레임의 감시자가 그 타일을 미스로 채가면 안 된다.
	if _replay_mode:
		while _replay_idx < _last_replay.size():
			var ev: Array = _last_replay[_replay_idx]
			var tile := int(ev[1])
			var d := float(ev[2])
			if String(ev[0]) == "p":
				if _idx > tile:
					_replay_idx += 1   # 경계에서 감시자가 선점 — 기록상 다음으로
					continue
				if _idx != tile or t < _hit_times[tile] + d:
					break
				_replay_idx += 1
				_apply_press(tile, d, KEY_SPACE)
			else:
				if _hold_tile < 0:
					_replay_idx += 1   # 홀드가 이미 닫혔다(감시자 미스)
					continue
				if t < _hold_end_ms + d:
					break
				_replay_idx += 1
				_release_hold(d)

	# ── 판정 커서: 기한이 지난 타일을 Miss 로 확정하고 전진한다.
	# while 인 이유: 랙 스파이크가 나면 한 프레임에 여러 타일이 동시에 만료된다.
	while _idx < _hit_times.size() and t > _hit_times[_idx] + _judge.miss_ms:
		_judge.emit_miss(_idx)
		_advance()

	# ── 홀드: 떼야 할 시각을 넘기면 뗌을 미스로 확정한다.
	# 탭과 대칭이다 — 안 누른 것도, 안 뗀 것도 이벤트가 없으니 감시자가 낸다.
	if _hold_tile >= 0 and t > _hold_end_ms + _judge.miss_ms:
		var ht := _hold_tile
		_hold_tile = -1
		_judge.emit_miss(ht)

	# ── 렌더 커서: 시간이 지나면 그냥 전진한다. 미스 기한을 기다리지 않는다.
	# 이게 판정 커서와 붙어 있으면 행성이 매 타일 miss_ms 만큼 얼어붙는다.
	while _vis < _hit_times.size() and t >= _hit_times[_vis]:
		_vis += 1
		_planets.swap_roles()
		_configure_orbit(_vis)

	if _score.is_dead():
		if not _revive_at_checkpoint():
			_on_song_finished(true)
		return

	if _idx >= _hit_times.size():
		# 전부 판정됐다. 바로 결과를 띄우지 않는다 — 마지막 히트의 여운이
		# 남아 있고 음악도 아직 흐른다. 유예 뒤에 결과만 얹고 곡은 계속 튼다.
		if not _outro:
			_outro = true
			_outro_at = t + OUTRO_GRACE_MS
		if t >= _outro_at:
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
	# 가상 렌더링: 경로가 화면 근처 타일만 그리게 카메라 중심을 알려준다.
	# 반지름 = 뷰포트 반대각(~734px) + 이동 마진.
	_path.set_view(_camera.position, 1050.0)

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
	if k.echo:
		return
	# '뗌'은 홀드에서만 의미가 있다. pressed 필터보다 먼저 봐야 한다 —
	# 아래로 내려가면 not k.pressed 에서 통째로 버려진다.
	if not k.pressed:
		_keyviewer.note_release(k.keycode)
		# 리플레이 중 실제 손이 키를 떼도 재생 중인 홀드를 끊으면 안 된다.
		if _hold_tile >= 0 and k.keycode == _hold_key and not _replay_mode:
			_release_hold(AudioClock.judged_ms() - _hold_end_ms)
		return
	if k.keycode == KEY_ESCAPE:
		if _finished:
			get_tree().change_scene_to_file("res://scenes/SongSelect.tscn")
		else:
			_toggle_pause()
		return
	# 곡 중간에 그만두고 싶을 때: ESC(일시정지) -> Q. 실수로 한 번에
	# 못 나가게 두 단계로 둔다 — 판정키가 거의 모든 키라 오폭이 잦다.
	if k.keycode == KEY_Q and _paused:
		get_tree().change_scene_to_file("res://scenes/SongSelect.tscn")
		return
	if k.keycode == KEY_R:
		_replay_mode = false   # 리플레이/오토 중 R = 끝내고 직접 친다
		_auto_mode = false
		_restart()
		return
	if k.keycode == KEY_V and _finished and _last_replay.size() > 0:
		_start_replay()
		return
	# 오토플레이 데모: 결과·일시정지 화면에서 O. 봇이 전 타일을 delta 0 으로
	# 밟는다 — 채보를 눈과 귀로 검수하는 모드다. 기록·리플레이엔 안 남는다.
	if k.keycode == KEY_O and (_finished or _paused):
		_replay_mode = false
		_auto_mode = true
		_restart()
		return
	# 자동 보정: 결과 화면에서 A — 이번 판의 평균 오차를 오프셋에 얹는다.
	# 평균이 +80ms 인데 슬라이더를 손으로 더듬게 하면 캘리브레이션이 아니라
	# 고문이다(블루투스 이어폰은 150~250ms 가 예사다).
	if k.keycode == KEY_A and _finished:
		var st := _score.delta_stats()
		if st.n >= 4 and absf(float(st.mean)) >= 10.0:
			_offset_slider.value = clampf(
				_offset_slider.value + float(st.mean),
				_offset_slider.min_value, _offset_slider.max_value)
		return
	if _paused or _finished:
		return
	if _replay_mode or _auto_mode:
		return   # 리플레이·오토는 보는 시간이다 — 판정 입력을 받지 않는다
	# 판정키 필터. 기본(바인딩 없음)은 얼불춤처럼 거의 모든 키 — 양손 교타가
	# 가능해야 빠른 구간에서 손맛이 산다. 곡 선택 화면의 K 메뉴에서 키를
	# 지정했으면 그 키들만 받는다. 테스트·직접 실행은 항상 '전부 허용'이다 —
	# 러너들이 사용자의 저장 바인딩에 좌우되면 안 된다.
	if _real_play:
		if not Records.is_judgment_key(k.keycode):
			return
	elif k.keycode in Records.NEVER_JUDGE:
		return
	_keyviewer.note_press(k.keycode)
	# 입력 즉시 히트사운드 — 판정보다 빠른 피드백. 곡의 클릭과 내 입력음의
	# 어긋남이 곧 내 오차라서, 이게 손맛 캘리브레이션의 핵심 도구다.
	# 실제 음악에서는 타일이 멜로디 온셋 위라 겹쳐 들린다 — 곡 선택 화면 M 키로 끈다.
	if Records.sfx_enabled:
		_hitsound.play()
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

	_apply_press(_idx, delta, k.keycode)


## 마지막 기록을 재생한다. 판정 입력은 막히고(_input 가드) 기록이 대신 친다.
func _start_replay() -> void:
	_replay_mode = true
	_restart()


const REPLAY_DIR := "user://replays"


func _replay_file() -> String:
	var base := chart.resource_path.get_file().get_basename()
	if base == "":
		base = chart.title   # 테스트 주입 차트(resource_path 없음) 폴백
	return REPLAY_DIR + "/" + base + ".json"


## 실플레이(_real_play)만 디스크에 남긴다 — 테스트 러너가 사용자 파일을
## 오염시키면 안 된다는 규약(InputRunner 머리말)과 같은 이유다.
func _save_replay() -> void:
	DirAccess.make_dir_recursive_absolute(REPLAY_DIR)
	var f := FileAccess.open(_replay_file(), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"chart": chart.resource_path,
		"acc": _score.accuracy(),
		"rank": _score.rank(),
		"events": _last_replay,
	}))


func _load_replay() -> void:
	var f := FileAccess.open(_replay_file(), FileAccess.READ)
	if f == null:
		return
	var d: Variant = JSON.parse_string(f.get_as_text())
	if d is Dictionary and d.get("events") is Array:
		_last_replay = d["events"]


## 밟기의 공통 코어. 실입력(_input)과 리플레이가 같은 경로를 탄다 —
## 갈라두면 언젠가 한쪽만 고쳐져 리플레이가 거짓말을 하게 된다.
func _apply_press(tapped: int, delta: float, keycode: int) -> void:
	if _replay_mode or _auto_mode:
		_keyviewer.note_tap(keycode)   # 키 이벤트가 없는 유일한 입력 소스
		if Records.sfx_enabled:
			_hitsound.play()   # 실입력은 _input 이 이미 냈다(판정 전 즉시 피드백)
	_judge.judge_input(delta, tapped)
	if not _replay_mode and not _auto_mode:
		_rec.append(["p", tapped, delta])
	_advance()
	# 홀드 타일이면 여기서 '누르고 있기'가 시작된다.
	# 미스로 밟은 경우에도 시작한다 — 안 그러면 한 번 놓친 뒤 남은 홀드가
	# 통째로 사라져서 화면(행성은 계속 돈다)과 판정이 어긋난다.
	var orbits := ChartRuntime.hold_orbits_at(chart, tapped)
	if orbits > 0.0:
		_hold_tile = tapped
		_hold_key = keycode
		if _replay_mode or _auto_mode:
			_keyviewer.sustain(keycode)   # 탭 플래시를 홀드 지속으로 승격
		_hold_end_ms = _hit_times[tapped] + ChartRuntime.hold_beats_at(chart, tapped) \
			* (60000.0 / chart.bpm) / ChartRuntime.speed_mult_at(chart, tapped)


## 체력이 바닥났을 때 마지막으로 지난 체크포인트에서 되살린다.
## 되살릴 곳이 없으면 false — 호출자가 실패 화면을 띄운다.
##
## 곡을 되감는 유일한 경로다. AudioClock.seek() 가 단조 클램프 이력을 버리므로
## 클럭이 얼어붙지 않는다(그 주석 참조).
func _revive_at_checkpoint() -> bool:
	var cp := -1
	for k in range(chart.checkpoint_tiles.size()):
		var t := int(chart.checkpoint_tiles[k])
		if t <= _idx and t > cp and t < _hit_times.size():
			cp = t
	if cp < 1:
		return false

	_checkpoints_used += 1
	_hold_tile = -1
	# 체크포인트 '조금 앞'으로 간다. 정확히 그 타일에 떨어뜨리면 되살아나는
	# 순간이 곧 판정 순간이라 손을 올릴 시간이 없다. 카운트인과 같은 이유다.
	var lead := minf(REVIVE_LEAD_MS, _hit_times[cp] - _hit_times[0])
	_idx = _next_judged(cp)
	_vis = cp
	_score.revive()
	_planets.clear_trails()
	_path.clear_impacts()
	_popup.text = ""
	_verdict_label.text = ""
	_combo_label.text = ""
	_configure_orbit(_vis)
	_apply_windows(_idx)
	_camera.position = _camera_target(_vis, 0.0)
	_camera.offset = Vector2.ZERO
	_camera.reset_smoothing()
	_shake = 0.0
	AudioClock.seek(_hit_times[cp] - lead)
	return true


## 홀드를 끝낸다. delta 는 (뗀 시각 - 떼야 할 시각).
##
## 뗌도 밟는 것과 같은 판정창을 쓴다 — 그래야 홀드가 '누르고 기다리기'가 아니라
## 리듬이 된다. 판정 수가 하나 늘어나므로 _judged_total 도 홀드를 두 번 센다.
func _release_hold(delta: float) -> void:
	var tile := _hold_tile
	_keyviewer.note_release(_hold_key)
	_hold_tile = -1
	if not AudioClock.is_warm() or _finished:
		return
	_judge.judge_input(delta, tile)
	if not _replay_mode and not _auto_mode:
		_rec.append(["r", tile, delta])


## 판정 커서만 전진시킨다. 행성 역할 교체와 공전 재설정은 렌더 커서가 한다.
## 고스트 타일은 판정이 없으므로 건너뛴다 — 커서는 항상 다음 '밟을' 타일을 본다.
func _advance() -> void:
	_idx = _next_judged(_idx + 1)
	_apply_windows(_idx)


var _prev_combo := 0

## Perfect 순간 배경이 잠깐 밝아졌다 감쇠한다(셰이더 flash 유니폼).
var _bg_flash := 0.0

## 난이도 색 램프는 곡 선택과 같은 정의를 쓴다 — 배경 틴트가 목록의
## 난이도 색과 같아야 '이 곡의 색'으로 읽힌다.
const _SELECT := preload("res://scripts/SongSelect.gd")
var _go_until := 0.0
var _paused := false


static func _verdict_color(v: Judge.Verdict) -> Color:
	match v:
		Judge.Verdict.PERFECT: return Color(0.50, 1.20, 0.72)
		Judge.Verdict.EARLY_PERFECT, Judge.Verdict.LATE_PERFECT: return Color(0.78, 1.12, 0.52)
		Judge.Verdict.VERY_EARLY, Judge.Verdict.VERY_LATE: return Color(1.15, 0.95, 0.44)
		_: return Color(1.20, 0.39, 0.39)


## 시작 시 판정 엄격도 체크 — 지금 어떤 창으로 채점되는지를 곡이 시작되기
## 전에 화면으로 확인시킨다. 설정 창에서 바꾼 걸 잊고 '왜 이렇게 후하지/
## 짜지?' 하는 상태를 없애는 게 목적이라, 값(±ms)까지 같이 쓴다.
func _refresh_judge_mode_label() -> void:
	if not _real_play:
		_judge_mode_label.text = ""   # 러너 화면엔 노이즈다
		_judge_mode_label.visible = false
		return
	var sc := _judge.strict_scale
	_judge_mode_label.text = "판정 %s  ·  미스 ±%.0fms · Perfect ±%.0fms" % [
		Records.JUDGE_NAMES.get(Records.judge_mode, "?"),
		_judge.base_miss_ms * sc, _judge.base_perfect_ms * sc]
	_judge_mode_label.visible = true
	if sc > 1.01:
		_judge_mode_label.self_modulate = Color(0.55, 0.95, 0.65)   # 관대 = 초록
	elif sc < 0.99:
		_judge_mode_label.self_modulate = Color(1.0, 0.55, 0.5)     # 엄격 = 빨강
	else:
		_judge_mode_label.self_modulate = Color(0.62, 0.68, 0.8)    # 보통 = 중립


## 배경 셰이더에 비트 위상·에너지를 먹인다. 배경이 스스로 시간을 세지
## 않는 이유: 일시정지·시크에서 음악과 어긋난 채 혼자 고동치면 박자를
## 방해한다 — 위상은 항상 AudioClock 에서 파생한다.
func _update_background() -> void:
	if _bg_mat == null:
		return
	var phase := 0.9   # 재생 밖(일시정지·결과)에서는 고동 끝자락에 고정
	if not _paused and not _finished and AudioClock.is_warm() \
			and _hit_times.size() > 1:
		var spb := 60000.0 / chart.bpm
		phase = fposmod(AudioClock.judged_ms() - _hit_times[0], spb) / spb
	_bg_mat.set_shader_parameter("beat_phase", phase)
	_bg_mat.set_shader_parameter("energy",
		clampf(_score.combo / 40.0, 0.0, 1.0))
	_bg_mat.set_shader_parameter("flash", _bg_flash)


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
			# 1.0 리셋으로 두면 초당 5탭 구간에서 스트로브가 된다 —
			# maxf + 낮은 상한으로 '은은한 여운'까지만.
			_bg_flash = maxf(_bg_flash, 0.5)
		Judge.Verdict.EARLY_PERFECT, Judge.Verdict.LATE_PERFECT:
			_planets.flash(vc)
			_bg_flash = maxf(_bg_flash, 0.3)
		Judge.Verdict.VERY_EARLY, Judge.Verdict.VERY_LATE:
			_planets.flash(vc)
		_:
			# 놓친 타일의 소리. 감시자 미스는 키 입력이 없어서 히트사운드가
			# 안 난다 — 이게 없으면 미스가 화면으로만 오고 귀로는 안 온다.
			if Records.sfx_enabled:
				_misssound.play()
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
	# 완주면 음악을 끊지 않는다 — 결과 위로 자연히 끝까지 흐른다.
	# 실패는 끊는 게 맞다: 죽었는데 곡이 계속 나오면 죽은 줄 모른다.
	if failed:
		AudioClock.stop()
	_countdown.text = ""
	_popup.text = ""
	# 이번 판이 실플레이 기록이면 리플레이로 보관한다(결과 화면 V).
	if not _replay_mode and not _auto_mode and _rec.size() > 0:
		_last_replay = _rec.duplicate(true)
		if _real_play:
			_save_replay()
	var s := _score.delta_stats()

	var acc := _score.accuracy()
	var rank := "F" if failed else _score.rank()
	if _replay_mode:
		_r_headline.modulate = Color(0.7, 0.9, 1.0)
	var prog := clampf(_progress_pct(), 0.0, 100.0)
	# 레이팅·배지 (adofai.gg 차용). 실패는 레이팅 0 — '클리어의 질'의 지표라서다.
	# PP = 전 판정 PERFECT · FC = 미스 없음. 체크포인트를 썼으면 배지 없음 —
	# 부활로 이어붙인 노미스는 노미스가 아니다.
	var rating := 0.0 if failed else Records.play_rating(chart.difficulty, acc)
	var badge := ""
	if not failed and _checkpoints_used == 0 and _score.total > 0:
		var misses := _score.count_of(Judge.Verdict.TOO_EARLY) \
			+ _score.count_of(Judge.Verdict.TOO_LATE)
		if misses == 0:
			badge = "PP" if _score.count_of(Judge.Verdict.PERFECT) == _score.total \
				else "FC"
	_song_progress.value = prog
	_r_rank.text = rank
	_r_acc.text = "정확도 %.2f%%" % acc
	if failed:
		_r_headline.text = "실패 — 진행 %.0f%%" % prog
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
		+ "최대 콤보 %d    ·    타일 %d / %d    ·    진행 %.0f%%\n" % [
			_score.max_combo, _score.total, _judged_total, prog]
		# 체크포인트를 밝히지 않으면 무한 부활로 낸 S 와 한 번에 낸 S 가 같아 보인다.
		+ ("체크포인트 %d회 사용\n" % _checkpoints_used if _checkpoints_used > 0 else "")
		+ ("난이도 %.1f    ·    레이팅 %.1f%s\n" % [chart.difficulty, rating,
			"    ·    ✦ " + badge if badge != "" else ""]
			if chart.difficulty > 0.0 else "")
		# 판정 모드를 밝히지 않으면 관대(x1.4)로 낸 S 와 보통 S 가 같아 보인다.
		+ ("판정 %s (창 x%.1f)\n" % [Records.JUDGE_NAMES.get(Records.judge_mode, "?"),
			_judge.strict_scale]
			if _real_play and absf(_judge.strict_scale - 1.0) > 0.01 else "")
		+ "판정 오차 평균 %+.1fms   표준편차 %.1fms" % [s.mean, s.sd]
		+ ("\n\nV 내 플레이 리플레이" if _last_replay.size() > 0 else "")
		+ "   ·   O 오토플레이 데모"
		+ ("\nA 자동 보정 (평균 %+.0fms 를 오프셋에 반영)" % s.mean
			if s.n >= 4 and absf(s.mean) >= 10.0 and not _replay_mode
				and not _auto_mode else "")
	)
	# 실플레이만 기록에 남긴다(테스트 오염 방지 — _real_play 주석 참고).
	# 무엇이 갱신됐는지가 반환되므로 결과 화면에 '신기록'을 바로 보여줄 수 있다.
	# 리플레이·오토는 기록에 못 오른다 — 실제로 리플레이 실패가 '진행 신기록'을
	# 덮어쓴 사고가 있었다(스크린샷 증거). 본 게 아니라 '친 것'만 기록이다.
	if _real_play and not _replay_mode and not _auto_mode:
		var imp: Dictionary = Records.record_play(
			GameState.selected_chart, acc, rank, _score.max_combo, prog,
			not failed, rating, badge)
		var marks := PackedStringArray()
		if imp.has("first_clear"):
			marks.append("첫 클리어")
		if imp.has("badge") and badge != "":
			marks.append("배지 %s 획득" % badge)
		if imp.has("rating") and rating > 0.0:
			marks.append("레이팅 %.1f (종합 %.1f)" % [rating, Records.total_rating()])
		if imp.has("rank") and str(imp.rank) != "-":
			marks.append("랭크 %s → %s" % [imp.rank, rank])
		if imp.has("acc"):
			marks.append("정확도 신기록 (이전 %.2f%%)" % float(imp.acc))
		if imp.has("combo") and int(imp.combo) > 0:
			marks.append("콤보 신기록 (이전 %d)" % int(imp.combo))
		# 진행도는 미클리어 상태에서만 의미 있는 지표다 — 클리어했으면 항상 100.
		if imp.has("progress") and float(imp.progress) > 0.0 and prog < 100.0:
			marks.append("진행 신기록 (이전 %.0f%%)" % float(imp.progress))
		if not marks.is_empty():
			_r_break.text += "\n\n🏆 " + "  ·  ".join(marks)
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
	# 드래그 중 스텝마다 저장된다. 파일이 1KB 미만이라 비용은 없고,
	# '슬라이더를 만졌으면 저장됐다'는 단순한 규칙이 flush 타이밍 버그를 없앤다.
	if _real_play:
		Records.offset_ms = v
		Records.save()


# ------------------------------------------------------------------ HUD
## 곡 진행도(%). 판정이 끝난 타일 기준이지 시간 기준이 아니다 —
## 얼불춤의 진행도가 이 정의고, 인트로·아웃트로의 무타일 구간이 %를 부풀리지 않는다.
func _progress_pct() -> float:
	if _judged_total <= 0:
		return 0.0
	return 100.0 * float(_score.total) / float(_judged_total)


func _update_hud(t: float) -> void:
	var prog := _progress_pct()
	_song_progress.value = prog
	_hud_progress.text = "%.0f%%" % prog
	_hud_score.text = ("AUTO   " if _auto_mode else "REPLAY   " if _replay_mode else "") \
		+ _score.summary_line()
	_health.value = _score.health
	_health.modulate = Color(1.0, 0.45, 0.45) if _score.health < 30.0 \
		else (Color(1.0, 0.9, 0.5) if _score.health < 60.0 else Color(0.5, 1.0, 0.7))
	_combo_label.text = str(_score.combo) if _score.combo > 0 else ""
	if _score.combo == 0:
		_verdict_label.text = ""

	# 판정 모드 라벨: 카운트인 동안은 또렷하게(시작 전 체크), 곡이 시작되면
	# 보통 모드는 숨기고 관대·엄격만 흐리게 남긴다 — 배율이 걸린 채로
	# 기록을 가는 걸 본인이 모르는 상태가 없어야 한다.
	var in_countin: bool = _hit_times.size() > 1 and t < _hit_times[1]
	if _judge_mode_label.text != "":
		var off_mode := absf(_judge.strict_scale - 1.0) > 0.01
		_judge_mode_label.visible = in_countin or off_mode
		_judge_mode_label.modulate.a = 1.0 if in_countin else 0.55

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
	# 체감 BPM 은 '탭 간격' 기준이다. 고스트가 끼면 홉 박자(1박)와 탭 간격(2박)이
	# 갈라지므로, 홉이 아니라 직전 판정 타일까지의 실제 벽시계 간격으로 잰다.
	var ebpm := ChartRuntime.effective_bpm_at(chart, maxi(_idx - 1, 0))
	var gap := _gap_before(_idx)
	var felt := 60000.0 / gap if is_finite(gap) and gap > 0.0 else ebpm
	var mult := ChartRuntime.speed_mult_at(chart, maxi(_idx - 1, 0))
	var tag := ""
	# 원곡 오디오 채보(speed_display 있음)는 홉 배율에 전사 잡음 ±7% 가 섞인다.
	# 태그는 기준 대비 10% 넘게 벗어난 '의도된 구간'에서만 단다 — 잡음에는 침묵.
	var tag_gate := 1e-6 if chart.speed_display.is_empty() else 0.10
	if absf(mult - 1.0) > tag_gate:
		# %g 는 GDScript 포맷에 없다 (TilePath._draw_markers 의 주석 참고)
		tag = "  %s x%s" % ["토끼" if mult > 1.0 else "달팽이", String.num(mult, 2)]
	_hud_info.text = "음악 %s / %s\n타일 BPM %.0f%s   체감 BPM %.0f\n타일 %d / %d" % [
		_fmt_time(t), _fmt_time(_song_len_ms), ebpm, tag, felt,
		_score.total, _judged_total]

	var s := _score.delta_stats()
	_timing_label.text = "판정창 ±%.0fms (Perfect ±%.0f)   표본 %d   평균 %+.1f   σ %.1f" % [
		_judge.miss_ms, _judge.perfect_ms, s.n, s.mean, s.sd]

	_debug.text = "역행 %d회 (최대 %.2fms)   output_latency %.1fms   fps %d" % [
		AudioClock.clamp_hits, AudioClock.max_backstep_ms,
		AudioClock.output_latency_ms(), Engine.get_frames_per_second()]


static func _fmt_time(ms: float) -> String:
	var sec := maxf(ms, 0.0) / 1000.0
	return "%d:%02d" % [int(sec) / 60, int(sec) % 60]
