#!/usr/bin/env python3
"""run_all_tests.sh 로그를 '실패 / 건너뜀 / 미분류 오류 / 예상된 오류 / 경고' 로 가른다.

Godot 는 테스트가 통과해도 ERROR·WARNING 줄을 찍는다 — 종료 시 리소스 누수 보고,
일부러 잘못된 입력을 먹이는 단위 테스트의 push_error 같은 것들이다. CI 로그에서
그 줄들이 실패와 섞여 보이지 않게 여기서 분류만 한다.

!! 통과/실패 판정은 run_all_tests.sh 의 종료 코드가 한다. 이 스크립트는 판정을 바꾸지 않는다.
   새 예상 오류를 EXPECTED 에 넣을 때는 어느 테스트가 왜 내는지를 같이 적는다 —
   이유 없이 넣으면 진짜 오류를 숨기는 목록이 된다.

  python3 tools/summarize_test_log.py test-output.log [--exit-code N] >> "$GITHUB_STEP_SUMMARY"
"""
import re
import sys

EXPECTED = [
    (r"Chart\.bpm must be > 0",
     "단위 테스트(t_bad_bpm)가 bpm 0 차트를 일부러 넣어 거부 경로를 검사"),
    (r"ObjectDB instances were leaked at exit",
     "재생 중인 씬을 quit() 로 끝낼 때 엔진이 내는 종료 시 누수 보고"),
    (r"resources still in use at exit",
     "위와 같은 종료 시 보고 — 러너가 곡 재생 중에 끝난다"),
    # Mureka 원곡 음원(assets/mureka_NN.wav)은 gitignore 이고 gen_all.sh 가 만들지 않는다.
    # 곡 선택(SongSelect.gd)은 로드에 실패한 차트를 목록에서 빼고, SelectRunner 는
    # 생성 차트만으로 통과한다 — 원곡이 없는 새 클론·CI 에서는 항상 이 줄이 나온다.
    (r"mureka_\d+\.(wav|tres)\b",
     "Mureka 원곡 음원은 레포·생성기에 없음 — 곡 선택이 로드 실패 차트를 목록에서 뺀다"),
]
# 카메라 검증 결과 — 스모크 러너가 찍는 줄을 그대로 모은다.
CAMERA = re.compile(r"카메라|스파이크|프레임 간격|연속성 표본")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
STEP = re.compile(r"^== (.+) ==$")


def classify(lines):
    step = "(시작 전)"
    out = {"fail": [], "skip": [], "unknown": [], "expected": {}, "warning": [], "camera": [], "steps": []}
    for raw in lines:
        line = ANSI.sub("", raw.rstrip("\n"))
        s = line.strip()
        m = STEP.match(s)
        if m:
            step = m.group(1)
            out["steps"].append(step)
            continue
        if s.startswith("at:") or not s:
            continue   # 직전 ERROR/WARNING 의 소스 위치
        if CAMERA.search(s) and "SmokeScene" not in s:
            out["camera"].append((step, s))
        if re.match(r"FAIL\b|FAILED\b", s):
            out["fail"].append((step, s))
            continue
        if re.match(r"SKIP\b", s):
            # 러너가 측정 전제(부하)를 못 채워 판정을 건너뛴 항목 — 통과도 실패도 아니다
            out["skip"].append((step, s))
            continue
        if s.startswith(("ERROR", "SCRIPT ERROR", "USER ERROR", "Parse Error")):
            for pat, why in EXPECTED:
                if re.search(pat, s):
                    out["expected"].setdefault(pat, [why, 0])[1] += 1
                    break
            else:
                out["unknown"].append((step, s))
            continue
        if s.startswith(("WARNING", "USER WARNING")):
            for pat, why in EXPECTED:
                if re.search(pat, s):
                    out["expected"].setdefault(pat, [why, 0])[1] += 1
                    break
            else:
                out["warning"].append((step, s))
    return out


def render(r, exit_code, passed_all):
    p = print
    if exit_code is None:
        verdict = "통과" if passed_all else "실패 또는 중단"
    else:
        verdict = "통과" if exit_code == 0 else "실패 (종료 코드 %d)" % exit_code
    p("## 테스트 요약 — %s" % verdict)
    p("")
    p("마지막 단계: %s · 진행한 단계 %d개" % (r["steps"][-1] if r["steps"] else "없음", len(r["steps"])))
    p("")
    p("판정은 종료 코드로만 합니다. 아래 '예상된 오류'와 '경고'는 통과한 실행에서도 나오는 줄입니다.")

    def section(title, rows):
        p("")
        p("### %s (%d)" % (title, len(rows)))
        for step, s in rows[:40]:
            p("- `%s` — %s" % (s, step))
        if len(rows) > 40:
            p("- … 외 %d줄" % (len(rows) - 40))

    section("실패", r["fail"])
    section("건너뜀 — 부하로 측정 전제가 깨진 판정(통과로 세지 않음)", r["skip"])
    section("미분류 오류 — 새로 생긴 오류일 수 있음", r["unknown"])
    p("")
    p("### 예상된 오류 (%d)" % sum(v[1] for v in r["expected"].values()))
    if r["expected"]:
        p("")
        p("| 패턴 | 횟수 | 이유 |")
        p("|---|---|---|")
        for pat, (why, n) in r["expected"].items():
            p("| `%s` | %d | %s |" % (pat, n, why))
    section("경고", r["warning"])
    section("카메라 검증", r["camera"])


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    exit_code = None
    if "--exit-code" in argv:
        exit_code = int(argv[argv.index("--exit-code") + 1])
    with open(argv[1], encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
    r = classify(lines)
    render(r, exit_code, any("전부 통과" in l for l in lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
