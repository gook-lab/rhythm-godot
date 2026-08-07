class_name Score
extends Node

## 판정을 받아 정확도·콤보·랭크로 집계한다. 판정 자체는 모른다(Judge 가 한다).
##
## 정확도 = sum(등급별 가중치) / 판정 수.
## 일반 Perfect 만 만점이라 "다 맞혔지만 E/L Perfect 가 섞인" 플레이와
## "전부 정확한" 플레이가 구분된다. 이게 있어야 손맛을 개선했는지 알 수 있다.
##
## delta 표본은 재시작을 넘어 누적된다(reset() 을 부르지 않는 한).
## 성공기준 3(같은 구간 10회 반복, 산포 <15ms)이 재시작마다 표본을 날리면
## 잴 수가 없기 때문이다.

var counts: Dictionary = {}      # Verdict -> int
var total: int = 0
var weight_sum: float = 0.0
var combo: int = 0
var max_combo: int = 0

## 판정 오차 표본(ms). Miss 는 제외 — 시각이 없으므로 산포에 못 넣는다.
var deltas: Array[float] = []


func _ready() -> void:
	reset()


func reset() -> void:
	counts.clear()
	for v in Judge.Verdict.values():
		counts[v] = 0
	total = 0
	weight_sum = 0.0
	combo = 0
	max_combo = 0


## 재시작해도 표본은 남긴다. 산포 측정이 세션 단위이기 때문이다.
## 표본까지 지우려면 이걸 부른다.
func clear_samples() -> void:
	deltas.clear()


func on_judged(v: Judge.Verdict, delta_ms: float, _tile: int) -> void:
	counts[v] = int(counts.get(v, 0)) + 1
	total += 1
	weight_sum += Judge.accuracy_weight(v)
	if Judge.is_miss(v):
		combo = 0
	else:
		combo += 1
		max_combo = maxi(max_combo, combo)
	if is_finite(delta_ms):
		deltas.append(delta_ms)


func accuracy() -> float:
	if total == 0:
		return 100.0
	return 100.0 * weight_sum / float(total)


func rank() -> String:
	if total == 0:
		return "-"
	var a := accuracy()
	# 전부 '일반 Perfect' 일 때만 P. 소수점 오차를 감안해 살짝 아래로 본다.
	if counts.get(Judge.Verdict.PERFECT, 0) == total:
		return "P"
	if a >= 99.0: return "SS"
	if a >= 95.0: return "S"
	if a >= 90.0: return "A"
	if a >= 80.0: return "B"
	if a >= 70.0: return "C"
	if a >= 60.0: return "D"
	return "F"


## 판정 오차의 평균과 표준편차(ms).
## 평균이 0 에서 벗어난 건 오프셋 슬라이더로 고치면 되지만,
## 흩어진 건 구조 문제라 슬라이더로 못 고친다.
func delta_stats() -> Dictionary:
	var n := deltas.size()
	if n == 0:
		return {"n": 0, "mean": 0.0, "sd": 0.0}
	var mean := 0.0
	for d in deltas:
		mean += d
	mean /= n
	var sd := 0.0
	for d in deltas:
		sd += (d - mean) * (d - mean)
	sd = sqrt(sd / n)
	return {"n": n, "mean": mean, "sd": sd}


func count_of(v: Judge.Verdict) -> int:
	return int(counts.get(v, 0))


## HUD 한 줄 요약.
func summary_line() -> String:
	return "%s  %.2f%%   combo %d (max %d)" % [rank(), accuracy(), combo, max_combo]
