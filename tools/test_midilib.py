#!/usr/bin/env python3
"""
midilib 파서 단독 테스트 — 라이터를 거치지 않는다.

파서를 자기 라이터 출력으로만 검증하면 둘이 같은 오해를 공유할 때 못 잡는다.
특히 우리 라이터는 러닝 스테이터스를 안 쓰므로, 실제 AI MIDI 가 흔히 쓰는
그 경로가 통째로 미검증이 된다. 여기서는 SMF 스펙대로 바이트를 손으로 깎아
파서에 직접 먹인다:

  - 러닝 스테이터스 (note on 연쇄 + vel0 = note off)
  - 메타/sysex 가 러닝 스테이터스를 취소하는 규칙
  - 파서가 '건너뛰어야 하는' 이벤트들: CC, 피치벤드, 프로그램, 채널 프레셔
  - 같은 음 중복 note-on 의 FIFO 매칭
  - 템포 다중 트랙 병합 + 같은 tick 중복 시 마지막 승리
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from midilib import parse_smf, TempoMap, dejitter_tempos

FAIL = 0


def ok(cond, what):
    global FAIL
    print("  %s %s" % ("ok  " if cond else "FAIL", what))
    if not cond:
        FAIL += 1


def chunk(events):
    body = b"".join(events) + b"\x00\xff\x2f\x00"
    return b"MTrk" + struct.pack(">I", len(body)) + body


def smf(tracks, ppq=480):
    return b"MThd" + struct.pack(">IHHH", 6, 1, len(tracks), ppq) + b"".join(tracks)


def main():
    path = "/tmp/midilib_handcrafted.mid"

    # ── 트랙 1: 러닝 스테이터스 지옥 ─────────────────────────────
    t1 = chunk([
        b"\x00" + b"\xff\x03" + b"\x04Lead",         # 이름
        b"\x00" + b"\x90\x45\x60",                    # tick 0: on 69 (status 설정)
        b"\x81\x70" + b"\x45\x00",                    # tick 240: 러닝, vel0 = off 69
        b"\x00" + b"\x47\x64",                        # tick 240: 러닝, on 71
        b"\x81\x70" + b"\x47\x00",                    # tick 480: 러닝, off 71
        # 메타(러닝 취소) 뒤 상태 없이 데이터가 오면 안 되므로 status 재설정
        b"\x00" + b"\xff\x01" + b"\x02hi",            # text meta -> 러닝 취소
        b"\x00" + b"\x90\x48\x60",                    # tick 480: on 72
        # 같은 음 중복 note-on: FIFO 로 닫혀야 한다
        b"\x60" + b"\x48\x60",                        # tick 576: 러닝, on 72 또
        b"\x60" + b"\x48\x00",                        # tick 672: off -> 첫 72 (dur 192)
        b"\x60" + b"\x48\x00",                        # tick 768: off -> 둘째 72 (dur 192)
        # 건너뛸 것들 사이에 노트: CC, 벤드, 프로그램, 채널 프레셔, sysex
        b"\x00" + b"\xb0\x07\x64",                    # CC volume
        b"\x00" + b"\xe0\x00\x40",                    # pitch bend
        b"\x00" + b"\xc0\x51",                        # program 81
        b"\x00" + b"\xd0\x40",                        # channel pressure
        b"\x00" + b"\xf0\x03\x01\x02\xf7",            # sysex len 3
        b"\x00" + b"\x90\x4a\x50",                    # tick 768: on 74
        b"\x81\x70" + b"\x4a\x00",                    # tick 1008: off 74
    ])
    # ── 트랙 2: 템포만 (병합·중복 검증) ──────────────────────────
    t2 = chunk([
        b"\x00" + b"\xff\x51\x03" + (500000).to_bytes(3, "big"),   # tick 0: 120
        b"\x00" + b"\xff\x51\x03" + (400000).to_bytes(3, "big"),   # tick 0 중복: 150 (마지막 승리)
        b"\x83\x60" + b"\xff\x51\x03" + (250000).to_bytes(3, "big"),  # tick 480: 240
    ])
    open(path, "wb").write(smf([t1, t2]))

    d = parse_smf(path)
    notes = sorted(d["tracks"][0]["notes"], key=lambda n: (n.tick, n.pitch))
    print("러닝 스테이터스 + 스킵 이벤트")
    ok(d["tracks"][0]["name"] == "Lead", "트랙 이름")
    ok(len(notes) == 5, "노트 5개 (러닝·vel0off·중복on 전부 해석) — %d" % len(notes))
    got = [(n.tick, n.pitch, n.dur) for n in notes]
    want = [(0, 69, 240), (240, 71, 240), (480, 72, 192), (576, 72, 192), (768, 74, 240)]
    ok(got == want, "tick/dur 정확 — %s" % (got,))
    ok(d["tracks"][0]["programs"].get(0) == 81, "program change 수집")

    print("템포 병합")
    ok(d["tempos"] == [(0, 150.0), (480, 240.0)],
       "같은 tick 중복은 마지막 승리, 정렬 병합 — %s" % d["tempos"])

    print("템포 맵 적분")
    tm = TempoMap([(0.0, 120.0), (4.0, 240.0)])
    ok(abs(tm.sec_at(4.0) - 2.0) < 1e-12, "4박@120 = 2.0s")
    ok(abs(tm.sec_at(6.0) - 2.5) < 1e-12, "이후 2박@240 = +0.5s")
    ok(tm.bpm_at(3.999) == 120.0 and tm.bpm_at(4.0) == 240.0, "경계에서 새 템포")

    print("템포 잡음 제거")
    # 전사 MIDI 재현: 진짜 128bpm 상수인 곡을 20ms 격자로 재면
    # 박 길이가 0.46/0.48 을 오가고 템포는 130.435/125 로 튄다 (Mureka 실측 값).
    jit = [(float(b), 130.435 if b % 2 == 0 else 125.0) for b in range(64)]
    clean, drift = dejitter_tempos(jit, 64.0)
    ok(len(clean) == 1, "박마다 찍힌 잡음 64개 -> 1개 — %d개" % len(clean))
    ok(abs(clean[0][1] - 127.6) < 1.0, "합쳐진 템포가 참값 부근 — %.3f" % clean[0][1])
    ok(drift < 0.05, "전사 대비 드리프트가 작다 — %.1fms" % (drift * 1000))
    # 시간 보존: 곡 전체 길이는 잡음 제거 전후로 같아야 한다.
    ok(abs(TempoMap(jit).sec_at(64.0) - TempoMap(clean).sec_at(64.0)) < 1e-9,
       "구간 총 길이 보존")

    # 의도된 변경(2배)은 tol 밖이라 반드시 살아남는다.
    real = [(0.0, 120.0), (8.0, 240.0)]
    clean2, _ = dejitter_tempos(real, 16.0)
    ok(clean2 == real, "2배 속도 변경은 보존 — %s" % (clean2,))

    # 잡음 위에 얹힌 진짜 변경: 잡음은 합쳐지고 변경은 남는다.
    mixed = [(float(b), (130.435 if b % 2 == 0 else 125.0)) for b in range(16)]
    mixed += [(float(b), (260.0 if b % 2 == 0 else 250.0)) for b in range(16, 32)]
    clean3, _ = dejitter_tempos(mixed, 32.0)
    ok(len(clean3) == 2, "잡음 32개 -> 구간 2개 — %d개" % len(clean3))
    ok(clean3[1][0] == 16.0, "경계가 진짜 변경 지점 — %.4g박" % clean3[1][0])

    ok(dejitter_tempos(jit, 64.0, tol=0.0)[0] == jit, "tol=0 이면 원본 그대로")

    # 전사 MIDI 는 노트가 끝난 뒤에도 템포를 계속 찍는다. 끝박이 마지막
    # 이벤트보다 앞일 때 소구간을 안 자르면 박/초 비율이 어긋나 템포가 밀린다
    # (실측: 313박 곡에 316박까지 이벤트 -> 128 이 126.8bpm 으로).
    tail = [(float(b), 128.0) for b in range(64)]
    clean4, _ = dejitter_tempos(tail, 40.0)
    ok(abs(clean4[0][1] - 128.0) < 1e-6,
       "끝박 뒤 이벤트가 템포를 밀지 않는다 — %.4f" % clean4[0][1])

    print("PASS" if FAIL == 0 else "FAILED %d" % FAIL)
    sys.exit(FAIL)


if __name__ == "__main__":
    main()
