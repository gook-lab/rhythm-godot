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
from midilib import parse_smf, TempoMap

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

    print("PASS" if FAIL == 0 else "FAILED %d" % FAIL)
    sys.exit(FAIL)


if __name__ == "__main__":
    main()
