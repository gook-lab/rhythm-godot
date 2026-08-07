class_name Judge
extends Node

## ms 판정만 한다. 렌더도 상태 전진도 모른다.
##
## delta = judged_ms(입력 순간) - hit_times_ms[i]   (부호 있음, 양수 = 늦음)
##
## ── 판정 7등급 (얼불춤 체계를 따른다) ──────────────────────────────
##   TooEarly · VeryEarly · EarlyPerfect · Perfect · LatePerfect · VeryLate · TooLate
##   Perfect 는 3종(E/일반/L)이고 정확도에 기여하는 값이 다르다.
##   일반 Perfect 만 만점이고 E/L Perfect 는 감점된다.
##
## ── 판정창은 BPM 에 따라 좁아진다 ──────────────────────────────────
## 얼불춤이 그렇게 하고, 안 하면 물리적으로 깨진다.
## 고정 +-110ms 로 두면 인접 타일 간격이 220ms 밑으로 내려가는 순간
## 판정창이 겹쳐서 한 번 누른 입력이 두 타일 모두에 유효해진다.
##
##   0.5박 @ 120bpm -> 간격 250ms -> 여유 30ms       (아슬아슬)
##   0.5박 @ 140bpm -> 간격 214ms -> -6ms  겹침
##   1/6박 @ 340bpm -> 간격  29ms -> -191ms 완전 붕괴
##
## 그래서 사다리 전체를 '이웃까지 거리'로 캡한다. 겹침이 구조적으로 불가능해진다.
##
##       hit[i-1]              hit[i]              hit[i+1]
##          |                    |                    |
##          |<---- gap_before -->|<---- gap_after --->|
##                        [<-- miss -->]
##                         캡 = min(gap) * 0.5 * GUARD

enum Verdict {
	PERFECT,
	EARLY_PERFECT,
	LATE_PERFECT,
	VERY_EARLY,
	VERY_LATE,
	TOO_EARLY,   # = Miss (너무 빠름)
	TOO_LATE,    # = Miss (너무 늦음 / 무입력)
}

## 기준 판정창(ms). 느린 곡에서의 상한이고, 빠른 구간에선 아래 캡에 눌린다.
## 계측으로 자기 손의 산포가 나온 뒤에 다시 조인다 —
## 산포가 20ms 인데 Perfect 창이 30ms 면 그건 난이도가 아니라 운이다.
@export var base_perfect_ms: float = 30.0
@export var base_very_ms: float = 60.0
@export var base_miss_ms: float = 110.0

## 판정창이 이웃 타일까지 갈 수 있는 비율. 1.0 이면 정확히 중간에서 맞닿는다.
## 0.9 로 두어 맞닿기 전에 멈춘다.
@export var overlap_guard: float = 0.9

## 현재 타일에 적용 중인 창(디버그 표시용). set_gaps() 가 갱신한다.
var perfect_ms: float = 30.0
var very_ms: float = 60.0
var miss_ms: float = 110.0

signal judged(verdict: Verdict, delta_ms: float, tile: int)


static func verdict_name(v: Verdict) -> String:
	match v:
		Verdict.PERFECT: return "PERFECT"
		Verdict.EARLY_PERFECT: return "EARLY PERFECT"
		Verdict.LATE_PERFECT: return "LATE PERFECT"
		Verdict.VERY_EARLY: return "EARLY!"
		Verdict.VERY_LATE: return "LATE!"
		Verdict.TOO_EARLY: return "TOO EARLY"
		_: return "MISS"


static func is_miss(v: Verdict) -> bool:
	return v == Verdict.TOO_EARLY or v == Verdict.TOO_LATE


## 정확도 기여분(0~1). 일반 Perfect 만 만점이다.
static func accuracy_weight(v: Verdict) -> float:
	match v:
		Verdict.PERFECT: return 1.0
		Verdict.EARLY_PERFECT, Verdict.LATE_PERFECT: return 0.9
		Verdict.VERY_EARLY, Verdict.VERY_LATE: return 0.6
		_: return 0.0


## 현재 타일 주변 간격에 맞춰 판정창을 좁힌다.
## gap_before / gap_after 는 이 타일과 앞뒤 타일의 시간 간격(ms).
## 끝 타일이라 이웃이 없으면 INF 를 넘긴다.
func set_gaps(gap_before_ms: float, gap_after_ms: float) -> void:
	var nearest := minf(gap_before_ms, gap_after_ms)
	var cap := nearest * 0.5 * overlap_guard
	miss_ms = minf(base_miss_ms, cap)
	# 사다리 전체가 같은 비율로 눌린다. 등급 간 비율은 보존된다.
	var scale := miss_ms / base_miss_ms if base_miss_ms > 0.0 else 1.0
	very_ms = base_very_ms * scale
	perfect_ms = base_perfect_ms * scale


func classify(delta_ms: float) -> Verdict:
	var a := absf(delta_ms)
	if a <= perfect_ms:
		return Verdict.PERFECT
	if a <= very_ms:
		return Verdict.EARLY_PERFECT if delta_ms < 0.0 else Verdict.LATE_PERFECT
	if a <= miss_ms:
		return Verdict.VERY_EARLY if delta_ms < 0.0 else Verdict.VERY_LATE
	return Verdict.TOO_EARLY if delta_ms < 0.0 else Verdict.TOO_LATE


func judge_input(delta_ms: float, tile: int) -> Verdict:
	var v := classify(delta_ms)
	judged.emit(v, delta_ms, tile)
	return v


## 무입력으로 기한이 지났을 때. 감시자가 부른다.
func emit_miss(tile: int) -> void:
	judged.emit(Verdict.TOO_LATE, INF, tile)
