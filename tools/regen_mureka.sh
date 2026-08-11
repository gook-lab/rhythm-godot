#!/bin/sh
# mureka 전곡 재변환 (변환기·믹스·채보 규칙을 바꾼 뒤 돌린다. 곡당 ~25초).
#
#   tools/regen_mureka.sh              # 14곡 전부
#   tools/regen_mureka.sh 03 07        # 지정 곡만
#
# 왜 레포에 두나: 개발 세션마다 스크래치패드에 같은 스크립트를 6번 넘게
# 재작성했다. 폴더 매핑과 mureka_09 특례는 기억이 아니라 파일에 있어야 한다.
#
# 폴더 매핑은 tools/identify.py 방식(MIDI 지문: 끝박+트랙 노트 수+템포)으로
# 확인된 것이다 — 이름 매칭이 아니다. "midis (N) 2" 처럼 ' 2' 붙은 폴더는
# zip 중복 다운로드라 원본과 같은 곡이다.
#
# ⚠️ mureka_09 는 원곡 오디오 채보다. --audio 없이 돌리면 변환기 걸쇠가
#    신스 회귀를 막고 중단한다(의도된 동작). 원곡 mp3 경로가 다르면 아래를 고칠 것.
set -e
cd "$(dirname "$0")/.."
D="$HOME/Downloads"
ORIG_09="$HOME/Downloads/과부하 루프.mp3"

run() {  # run <NN> <폴더> [추가 인자...]
  nn="$1"; fold="$2"; shift 2
  echo "=============================== mureka_$nn"
  python3 tools/midi2song.py "$D/$fold"/*.mid --name "mureka_$nn" \
    --title "$(python3 -c "
import re
t = open('charts/mureka_$nn.tres', encoding='utf-8').read()
print(re.search(r'title = \"(.*)\"', t).group(1))
" 2>/dev/null || echo "mureka_$nn")" "$@"
}

want() {  # 스크립트 인자 없으면 전부, 있으면 지정 곡만
  # ⚠️ $# 은 want 자신의 인자(항상 1)다 — 스크립트 인자는 $ONLY 로만 판단.
  #    $# 검사를 섞었다가 무인자 실행이 전 곡을 조용히 스킵했다(실사고).
  [ -z "$ONLY" ] && return 0
  case " $ONLY " in *" $1 "*) return 0;; esac
  return 1
}
ONLY="$*"

want 01 && run 01 "midis"
want 02 && run 02 "midis (1)"
want 03 && run 03 "midis (2)"
want 04 && run 04 "midis (3)"
want 05 && run 05 "midis (4)"
want 06 && run 06 "midis (5)"
want 07 && run 07 "midis (6)"
want 08 && run 08 "midis (7)"
want 09 && run 09 "midis (8)"  --audio "$ORIG_09"
want 10 && run 10 "midis (9)"
want 11 && run 11 "midis (10)"
want 12 && run 12 "midis (11)"
want 13 && run 13 "midis (12)"
want 14 && run 14 "midis (13)"

echo ""
echo "완료 — 다음: godot --headless --import 후 tools/run_all_tests.sh"
