# rhythm-godot — 작업 규칙

얼불춤(ADOFAI)류 원버튼 리듬게임. Godot 4.7 / GDScript + Python 도구(표준 라이브러리만).
**설계 근거·계측 기록·공식 유도는 전부 `README.md`가 단일 소스다.** 이 파일은
'어떻게 작업하는가'만 담는다 — 배경이 궁금하면 README 해당 섹션을 읽고, 여기에
내용을 복제하지 말 것.

## 불변 규칙 (위반 금지 — 이유는 README '지키는 규칙')

- **시간축은 하나** — 모든 시각 요소는 `AudioClock.now_ms()` 파생. **Tween 금지.**
- 캘리브레이션 오프셋은 클럭 밖(판정 시점)에서 — 클럭 내부에 넣으면 단조 클램프가 오발한다.
- 판정 커서(`_idx`)와 렌더 커서(`_vis`)는 분리 유지.
- 가드는 `assert`가 아니라 실제 분기 — assert 는 릴리스 빌드에서 사라진다.
- 각도 비교는 등호가 아니라 밴드(`ChartRuntime.TURN_EPS_DEG`) — fposmod 경계에서 float32/64 가 갈린다.
- 실측 없이 고치지 않는다 — 수정마다 계측/반증을 붙이고, 커밋 메시지에 잰 숫자를 남긴다(기존 로그가 양식).

## 검증

- 전체 체인: `./tools/run_all_tests.sh` (약 6분 — 스모크가 실시간 재생. 개별 명령은 README '테스트')
- ⚠️ 통합 씬은 `--audio-driver CoreAudio` 필수 — 기본 Dummy 는 -4% 드리프트.
- ⚠️ `--script` 모드엔 autoload 가 없다 — 통합 테스트는 씬으로만.
- 새로 클론했으면 `./tools/gen_all.sh` 먼저 — wav·`*.expected.json` 은 생성물이라 gitignore 다.

## MIDI → 곡+채보

`python3 tools/midi2song.py <mid...>` → `verify_chart.gd` → 스모크 `--chart=` 순.
명령과 함정 목록은 README 'MIDI → 곡 + 채보' 섹션.

## 병렬 Claude 세션 규약

같은 레포에서 세션 두 개가 자주 병렬로 작업한다.

- **파일 소유를 먼저 나눈다** (예: 변환기 `tools/midi2song.py`·`make_charts.py`·mureka 자산 = 한 세션, `scripts/`·`scenes/` = 다른 세션).
- 편집 전 `git status` — 미커밋 변경이 상대 소유면 내 커밋에 섞지 않는다.
- Write 충돌 시: 현재 상태를 읽고 → 상대 작업을 별도 커밋으로 먼저 올리고 → 내 것을 그 위에 얹는다.
