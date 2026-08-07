#!/usr/bin/env python3
"""
midi2song 검증용 MIDI 픽스처.

AI 가 뱉는 MIDI 에서 실제로 나올 함정을 전부 심는다:
  - 템포 변경 2회 (120 -> 180 -> 120). 첫 변경 지점(16박)에는 일부러 노트가 없다
    -> 변환기가 그 자리에 타일을 강제 삽입해야 한다(안 하면 홉 중간에 템포가 바뀌어
       게임의 '홉당 상수 배속' 모델로 표현이 안 된다).
  - 코드(같은 틱에 노트 2개) -> 온셋 1개로 합쳐져야 한다.
  - 그리드 벗어난 노트(10박 + 5틱) -> 1/12 격자로 양자화 + 오차 보고.
  - 5박 공백(14 -> 19) -> 한 타일 최대 대기가 2박이라 채움 타일이 필요하다.
  - 첫 노트가 0박 -> 카운트인 리드가 없어서 변환기가 +4박 시프트해야 한다.

손계산 앵커 (시프트 +4 후):
  첫 온셋 = 4박 @120 -> t = 2.000s, start_offset = 2.0 - 0.5 = 1.500s
  템포 변경 = 20박 -> t = 2 + 16*0.5 = 10.000s
  복귀 = 36박 -> t = 10 + 16*(60/180) = 15.333s
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from midilib import write_smf

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PPQ = 480


def b(beats):  # 박 -> 틱
    return int(round(beats * PPQ))


def main():
    A, C, D, E, F, G, A5 = 69, 72, 74, 76, 77, 79, 81

    mel = []  # (박, 길이박, 음)
    mel += [(0, 0.9, A), (1, 0.9, C), (2, 0.9, E), (3, 0.9, D)]
    mel += [(4, 0.4, E), (4.5, 0.4, F), (5, 0.4, G), (5.5, 0.4, A5), (6, 0.9, G), (7, 0.9, E)]
    # 코드: 8박에 두 음
    mel += [(8, 0.9, E), (8, 0.9, G), (9, 0.9, D)]
    # 그리드 벗어남: 10박 + 5틱 (= 10.0104박, 1/12 격자 밖)
    mel += [(10 + 5.0 / PPQ, 0.9, C), (11, 0.9, D)]
    mel += [(12, 0.9, E), (13, 0.9, C), (14, 1.8, A)]
    # <- 14~19 가 5박 공백. 그 안(16박)에서 템포가 120 -> 180 으로 바뀐다.
    mel += [(19, 0.4, E), (20, 0.9, G), (21, 0.9, A5), (22.5, 0.9, G),
            (24, 0.9, E), (25, 0.9, D), (26, 1.8, C), (28, 1.8, E), (30, 0.9, G), (31, 0.9, A5)]
    # 32박에서 템포 복귀(여기는 노트가 있다 -> 삽입 불필요 경로도 검증)
    mel += [(32, 0.9, A5), (33, 0.9, G), (34, 0.9, E), (35, 0.9, C), (36, 1.8, A)]

    bass = []
    roots = [A - 24, F - 24, C - 24, G - 24]
    for k in range(0, 19):  # 2박 간격, 0..36
        bass.append((k * 2.0, 1.8, roots[(k // 2) % 4]))

    drums = []
    for bar in range(0, 10):  # 0..36박 커버
        base = bar * 4.0
        drums += [(base, 0.2, 36), (base + 2, 0.2, 36)]        # kick
        drums += [(base + 1, 0.2, 38), (base + 3, 0.2, 38)]    # snare
        for k in range(8):
            drums.append((base + k * 0.5, 0.1, 42))            # closed hat

    def notes(ch, seq, vel=96):
        return [(b(t), max(1, b(d)), ch, p, vel) for (t, d, p) in seq]

    write_smf(
        os.path.join(HERE, "assets", "test_song.mid"),
        PPQ,
        [
            {"name": "Melody", "notes": notes(0, mel)},
            {"name": "Bass", "notes": notes(1, bass, 88)},
            {"name": "Drums", "notes": notes(9, drums, 100)},
        ],
        [(0, 120.0), (b(16), 180.0), (b(32), 120.0)],
    )
    print("assets/test_song.mid  (멜로디 %d · 베이스 %d · 드럼 %d · 템포변경 2회)"
          % (len(mel), len(bass), len(drums)))


if __name__ == "__main__":
    main()
