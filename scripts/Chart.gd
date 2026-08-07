class_name Chart
extends Resource

## 채보의 단일 진실 소스. 렌더도 판정도 전부 여기서 파생된다.
## 별도의 노트 타임라인을 만들지 않는다 — 두 개의 진실 소스가 있으면
## 둘이 어긋날 수 있는 버그 표면이 생기고, 그게 클론들이 "미묘하게 안 맞는" 이유다.

## 분당 박자. 0 이하면 ChartRuntime 이 빈 배열을 돌려준다.
@export var bpm: float = 120.0

## 타일별 '나갈 방향'(도). 절대각, 반시계(CCW) 양수.
## angles[0] 은 출발 타일의 나갈 방향이라 대기 계산 대상이 아니다.
@export var angles: PackedFloat32Array = PackedFloat32Array()

## 곡 시작부터 타일 0 까지의 시간(ms).
@export var start_offset_ms: float = 0.0

## 곡. 차트와 곡은 항상 같이 다녀야 하므로 여기 들고 있는다.
@export var audio: AudioStream

## 속도 변경 타일 (얼불춤의 토끼/달팽이 = SetSpeed).
##   x = 타일 인덱스 · y = 그 타일부터 적용할 배율 (chart.bpm 대비 절대값)
##   y > 1 이면 토끼(빨라짐), y < 1 이면 달팽이(느려짐).
##
## 두 배열로 나누지 않고 Vector2 하나로 두는 이유: 길이가 어긋날 수 없다.
## 배율은 '누적'이 아니라 '대체'다 — 디버깅할 때 그 타일의 배속을 바로 읽을 수 있다.
##
## 주의: 배속이 올라가면 타일 간격이 좁아지고, 판정창이 자동으로 같이 좁아진다
## (Judge.set_gaps). 그래서 3배속 구간에서도 판정창이 이웃 타일에 안 닿는다.
@export var speed_changes: PackedVector2Array = PackedVector2Array()

@export var title: String = ""


## 인스펙터에서 필드를 빠뜨렸는지 한 곳에서 확인한다.
func is_valid() -> bool:
	return audio != null and bpm > 0.0 and angles.size() >= 2


func describe() -> String:
	return "%s (bpm %.1f, %d tiles)" % [title, bpm, angles.size()]
