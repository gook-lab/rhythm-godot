#!/usr/bin/env python3
"""
의존성 0 의 Standard MIDI File 파서/라이터 + 템포 맵.

왜 mido 를 안 쓰나: 이 레포의 도구는 전부 stdlib 만 쓴다(make_song, make_charts).
pip 의존성이 하나 생기는 순간 "아무 데서나 python3 한 줄" 이 깨진다.
SMF 는 포맷이 작고 안정적이라 파서가 ~150줄이면 끝난다.

핵심 통찰 (이 파일이 존재하는 이유):
  MIDI 틱은 이미 '박자' 도메인이다 — tick / PPQ = 박자(4분음표 단위).
  템포 맵은 박자를 벽시계로 바꿀 때만 쓰인다.
  우리 게임도 박자 네이티브(각도 = 대기 박자)라서, MIDI 에서 온셋을 뽑으면
  온셋 검출(madmom 등, 120bpm 초과에서 정확도 11%) 자체가 필요 없다.
"""
import struct


class Note:
    __slots__ = ("tick", "dur", "ch", "pitch", "vel", "track")

    def __init__(self, tick, dur, ch, pitch, vel, track):
        self.tick = tick
        self.dur = dur
        self.ch = ch
        self.pitch = pitch
        self.vel = vel
        self.track = track

    def __repr__(self):
        return "Note(t=%d d=%d ch=%d p=%d)" % (self.tick, self.dur, self.ch, self.pitch)


# ---------------------------------------------------------------- 파서
def _read_varint(data, i):
    v = 0
    while True:
        b = data[i]
        i += 1
        v = (v << 7) | (b & 0x7F)
        if not (b & 0x80):
            return v, i


def parse_smf(path):
    """SMF -> {"ppq", "tracks": [{name, notes, programs}], "tempos": [(tick, bpm)]}

    다루는 것: note on/off(vel0=off), 러닝 스테이터스, 템포 메타, 트랙 이름.
    무시하는 것: CC/피치벤드/애프터터치/sysex (건너뛰기만 정확히 한다).
    """
    raw = open(path, "rb").read()
    assert raw[0:4] == b"MThd", "MThd 없음 — MIDI 파일이 아니다"
    hlen = struct.unpack(">I", raw[4:8])[0]
    fmt, ntrks, division = struct.unpack(">HHH", raw[8:14])
    assert division < 0x8000, "SMPTE 시분할은 지원 안 함 (PPQ 만)"
    ppq = division

    tracks = []
    tempos = []  # (tick, us_per_qn)
    i = 8 + hlen
    for tno in range(ntrks):
        assert raw[i:i + 4] == b"MTrk", "MTrk 청크가 아님 (offset %d)" % i
        tlen = struct.unpack(">I", raw[i + 4:i + 8])[0]
        data = raw[i + 8:i + 8 + tlen]
        i += 8 + tlen

        name = ""
        notes = []
        programs = {}
        open_notes = {}  # (ch,pitch) -> [Note, ...]  같은 음 중복은 FIFO
        tick = 0
        j = 0
        status = 0
        while j < len(data):
            dt, j = _read_varint(data, j)
            tick += dt
            b = data[j]
            if b & 0x80:
                status = b
                j += 1
                if b in (0xF0, 0xF7):          # sysex — 러닝 스테이터스 취소
                    ln, j = _read_varint(data, j)
                    j += ln
                    status = 0
                    continue
                if b == 0xFF:                  # meta
                    mtype = data[j]
                    j += 1
                    ln, j = _read_varint(data, j)
                    body = data[j:j + ln]
                    j += ln
                    if mtype == 0x51 and ln == 3:
                        tempos.append((tick, int.from_bytes(body, "big")))
                    elif mtype == 0x03 and not name:
                        name = body.decode("latin-1", "replace")
                    elif mtype == 0x2F:        # end of track
                        break
                    status = 0
                    continue
            # 채널 이벤트 (러닝 스테이터스 포함)
            assert status & 0x80, "러닝 스테이터스인데 직전 상태가 없다 (offset %d)" % j
            kind = status & 0xF0
            ch = status & 0x0F
            if kind in (0x80, 0x90, 0xA0, 0xB0, 0xE0):
                d1, d2 = data[j], data[j + 1]
                j += 2
            else:  # 0xC0 program, 0xD0 channel pressure
                d1, d2 = data[j], 0
                j += 1
            if kind == 0x90 and d2 > 0:
                n = Note(tick, 0, ch, d1, d2, tno)
                notes.append(n)
                open_notes.setdefault((ch, d1), []).append(n)
            elif kind == 0x80 or (kind == 0x90 and d2 == 0):
                q = open_notes.get((ch, d1))
                if q:
                    n = q.pop(0)
                    n.dur = max(1, tick - n.tick)
            elif kind == 0xC0:
                programs.setdefault(ch, d1)
        # 안 닫힌 노트는 트랙 끝까지
        for q in open_notes.values():
            for n in q:
                n.dur = max(1, tick - n.tick)
        tracks.append({"name": name, "notes": notes, "programs": programs})

    if not tempos:
        tempos = [(0, 500000)]  # 표준 기본값 120bpm
    # tick 정렬, 같은 tick 은 마지막 것이 이긴다
    tempos.sort(key=lambda t: t[0])
    dedup = {}
    for t, us in tempos:
        dedup[t] = us
    tempos_bpm = [(t, 60_000_000.0 / us) for t, us in sorted(dedup.items())]
    return {"ppq": ppq, "tracks": tracks, "tempos": tempos_bpm}


# ---------------------------------------------------------------- 템포 맵
class TempoMap:
    """박자 -> 초. 구간별 상수 템포의 누적 적분.

    entries: [(beat, bpm)], beat 오름차순, 첫 항이 곡 처음의 템포.
    """

    def __init__(self, entries):
        assert entries, "빈 템포 맵"
        entries = sorted(entries)
        if entries[0][0] > 0:
            entries = [(0.0, entries[0][1])] + entries
        self.entries = entries
        # 누적 초
        self._sec = [0.0]
        for k in range(1, len(entries)):
            b0, bpm0 = entries[k - 1]
            b1, _ = entries[k]
            self._sec.append(self._sec[-1] + (b1 - b0) * 60.0 / bpm0)

    def sec_at(self, beat):
        k = 0
        for idx in range(len(self.entries)):
            if self.entries[idx][0] <= beat + 1e-12:
                k = idx
            else:
                break
        b0, bpm0 = self.entries[k]
        return self._sec[k] + (beat - b0) * 60.0 / bpm0

    def bpm_at(self, beat):
        bpm = self.entries[0][1]
        for b, v in self.entries:
            if b <= beat + 1e-12:
                bpm = v
        return bpm


# ------------------------------------------------------- 템포 잡음 제거
def _fit_bpm(entries, lo, hi, end_beat):
    """entries[lo:hi] 구간을 대체할 '총 시간이 같은' 단일 bpm.

    시간 보존이 핵심이다. 평균 bpm 을 쓰면 구간 길이가 변해서
    잡음이 누적 드리프트로 바뀐다.
    """
    b0 = entries[lo][0]
    b1 = entries[hi][0] if hi < len(entries) else end_beat
    sec = 0.0
    for k in range(lo, hi):
        s = entries[k][0]
        # end_beat 이 마지막 템포 이벤트보다 앞일 수 있다(노트가 먼저 끝나는 경우).
        # 구간을 음수로 두면 적분이 망가지므로 0 으로 눌러 둔다.
        e = max(s, entries[k + 1][0] if k + 1 < hi else b1)
        sec += (e - s) * 60.0 / entries[k][1]
    if sec <= 0.0:
        return entries[lo][1]
    return (b1 - b0) * 60.0 / sec


def dejitter_tempos(entries, end_beat, tol=0.10):
    """전사 MIDI 의 템포 '측정 잡음'을 걷어내고 '의도된 변경'만 남긴다.

    오디오→MIDI 전사기(Mureka 스템 등)는 박마다 템포 이벤트를 찍는다.
    실측(Neon Orbit, 2026-08-07): 317박 전부에 이벤트가 있고 값은
    125 / 130.435 / 136.364 세 개뿐 — 박 길이로는 0.48 / 0.46 / 0.44 초,
    즉 20ms 격자다. 실제로는 128bpm 상수인 곡을 20ms 해상도로 재어
    반올림한 잡음이었다(상수 128 대비 편차가 추세 없이 ±36ms 안에서 진동).

    이걸 그대로 두면 변경 지점마다 토끼/달팽이 타일이 박힌다(실측 254개).
    게다가 변경이 홉 중간에 떨어지면 게임의 '홉당 상수 배속' 모델로는
    표현 자체가 안 되어 히트타임이 어긋난다(실측 최대 103ms).

    구간을 탐욕적으로 넓히면서, 그 구간을 시간 보존 단일 템포로 바꿔도
    구간 안 모든 원본 템포가 tol 안에 들어오면 계속 합친다.
    tol 기본값 10%: 그보다 작은 변화는 토끼/달팽이로 인지되지 않는다
    (얼불춤 속도 타일은 보통 1.2배 이상). tol <= 0 이면 원본을 그대로 둔다.

    반환: (정리된 entries, 원본 템포맵 대비 최대 드리프트 초)
    """
    entries = sorted(entries)
    if tol <= 0.0 or len(entries) <= 1:
        return list(entries), 0.0

    out = []
    i, n = 0, len(entries)
    while i < n:
        j, fit = i + 1, entries[i][1]
        while j < n:
            cand = _fit_bpm(entries, i, j + 1, end_beat)
            if all(abs(entries[k][1] / cand - 1.0) <= tol for k in range(i, j + 1)):
                fit, j = cand, j + 1
            else:
                break
        out.append((entries[i][0], fit))
        i = j

    before, after = TempoMap(entries), TempoMap(out)
    edges = sorted({e[0] for e in entries} | {e[0] for e in out} | {end_beat})
    drift = max(abs(before.sec_at(b) - after.sec_at(b)) for b in edges)
    return out, drift


# ---------------------------------------------------------------- 라이터 (픽스처용)
def _varint(v):
    out = [v & 0x7F]
    v >>= 7
    while v:
        out.append((v & 0x7F) | 0x80)
        v >>= 7
    return bytes(reversed(out))


def write_smf(path, ppq, note_tracks, tempos_bpm):
    """픽스처 생성용 최소 라이터.

    note_tracks: [{name, notes: [(tick, dur, ch, pitch, vel)]}]
    tempos_bpm:  [(tick, bpm)] — 트랙 0(템포 트랙)에 들어간다
    """
    def track_chunk(events):
        events.sort(key=lambda e: (e[0], e[1]))
        body = b""
        last = 0
        for tick, _prio, ev in events:
            body += _varint(tick - last) + ev
            last = tick
        body += _varint(0) + b"\xff\x2f\x00"
        return b"MTrk" + struct.pack(">I", len(body)) + body

    chunks = []
    tempo_events = []
    for tick, bpm in tempos_bpm:
        us = round(60_000_000 / bpm)
        tempo_events.append((tick, 0, b"\xff\x51\x03" + us.to_bytes(3, "big")))
    chunks.append(track_chunk(tempo_events))

    for tr in note_tracks:
        ev = []
        if tr.get("name"):
            nm = tr["name"].encode("latin-1")
            ev.append((0, 0, b"\xff\x03" + _varint(len(nm)) + nm))
        for tick, dur, ch, pitch, vel in tr["notes"]:
            ev.append((tick, 1, bytes([0x90 | ch, pitch, vel])))
            ev.append((tick + dur, 0, bytes([0x80 | ch, pitch, 0])))  # off 를 on 보다 먼저
        chunks.append(track_chunk(ev))

    with open(path, "wb") as f:
        f.write(b"MThd" + struct.pack(">IHHH", 6, 1, len(chunks), ppq))
        for c in chunks:
            f.write(c)
