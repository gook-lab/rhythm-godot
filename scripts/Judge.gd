class_name Judge
extends Node

## ms 판정만 한다. 렌더도 상태 전진도 모른다.
##
## delta = judged_ms(입력 순간) - hit_times_ms[i]   (부호 있음, 양수 = 늦음)
##
## 이 숫자들은 근거 있는 출발점이지 확정값이 아니다.
## osu!/ADOFAI 계열의 최상위 판정이 대략 +-30~50ms 대역이라 Perfect 를 30 으로 잡았다.
## 계측으로 자기 손의 산포가 나온 뒤에 다시 조인다 —
## 산포가 20ms 인데 Perfect 창이 30ms 면 그건 난이도가 아니라 운이다.

enum Verdict { PERFECT, EARLY_PERFECT, LATE_PERFECT, EARLY, LATE, MISS }

@export var perfect_ms: float = 30.0
@export var perfect_edge_ms: float = 60.0
@export var miss_ms: float = 110.0

signal judged(verdict: Verdict, delta_ms: float, tile: int)
signal missed(tile: int)


static func verdict_name(v: Verdict) -> String:
	match v:
		Verdict.PERFECT: return "PERFECT"
		Verdict.EARLY_PERFECT: return "EARLY!"
		Verdict.LATE_PERFECT: return "LATE!"
		Verdict.EARLY: return "EARLY"
		Verdict.LATE: return "LATE"
		_: return "MISS"


func classify(delta_ms: float) -> Verdict:
	var a := absf(delta_ms)
	if a <= perfect_ms:
		return Verdict.PERFECT
	if a <= perfect_edge_ms:
		return Verdict.EARLY_PERFECT if delta_ms < 0.0 else Verdict.LATE_PERFECT
	if a <= miss_ms:
		return Verdict.EARLY if delta_ms < 0.0 else Verdict.LATE
	return Verdict.MISS


## 입력이 들어왔을 때. 판정을 내고 신호를 쏜다.
func judge_input(delta_ms: float, tile: int) -> Verdict:
	var v := classify(delta_ms)
	judged.emit(v, delta_ms, tile)
	return v


## 무입력으로 기한이 지났을 때. 감시자가 부른다.
func emit_miss(tile: int) -> void:
	judged.emit(Verdict.MISS, INF, tile)
	missed.emit(tile)
