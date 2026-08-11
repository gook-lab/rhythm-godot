extends Control

## 타건 UI (얼불춤 커뮤니티 KeyViewer 모드의 우리 판).
## 화면 왼쪽에 판정키 타일을 세로로 쌓고, 누르면 켜지고 떼면 꺼진다.
## 키별 타수와 최근 1초 KPS 를 같이 보여준다 — 양손 교타에서 어느 손이
## 노는지, 순간 몇 타까지 올라가는지가 손맛 계측의 일부다.
##
## 데이터는 스스로 줍지 않고 Main 이 먹인다(note_*). 이유:
## - 실입력은 Main._input 의 판정키 필터를 통과한 것만 의미가 있다
##   (ESC·R 이 깜빡이면 잡음이다).
## - 리플레이·오토는 키 이벤트가 아예 없어서 _apply_press 가 유일한 소스다.
##
## 기본 바인딩(비어 있음 = 전부 판정키)에서는 보여줄 키 목록이 정해져 있지
## 않다 — 처음 눌린 순서대로 슬롯을 만들고 MAX_KEYS 에서 자른다.
## 곡 선택 K 메뉴로 바인딩했으면 그 키들을 처음부터 깔아 둔다.

const MAX_KEYS := 8
const BOX := 44.0
const GAP := 8.0
const TAP_FLASH_MS := 110.0   # 리플레이·오토 탭의 표시 시간(뗌 이벤트가 없다)

var _order: Array[int] = []     # 표시 순서 (첫 사용 순)
var _held := {}                 # keycode -> true
var _until := {}                # keycode -> 자동 소등 시각 (탭 전용, ms)
var _count := {}                # keycode -> 누적 타수
var _times: Array[float] = []   # 최근 누름 시각들 (KPS)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in Records.bound_keys:
		_ensure_slot(int(c))


func _process(_d: float) -> void:
	var now := float(Time.get_ticks_msec())
	for k in _until.keys():
		if now >= float(_until[k]):
			_held.erase(k)
			_until.erase(k)
	while _times.size() > 0 and now - _times[0] > 1000.0:
		_times.remove_at(0)
	queue_redraw()


func _ensure_slot(code: int) -> void:
	if code in _order or _order.size() >= MAX_KEYS:
		return
	_order.append(code)
	_count[code] = int(_count.get(code, 0))


## 실입력의 누름. 뗌(note_release)이 따로 온다.
func note_press(code: int) -> void:
	_ensure_slot(code)
	_held[code] = true
	_until.erase(code)
	_count[code] = int(_count.get(code, 0)) + 1
	_times.append(float(Time.get_ticks_msec()))


func note_release(code: int) -> void:
	_held.erase(code)
	_until.erase(code)


## 리플레이·오토의 탭 — 뗌 이벤트가 없으므로 잠깐 켰다 끈다.
## 홀드가 시작되면 Main 이 곧바로 note_press 로 승격시킨다.
func note_tap(code: int) -> void:
	note_press(code)
	_until[code] = float(Time.get_ticks_msec()) + TAP_FLASH_MS


## 탭 플래시(자동 소등)를 '누르고 있음'으로 승격한다 — 리플레이·오토의
## 홀드 시작. 소등은 note_release(홀드 뗌 경로)가 맡는다.
func sustain(code: int) -> void:
	_until.erase(code)


func reset() -> void:
	_held.clear()
	_until.clear()
	_count.clear()
	_times.clear()
	# 바인딩 키는 슬롯을 유지한다 — 판마다 배치가 바뀌면 눈이 못 따라간다.
	if Records.bound_keys.is_empty():
		_order.clear()
	for c in Records.bound_keys:
		_ensure_slot(int(c))


func _draw() -> void:
	var font := ThemeDB.fallback_font
	var y := 0.0
	# KPS — 최근 1초 누름 수. 표본이 없으면 0.
	draw_string(font, Vector2(0, -14), "%d KPS" % _times.size(),
		HORIZONTAL_ALIGNMENT_LEFT, BOX + 34.0, 15,
		Color(0.62, 0.68, 0.8, 0.9))
	for code in _order:
		var r := Rect2(0, y, BOX, BOX)
		var held: bool = _held.has(code)
		if held:
			draw_rect(r, Color(1.0, 0.92, 0.55, 0.92))
		draw_rect(r, Color(0.62, 0.68, 0.8, 0.85 if held else 0.45), false, 2.0)
		var name := OS.get_keycode_string(code)
		if name.length() > 3:
			name = name.substr(0, 3)
		var fg := Color(0.1, 0.1, 0.12) if held else Color(0.75, 0.8, 0.9, 0.9)
		draw_string(font, Vector2(0, y + BOX * 0.62), name,
			HORIZONTAL_ALIGNMENT_CENTER, BOX, 17, fg)
		draw_string(font, Vector2(BOX + 7.0, y + BOX * 0.62),
			str(int(_count.get(code, 0))),
			HORIZONTAL_ALIGNMENT_LEFT, 60.0, 13, Color(0.55, 0.6, 0.72, 0.85))
		y += BOX + GAP
