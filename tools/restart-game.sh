#!/bin/sh
# 게임(에디터 아님) 재시작 — pkill 후 백그라운드 재기동 + 헬스체크.
#
# 왜 레포에 두나: 세션마다 `pkill -x godot; nohup godot ...` 원라이너를
# 재작성했다(한 세션에서 8번). 실패 시 로그 꼬리를 보여주는 것까지가
# 매번 같은 손동작이다.
#
#   tools/restart-game.sh          # 재시작 (실행 중이 아니어도 그냥 시작)
set -e
cd "$(dirname "$0")/.."
LOG="${TMPDIR:-/tmp}/rhythm-godot.log"

pkill -x godot 2>/dev/null || true
sleep 1
# 서브셸 이중 포크로 완전히 분리한다 — 스크립트 셸의 잡으로 남기면
# 호출자(에이전트 셸 등)가 끝날 때 프로세스 그룹째 정리될 수 있다.
( nohup godot > "$LOG" 2>&1 & ) </dev/null
sleep 6

if pgrep -x godot > /dev/null; then
  echo "게임 실행 OK (로그: $LOG)"
else
  echo "실행 실패 — 로그 꼬리:" >&2
  tail -10 "$LOG" >&2
  exit 1
fi
