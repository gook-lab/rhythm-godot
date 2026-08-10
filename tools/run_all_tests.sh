#!/bin/sh
# 검증 체인 원커맨드 — 손으로 십수 회 반복하던 순서를 굳힌 것.
# 러너들이 실패 수를 종료 코드로 돌려주므로 set -e 로 그 자리에서 멈춘다.
#
#   ./tools/run_all_tests.sh                 # 전부 (약 6분 — 스모크가 실시간 재생)
#   SKIP_IMPORT=1 ./tools/run_all_tests.sh   # 에디터가 이미 임포트해 둔 경우
#
# !! 통합 씬은 --audio-driver CoreAudio 필수 — 기본 Dummy 는 클럭이 -4%
#    드리프트해서 타이밍 결론이 무효가 된다. 소리는 러너가 버스 뮤트로 끈다.
# !! 개별 단계만 돌리고 싶으면 README '테스트' 섹션의 명령을 그대로 쓰면 된다.
set -e
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

# 생성 자산(gitignore)이 없으면 통합 테스트가 전부 헛돈다 — 먼저 안내.
if [ ! -f assets/hit.wav ] || [ ! -f assets/test_song.expected.json ]; then
	echo "생성 자산이 없다 — ./tools/gen_all.sh 를 먼저 돌려라."
	exit 1
fi

step "0/10 임포트"
[ -n "$SKIP_IMPORT" ] || "$GODOT" --headless --import >/dev/null 2>&1

step "1/12 Python 단독 (midilib · 홀드 · 라우드니스 · 선택 판단)"
python3 tools/test_midilib.py
python3 tools/test_holds.py
python3 tools/test_audio.py
python3 tools/test_midi2song.py

step "2/12 단위 (ChartRuntime 순수 함수)"
"$GODOT" --headless --script res://tests/run_tests.gd

step "3/12 스모크: 무입력 (감시자 전부-미스 경로)"
"$GODOT" --headless --audio-driver CoreAudio res://tests/SmokeScene.tscn

step "4/12 스모크: 오토플레이 (판정 체인 전체)"
"$GODOT" --headless --audio-driver CoreAudio res://tests/SmokeScene.tscn -- --autoplay

step "5/12 스모크: 드문 미스 / 잦은 미스 (체력 회복·사망 경로)"
"$GODOT" --headless --audio-driver CoreAudio res://tests/SmokeScene.tscn -- --autoplay --miss-every=5
"$GODOT" --headless --audio-driver CoreAudio res://tests/SmokeScene.tscn -- --autoplay --miss-every=2

step "6/12 조작 표면 (등급·echo·R재시작·일시정지)"
"$GODOT" --headless --audio-driver CoreAudio res://tests/InputScene.tscn

step "7/12 체크포인트 부활 (seek 후 클럭이 계속 흐르는가)"
"$GODOT" --headless --audio-driver CoreAudio res://tests/CheckpointScene.tscn

step "8/12 홀드 (누름·뗌 2판정, 히트타임 지연, 착지 불변)"
"$GODOT" --headless --audio-driver CoreAudio res://tests/HoldScene.tscn

step "9/12 리플레이 (판정 기록의 비트 단위 재현)"
"$GODOT" --headless --audio-driver CoreAudio res://tests/ReplayScene.tscn

step "10/12 오토플레이 데모 (전 타일 delta 0 · P 100%)"
"$GODOT" --headless --audio-driver CoreAudio res://tests/AutoScene.tscn

step "11/12 곡 선택"
"$GODOT" --headless res://tests/SelectScene.tscn

step "12/12 교차 언어 채보 검증 (MIDI 픽스처, 엔진 vs 적분 정답)"
"$GODOT" --headless --script res://tests/verify_chart.gd -- --chart=res://charts/test_song.tres

printf '\n\033[1;32m전부 통과\033[0m\n'
