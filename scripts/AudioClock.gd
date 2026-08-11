extends Node

## 오디오 클럭. AudioClock.tscn 의 루트이고 autoload 로 등록된다.
##
## 왜 스크립트가 아니라 '씬' autoload 인가:
##   1. @export 가 인스펙터에 붙는다 (스크립트 autoload 는 안 붙는다).
##   2. 재생 노드를 자기 자식으로 소유한다. Main.tscn 에 두면
##      get_tree().reload_current_scene() 때 autoload 가 해제된 노드를 계속 가리켜
##      "previously freed instance" 로 죽는다. 성공기준 1(연속 3회 재시작)이 그걸 밟는다.
##
## 판정은 오직 이 클럭의 ms 차이로만 한다. 좌표 겹침도 프레임 카운트도 쓰지 않는다.
## 참고한 팬 구현이 화면 좌표로 판정했는데(if block[i][1]-25 <= ry <= ...),
## 그러면 프레임이 밀릴 때 판정이 통째로 밀리고 오디오 클럭과 갈라진다.

@onready var _player: AudioStreamPlayer = $AudioStreamPlayer

var _last_ms := -INF
var _started_usec := 0

## 역행 클램프가 발동한 횟수.
##
## !! 0 을 기대하지 마라. 실측하니 20초 재생에 5~12회 난다.
##    pos 와 since_mix 가 서로 독립적으로 갱신돼서, 믹싱 직후에 샘플링하면
##    옛 pos 에 리셋된 since_mix 가 붙어 한 청크(~5ms)만큼 뒤로 간다.
##    구조적으로 일어나는 일이고, 단조 클램프가 바로 그걸 막으라고 있는 것이다.
##    (get_output_latency() 를 시작 시점에 고정해봐도 크기가 그대로였다 —
##     latency 지터가 원인이 아니라는 뜻이다.)
##
## 판단은 횟수가 아니라 아래 max_backstep_ms 로 한다.
var clamp_hits := 0

## 역행의 '크기'. 횟수만으로는 판단이 안 된다 —
## 0.05ms 짜리 역행 12번은 무해하고, 20ms 짜리 1번은 치명적이다.
## 하드 게이트는 횟수가 아니라 이 값으로 봐야 한다.
var max_backstep_ms := 0.0

## 사용자 캘리브레이션 오프셋(ms).
##
## 부호 규약 (정의가 먼저, 증상은 그 다음):
##   정의: + 값은 "실제 출력 지연이 get_output_latency() 보고값보다 그만큼 크다"는 뜻.
##   증상: 보정이 부족하면 모든 입력이 Late 로 읽힌다. Late 로 치우치면 + 방향으로 민다.
##
## !! 이 값을 now_ms() 안에서 빼지 않는다. 판정 시점에 뺀다.
##    클럭 안에서 빼면 슬라이더를 미는 순간 ms 가 급락해서
##      1) clamp_hits 가 올라가고 (하드 게이트의 거짓양성)
##      2) maxf 가 이전 값을 붙잡아 클럭이 오프셋만큼 얼어붙는다 ("즉시 반영"이 아니게 됨)
##    캘리브레이션은 슬라이더를 이리저리 미는 작업이라 그 행위 자체가 게이트를 오염시킨다.
var user_offset_ms := 0.0

## 곡 시작 직후 클럭이 안정될 때까지의 유예(ms).
## 100 은 실측 전 출발점이지 근거 있는 상수가 아니다 —
## 계측 단계에서 곡 시작 직후 로그를 보고 실제 안정 시점으로 다시 잡을 것.
@export var warmup_ms: float = 100.0

signal song_started
signal song_finished


func _ready() -> void:
	_player.finished.connect(func() -> void: song_finished.emit())


func _exit_tree() -> void:
	# 재생 중에 프로세스가 죽으면 AudioStreamWAV/Playback 이 leak 로 잡힌다.
	# 기능상 무해하지만 로그에 노이즈가 남아 진짜 에러를 읽기 어려워진다.
	_player.stop()


## 유일한 재생 진입점. _player.play() 를 직접 부르는 경로를 만들지 않는다.
## 거치지 않으면 _last_ms 리셋이 누락되어 두 번째 플레이부터 조용히 망가진다.
func start(stream: AudioStream) -> void:
	if stream == null:
		push_error("AudioClock.start() called with null stream")
		return
	_player.stop()
	_player.stream_paused = false   # 일시정지 중 재시작해도 깨끗하게
	_player.stream = stream
	_last_ms = -INF
	clamp_hits = 0
	max_backstep_ms = 0.0
	_started_usec = Time.get_ticks_usec()
	_player.play()
	song_started.emit()


func stop() -> void:
	_player.stop()


## 음악 볼륨(0~1 선형). 설정 화면과 Main 이 부른다.
## 0 은 -80dB 로 못박는다 — linear_to_db(0) 은 -inf 라 스트림에 따라
## 잡음·NaN 경로를 탄다.
func set_music_volume(lin: float) -> void:
	_player.volume_db = linear_to_db(clampf(lin, 0.001, 1.0)) \
		if lin > 0.001 else -80.0


## 곡 안의 다른 지점으로 건너뛴다. 체크포인트 부활이 유일한 사용처다.
##
## 이 경로를 오래 막아 뒀던 이유가 있다: now_ms() 의 단조 클램프
## (`_last_ms = maxf(ms, _last_ms)`)는 시간이 되감기지 않는다는 전제 위에 있고,
## 그냥 _player.seek() 만 부르면 클럭이 옛 값에 영원히 얼어붙는다 —
## 크래시가 아니라 '판정이 전부 미스가 되는' 조용한 고장이다.
##
## 그런데 클램프는 '한 재생 구간 안에서'만 성립하는 불변식이지 곡 전체의
## 불변식이 아니다. start() 가 이미 매 재생마다 이력을 버리고 있다.
## 건너뛰기도 같은 리셋을 하면 새 구간이 시작되는 것과 구별할 이유가 없다.
## 그래서 '방어 코드'가 아니라 start() 와 같은 진입점 규약으로 만든다 —
## _player.seek() 를 직접 부르는 경로는 여전히 만들지 않는다.
func seek(ms: float) -> void:
	if not _player.playing:
		return
	_last_ms = -INF                        # 단조 클램프 이력을 버린다
	clamp_hits = 0
	max_backstep_ms = 0.0
	_started_usec = Time.get_ticks_usec()  # 워밍업 다시 — 건너뛴 직후 클럭은 못 믿는다
	_player.seek(maxf(ms, 0.0) / 1000.0)


## 일시정지. stream_paused 는 get_playback_position() 을 얼린다 —
## 언 클럭 = 시간이 안 흐름 = 감시자가 미스를 안 낸다.
## 별도의 '일시정지 시각 저장/복원'이 필요 없는 이유다.
## (멈춘 동안 since_mix 가 믹스 청크 안에서 진동하지만 단조 클램프가 잡는다)
func set_paused(p: bool) -> void:
	_player.stream_paused = p


func is_playing() -> bool:
	return _player.playing


## 곡 시작 직후 warmup_ms 동안은 클럭을 신뢰하지 않는다.
## 호출자는 반드시 이걸로 게이트한 뒤 now_ms() 를 부른다.
func is_warm() -> bool:
	if _started_usec == 0:
		return false
	return float(Time.get_ticks_usec() - _started_usec) > warmup_ms * 1000.0


## 지금 귀에 닿고 있는 소리의 시각(ms). 오프셋은 포함하지 않는다.
##
## Godot 공식 문서가 명시한 3항 조합이다:
##   get_playback_position() 만 쓰면 오디오 스레드가 다음 청크를 믹싱할 때까지
##   같은 값을 계속 돌려주므로 클럭이 믹스 버퍼 크기만큼의 계단으로 뚝뚝 뛴다.
##   그 계단폭이 그대로 판정 잡음이 된다.
##
## !! 반드시 _input() 과 _process() 각각에서 그 자리에서 호출한다. 캐시 금지.
##    _process 에 캐시한 값을 _input 에서 쓰면 최대 1프레임(60fps 에서 16.7ms)이
##    판정 오차로 그대로 들어간다. 두 곳에서 각각 불러도 단조 클램프가 있어 모순이 없다.
func now_ms() -> float:
	assert(is_warm(), "now_ms() before warm — 호출자가 is_warm() 게이트를 빠뜨렸다")
	# 정지한 뒤에는 get_playback_position() 이 0 을 돌려준다.
	# 그대로 계산하면 클럭이 곡 길이만큼 통째로 뒤로 가고(실측 -20.9초)
	# 역행 카운터가 오염된다. 정지 상태에서는 마지막 값을 그대로 유지한다.
	if not _player.playing:
		return _last_ms
	var pos := _player.get_playback_position()               # 초
	var since_mix := AudioServer.get_time_since_last_mix()   # 초
	var latency := AudioServer.get_output_latency()          # 초
	var ms := (pos + since_mix - latency) * 1000.0
	if ms < _last_ms:
		clamp_hits += 1
		max_backstep_ms = maxf(max_backstep_ms, _last_ms - ms)
	_last_ms = maxf(ms, _last_ms)  # 스레드 지터로 값이 역행할 수 있다(공식 문서 경고)
	return _last_ms


## 판정에 쓰는 보정된 시각. 감시자와 입력자가 둘 다 이걸 쓴다.
func judged_ms() -> float:
	return now_ms() - user_offset_ms


## 디버그 오버레이용. 실측 출력 지연(ms).
func output_latency_ms() -> float:
	return AudioServer.get_output_latency() * 1000.0
