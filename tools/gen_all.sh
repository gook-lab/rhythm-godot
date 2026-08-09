#!/bin/sh
# 새로 클론했을 때 생성 자산 일괄 재구성 (wav 류는 gitignore 라 레포에 없다).
set -e
cd "$(dirname "$0")/.."
python3 tools/test_midilib.py
python3 tools/test_density.py
python3 tools/make_click.py 120 60
python3 tools/make_hitsound.py
python3 tools/make_song.py
python3 tools/make_test_midi.py
python3 tools/make_charts.py
python3 tools/midi2song.py assets/test_song.mid --title "MIDI 픽스처 (템포 120-180-120)"
echo "완료 — godot --headless --import 후 실행"
