extends Node

## 디스크에 남는 것 전부 — 곡별 기록 + 판정키 바인딩 + 캘리브레이션 오프셋.
## user://records.json 한 파일.
##
## 왜 autoload 인가: 기록은 씬(SongSelect ↔ Main)을 넘나들며 읽고 쓴다 —
## GameState 와 같은 이유다. 다만 GameState 는 '이번 세션의 선택'이고
## 여기는 '디스크에 남는 역사'다. 섞으면 안 된다.
##
## 테스트 주의: 러너들은 chart 를 직접 주입하고 GameState.selected_chart 를
## 비워 둔다. Main/SongSelect 는 그 경로에서 여기를 읽고 쓰지 않는다 —
## 사용자의 저장 파일이 테스트 결과를 흔들지도, 테스트가 기록을 오염시키지도
## 않게 하기 위해서다. 단위 테스트는 이 스크립트를 직접 인스턴스해
## save_path 를 갈아끼운다.

const SAVE_PATH := "user://records.json"

## 랭크 서열. best_rank 갱신 비교용 — 정확도만으로는 P(전부 일반 Perfect)와
## SS(99%+지만 E/L 섞임)의 우열이 안 갈린다.
const RANKS := ["-", "F", "D", "C", "B", "A", "S", "SS", "P"]

## 어떤 바인딩에서도 판정키가 될 수 없는 키.
## ESC/R 은 Main 의 예약키(일시정지·재시작)고, 수식키·TAB 은 원래 제외였다.
const NEVER_JUDGE: Array[int] = [
	KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META, KEY_CAPSLOCK, KEY_TAB,
	KEY_ESCAPE, KEY_R,
]

## 테스트가 갈아끼운다. 실행 흐름에서는 항상 SAVE_PATH.
var save_path := SAVE_PATH

## 캘리브레이션 오프셋(ms). Main 의 슬라이더가 읽고 쓴다 —
## 잰 값을 매번 다시 재게 하면 캘리브레이션이 아니라 고문이다.
var offset_ms := 0.0

## 판정키 바인딩. 비어 있으면 '예약키 제외 전부'(기본, 얼불춤식 양손 교타).
## SongSelect 의 K 메뉴가 채운다.
var bound_keys := PackedInt32Array()

## 입력 효과음(hit/miss)을 낼지. Main 이 M 키로 토글한다.
##
## 켜고 끌 수 있어야 하는 이유: 이 소리는 목적이 두 개인데 곡에 따라 하나가
## 무의미해진다. 클릭 트랙에서는 '곡의 클릭과 내 입력음의 어긋남 = 내 오차'라
## 캘리브레이션 도구지만(Main.gd 의 _hitsound 주석), 실제 음악에서는 타일이
## 정의상 멜로디 온셋 위에 있어서 효과음이 멜로디 음과 같은 샘플에 겹친다.
##
## 그렇다고 음악에서 무조건 끌 수도 없다. 채움 타일(2박 초과 공백을 메우는
## 타일)에는 멜로디 음이 아예 없어서, 끄면 그 타일은 쳐도 무음이 된다 —
## 실측 14곡 8166타일 중 255개(3.1%), 가장 심한 곡이 8.2% 다.
## (파이프라인에 민감한 값이다. 온셋 보강·홉 분해 전에는 31.3% 였다.)
## 그래서 기본은 켜 두고 선택으로 남긴다.
var sfx_enabled := true

var _charts := {}   # 차트 경로 -> 기록 Dictionary


func _ready() -> void:
	load_file()


static func rank_index(r: String) -> int:
	return maxi(RANKS.find(r), 0)


## 이 키가 지금 바인딩에서 판정키인가.
func is_judgment_key(code: int) -> bool:
	if code in NEVER_JUDGE:
		return false
	return bound_keys.is_empty() or code in bound_keys


## 바인딩 토글. 예약키는 조용히 거부한다(true = 반영됨).
func toggle_key(code: int) -> bool:
	if code in NEVER_JUDGE:
		return false
	var i := bound_keys.find(code)
	if i >= 0:
		bound_keys.remove_at(i)
	else:
		bound_keys.append(code)
	return true


## 곡 하나의 기록. 없으면 빈 Dictionary — 호출부는 is_empty() 로 '미플레이' 판별.
func get_record(path: String) -> Dictionary:
	return (_charts.get(path, {}) as Dictionary).duplicate()


## 플레이 1회를 반영하고 저장한다. 반환값은 '무엇이 갱신됐나' —
## 결과 화면의 신기록 표시용. 키가 있으면 갱신, 값은 이전 최고치.
##   {acc: 이전값, combo: 이전값, progress: 이전값, rank: 이전랭크, first_clear: true}
func record_play(path: String, acc: float, rank: String, combo: int,
		progress: float, cleared: bool) -> Dictionary:
	var r: Dictionary = _charts.get(path, {
		"plays": 0, "clears": 0,
		"best_acc": -1.0, "best_rank": "-", "best_combo": 0, "best_progress": 0.0,
	})
	var improved := {}
	r.plays = int(r.plays) + 1
	if cleared:
		r.clears = int(r.clears) + 1
		if int(r.clears) == 1:
			improved["first_clear"] = true
	if acc > float(r.best_acc):
		if float(r.best_acc) >= 0.0:
			improved["acc"] = float(r.best_acc)
		r.best_acc = acc
	if rank_index(rank) > rank_index(str(r.best_rank)):
		improved["rank"] = str(r.best_rank)
		r.best_rank = rank
	if combo > int(r.best_combo):
		improved["combo"] = int(r.best_combo)
		r.best_combo = combo
	if progress > float(r.best_progress):
		improved["progress"] = float(r.best_progress)
		r.best_progress = progress
	r.last_played = Time.get_datetime_string_from_system()
	_charts[path] = r
	save()
	return improved


func save() -> void:
	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f == null:
		push_error("기록 저장 실패: %s" % save_path)
		return
	var keys := []
	for k in bound_keys:
		keys.append(int(k))
	f.store_string(JSON.stringify({
		"settings": {"offset_ms": offset_ms, "bound_keys": keys,
			"sfx_enabled": sfx_enabled},
		"charts": _charts,
	}, "  "))


func load_file() -> void:
	_charts = {}
	offset_ms = 0.0
	bound_keys = PackedInt32Array()
	sfx_enabled = true
	if not FileAccess.file_exists(save_path):
		return
	var f := FileAccess.open(save_path, FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	# 파일이 깨져 있으면 기본값으로 시작한다. 기록 파일 때문에 게임이
	# 못 뜨는 것보다 기록을 잃는 쪽이 낫다.
	if not (data is Dictionary):
		push_warning("기록 파일이 깨져 있다 — 기본값으로 시작: %s" % save_path)
		return
	var s = data.get("settings", {})
	if s is Dictionary:
		offset_ms = float(s.get("offset_ms", 0.0))
		sfx_enabled = bool(s.get("sfx_enabled", true))
		for k in (s.get("bound_keys", []) as Array):
			bound_keys.append(int(k))
	var c = data.get("charts", {})
	if c is Dictionary:
		_charts = c
