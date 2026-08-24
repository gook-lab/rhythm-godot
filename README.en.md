# rhythm-godot

[한국어](README.md) | **English**

A Dance of Fire and Ice (ADOFAI) style **one-button rhythm game**. Godot 4.7 / GDScript.

Two planets orbit an angular tile path in alternation. The button is just spacebar.
There are no falling notes — **a tile's angle is the wait beat count**, so you solve it with your ears and hands, not your eyes.

Design rationale and decision logs: `~/.gstack/projects/rhythm-godot/kyb-ontact-main-design-*.md`
Work rules (invariants · verification · parallel session contract): [CLAUDE.md](CLAUDE.md)

---

## The Heart of This Game

```
If the orbit angular velocity is fixed at 180 degrees per beat, the relative angle between tiles is the wait time.

         prev+180 (start of orbit)
              \
               \   sweep
                \ ,-'`
        [pivot]  o------> cur (next tile direction)

    sweep = fposmod(cur - (prev + 180), 360)     # 0 becomes 360
    beats = sweep / 180

    straight line (cur==prev)     -> sweep 180 -> 1.0 beats
    U-turn      (cur==prev+180)   -> sweep 360 -> 2.0 beats
    90° bend                        -> sweep 270 -> 1.5 beats
```

So **there's no need for a note timeline data structure at all.** A single angle array generates both rendering and timing. With no two sources of truth, the bug surface itself vanishes where they could diverge. (Most clones fall apart here.)

### This Formula Is Verified by Real Measurement

```bash
python3 tools/verify_formula.py <actual .adofai files>
```

- ADOFAI baseline level (straight 10 tiles @ bpm 100) → **exactly 1.0 beat / 600ms interval**
- Real charted 3,155 tiles → mode exactly 1.0 (34%), all values on 1/12 grid, zero garbage
- Counter-proof: drop the `+180` and a straight line becomes **2 beats**, instant disqualification

Three things I found during verification:

1. **`.adofai` isn't valid JSON.** I found 3 kinds of violations in actual files —
   double commas (`"difficulty": 1, ,`), trailing commas, missing commas between sections.
   `tools/verify_formula.py:load_adofai()` handles this.
2. **CCW/CW convention isn't decided by this evidence.** The two variants are identical on straights and U-turns,
   different only on left/right turns (1.5 ↔ 0.5). We write our charts directly so it doesn't matter,
   but if we wanted to load real `.adofai` files, we'd need to pick.
3. **Real charts are way more complex than this project models.**
   Sample charts have 132 SetSpeeds (bpm 128→512) and Twirls on 25% of tiles.
   → Our decision to "use only charts we write" was vindicated.

---

## Architecture

```
AudioClock.tscn                  autoload — registered as scene
└── AudioStreamPlayer            clock owns its own playback node

Main.tscn                        safe to reload for restart
├── World
│   ├── Camera2D                 position also derived from audio clock
│   ├── Path (Line2D)            path drawn directly from angle array
│   ├── PlanetPair               set_orbit_progress(u) — no Tween
│   │   ├── PlanetA / PlanetB
│   └── JudgmentPopup
├── Judge                        3 judgment windows via @export
└── UI
    ├── CalibrationPanel         offset slider ±150ms
    └── DebugOverlay             sample · mean · stddev · clamp_hits · output_latency
```

| Script | Role |
|---|---|
| `ChartRuntime.gd` | angle→beats·coords. **only pure static functions.** test target alone |
| `Chart.gd` | Resource. single source of truth for chart |
| `AudioClock.gd` | audio clock + playback ownership. autoload |
| `Judge.gd` | ms judgment only. doesn't know render or state |
| `Main.gd` | wiring + TileCursor state + observer/input |

### 8 Rules We Keep

**1. Judgment is only by audio clock ms difference.** No coord overlap, no frame count.

```gdscript
var ms := (get_playback_position() + AudioServer.get_time_since_last_mix()
           - AudioServer.get_output_latency()) * 1000.0
_last_ms = maxf(ms, _last_ms)   # can go backward from thread jitter (official docs warning)
```

Using just `get_playback_position()` returns the same value until the audio thread mixes the next chunk.
The clock steps in stair-steps by the buffer size. That step width becomes judgment noise directly.

**2. `now_ms()` is called fresh in `_input()` and `_process()` at that spot. Never cache it.**
If you cache it in `_process` and use that value in `_input`, up to one frame (16.7ms at 60fps)
of judgment error slips in.

**3. There's only one time axis. Don't use `Tween`.**
Tween is a wall-clock driven by the frame loop, a second independent time axis from the audio clock.
Most common symptom: not a crash, but **"planet hasn't arrived yet but judgment says Perfect"** —
eyes and hands out of sync, hardest to diagnose.
We derive all rotation, camera position from `now_ms()`.

For the same reason, **don't subtract calibration offset inside the clock.** If you do, the moment you slide:
① `clamp_hits` goes up (false positive of hard gate)
② `maxf` holds the old value and the clock freezes by the offset amount.
We subtract offset at the judgment point.

**4. Render cursor and judgment cursor are separate. Both derive from `now_ms()` but advance differently.**

| Cursor | Advances when | Used for |
|---|---|---|
| `_idx` (judgment) | input arrives or `hit_time + miss_ms` passes | judgment, window |
| `_vis` (render) | `t >= hit_time` — just time passing | orbit angle, camera, popup pos |

Merging them means **planets freeze for `miss_ms` at each tile.** The observer waits until the deadline to catch late input,
and if render follows, it sticks at u=1.0 and stops.

Measured: render merged to judgment cursor, **25.8% of all frames are frozen**
(0.5 beat @ 120bpm = 110ms out of 250ms = 44%). Separated, it drops to **0.7%**.
`tests/SmokeRunner.gd` measures this ratio and fails if it exceeds 8%.

**5. Camera watches the 'average of surrounding tiles', not instant position.**

Whether planet, pivot, or center, **chasing instant position tracks the path's zigzag and bobs up/down.**
The demo chart alone has four 90° sequences (rectangle) twice and U-turns three times, so the path actually comes back.
It's not an algorithm problem, it's the path shape.

So we watch the average of ±2 tiles around (`Main.CAMERA_WINDOW`). In a rectangle zone,
it stays at the rectangle center. The symmetric window reflects upcoming tiles too (leading sight).
Between tiles we lerp smoothly by `u` so the target doesn't step.

Measured — path waste ratio (actual distance / net distance, 1 = straight follow):

| Camera target | frame move max | waste ratio | planet distance max |
|---|---|---|---|
| line lerp tile-to-tile | 29.35 px | 5.86x | 147 px |
| midpoint of both planets | 5.11 px | **8.17x** | 48 px |
| pivot (current tile) only | 96.00 px | 6.50x | 96 px |
| **average nearby ±2** | **3.09 px** | **2.65x** | 194 px |

Midpoint had the best position continuity (48px radius around pivot) but shook worst.
Not watching both metrics at once means fixing one breaks the other.

Window size tradeoff: ±1 is 4.07x/162px · ±2 is 3.32x/194px · ±3 is 3.10x/242px.
Bigger is calmer but planets drift further from screen center.

Shake (miss effect) uses `offset`, not `position` — feeding it to `position` means `position_smoothing`
kills it so 'shake' becomes 'slow drift'.

**6. Don't shake the screen every miss. Only short sharp shakes when combo actually breaks.**

In rhythm games misses are common. If shake is longer than tile spacing (250~500ms), it's constant vibration.
Measured: 14px/233ms shaking every miss gave **47.3% of frames shaking**, and visible path waste jumped
from 2.65x to **18.01x**.

And you can't flip direction every frame with `randf()`. At 144fps that's 144 direction changes per second,
so it reads as 'flutter' not 'impact', and feel varies by fps. We use fixed-frequency (22Hz) damped oscillation.

| | shake frames | visible path waste |
|---|---|---|
| every miss 14px/233ms · flip each frame | 47.3% | 18.01x |
| **break combo 3+ only 7px · 22Hz** | **4.5%** | **3.06x** |

> **Measurement trap:** after moving shake to `offset` I was still measuring only `position`.
> So I reported "camera waste 2.65x, pass" but the actual value was 18.01x.
> Now we measure **position for continuity, position+offset for shake separately**.
> Mixing them can misread legit shake as continuity failure.

**7. Charts need a count-in (default 4 beats).**

Musically necessary but also technically. AudioClock warms up (100ms) while render idles.
If the first tile is at 0ms, when it warms up the camera can skip 32px in one leap.
`tools/make_charts.py:LEAD_IN_BEATS`.

**8. Index is `angles[i-2]` (incoming direction) and `angles[i-1]` (outgoing direction). Not `angles[i]`.**

The orbit to tile `i` has pivot at `i-1`, and the planet launches from `i-2` and lands on `i`.
So the sweep is set by `angles[i-2]` and `angles[i-1]`.
`angles[i]` is the direction to exit tile `i`, one tile ahead.

The first version was off by one. **On straights, landing error is exactly 0 so you never see it,**
only where it bends:

| Path | error when off | after fix |
|---|---|---|
| straight | 0.00 px | 0.00 px |
| 90° step | 135.76 px | 0.00 px |
| rectangle (four 90°) | 135.76 px | 0.00 px |
| U-turn | 192.00 px | 0.00 px |

Tile spacing is 96px, so it was landing two tiles out of bounds and bouncing.
`tests/run_tests.gd:t_landing()` locks coords across six path shapes.
`tools/make_charts.py` verifies this invariant too every time it builds a chart.

---

## Running

```bash
# Song (metronome click) generation — BPM must be exact at sample rate
python3 tools/make_click.py 120 60

# Chart generation — don't hand-write angles. reverse-engineer from beat patterns
python3 tools/make_charts.py

# Converter unit tests (parser · density boost · step fill)
python3 tools/test_midilib.py
python3 tools/test_density.py

# Unit tests (zero dependencies) — 85 kinds
godot --headless --script res://tests/run_tests.gd

# Integration smoke (full song clear · observer · song end · clock backward · camera · shake)
godot --headless --audio-driver CoreAudio res://tests/SmokeScene.tscn

# Autoplay — full judgment chain validation (rank P / 100% / σ 2.1ms required)
godot --headless --audio-driver CoreAudio res://tests/SmokeScene.tscn -- --autoplay

# Deliberate miss — verify combo break and shake trigger
godot --headless --audio-driver CoreAudio res://tests/SmokeScene.tscn -- --autoplay --miss-every=5

# Checkpoint revival (clock doesn't freeze after seek — can't catch with unit tests)
godot --headless --audio-driver CoreAudio res://tests/CheckpointScene.tscn

# Hold tiles (release judgment · hitime shift · landing invariant)
godot --headless --audio-driver CoreAudio res://tests/HoldScene.tscn

# Input surface — grade mapping · echo filter · R restart · input after warmup/end
godot --headless --audio-driver CoreAudio res://tests/InputScene.tscn

# Replay — bit-perfect replay of judgment record (original == playback, element compare)
godot --headless --audio-driver CoreAudio res://tests/ReplayScene.tscn

# Autoplay demo — all tiles delta 0 · lock promise of P 100%
godot --headless --audio-driver CoreAudio res://tests/AutoScene.tscn

# Song select screen — list · keys · toggles
godot --headless res://tests/SelectScene.tscn

# Audio clock measurement (drift · jitter · 3-term vs 1-term)
godot --headless --audio-driver CoreAudio --script res://tests/probe_clock.gd

# Run
godot -e     # editor
godot        # direct run
```

**Controls:** `spacebar` judge · `R` restart

### Why Make Our Own Songs

Music usually has imprecise BPM or tempo changes or groove. When judgment goes wrong,
I can't tell if it's my code or the song. Clicks are sample-perfect —
measured max interval error 0.042ms, 60-second cumulative drift +0.08ms.

Why WAV: lossy compression can smudge attack transients. No decoder delay variance.
File sizes are huge so we gitignore them and commit only the generator.

---

## Milestones

### Weekend 1 · finish line = **"can evaluate feel"**

| # | Task | Status |
|---|---|---|
| 0 | Godot 4.7.1 install + project import | ✅ zero import errors |
| 1 | Validate angle→beat formula with real `.adofai` | ✅ pass |
| ⭐ | Procure song (metronome click) | ✅ interval error 0.042ms |
| 2 | `AudioClock` + calibration slider + debug overlay | ✅ clock measured (below) |
| 3 | `Chart` + `ChartRuntime` + unit tests + path render | ✅ 31/31 unit tests |
| 4 | `Judge` + `TileCursor` + delta display | ✅ zero load/runtime errors |

> **Not yet done:** have a person actually play and judge feel.
> Above ✅ means "compiles and runs", not "fun".
> Running `godot` and hitting spacebar is next.

### Measurements (2026-08-07, Apple Silicon / macOS)

```
godot --headless --audio-driver CoreAudio --script res://tests/probe_clock.gd
```

| item | Dummy (headless default) | **CoreAudio (real)** |
|---|---|---|
| drift (speed error) | −4.03% | **−0.02%** |
| jitter (stddev after detrend) | 7.86ms | **0.78ms** |
| backward runs (3sec) | 7 | **0** |

**Audio clock gets 0.78ms.** Criterion 3 budgets 15ms total,
leaving 14ms+ for input path and human hands.
The risk I worried most about (audio clock kills feel) is resolved.

**Watch the Dummy −4% drift.** Calibration can't catch it (widens over time). If you're running
auto timing, you must add `--audio-driver CoreAudio`. With it, CI can measure too.

#### 3-term vs 1-term — cross-model debate settled

| formula | jitter |
|---|---|
| **3-term** `pos + since_mix - latency` | **0.78ms** |
| 1-term `pos` only | 3.44ms |

An independent reviewer said "3-term is overkill, start with just `get_playback_position()`",
and I countered "that term isn't insurance against flakiness, it fills the constant staircase".
**Measured: 3-term cuts jitter by 2.66ms** — 18% of the total 15ms budget. Not premature optimization.

#### Not yet measured

| config | stddev |
|---|---|
| `agile_event_flushing` OFF (default) / ON | ? ms |
| `vsync_mode` ON / OFF | ? ms |
| `output_latency` 15ms / lowered | ? ms |

Input path config **needs actual keypresses**, not probe. Launch the game and watch
debug overlay stddev while toggling.

### Success Criteria

1. 30+ seconds complete + **restart 3 times in a row** and judgment stays identical (`_last_ms` reset check)
2. Offset slider ±150ms, next judgment reflects it instantly
3. **judgment error stddev < 15ms** — same section 10x, all `delta_i` as one sample
   - Miss: don't fail immediately, log audio backend·buffer·`output_latency` first.
     If backend swap doesn't improve, that's machine floor not code bug.
     **Goal is to tell code bug from machine floor. 15 is the number, not the goal.**
4. **Clock backward *size* never exceeds one mix chunk (~6ms).** Not count.
   - Measured: 20-second playback, 20 backward runs, max 5.7ms. **Zero isn't normal.**
     `get_playback_position()` and `get_time_since_last_mix()` update independently,
     so sampling right after mix attaches old `pos` to reset `since_mix`.
     It's structural; monotone clamp is there to prevent exactly this.
   - Tried fixing `get_output_latency()` at start; size stayed the same —
     latency jitter wasn't the culprit.
   - **Slider wiggle should never increase backward count** — if it does, offset is still
     inside `now_ms()`.
5. Judgment feedback within 33ms of input

### Weekend 2 · finish line = "looks like a game"

5. Orbit effect + song end · 6. result tally + cleanup

---

## Out of Scope (M1)

Level editor · map share · auto-chart · **multi-planet (3+)** (if the field exists, it gets half-finished someday) · 
**seek/loop** (breaks monotone clamp, defend with path rules not code) · web export · SFX · multi-song · 
path morph mechanics (M2)

---

## Known Harmless Warnings

At exit you see this. **Don't chase it — verified closed.**

```
WARNING: 2 ObjectDB instances were leaked at exit
ERROR: 1 resources still in use at exit
Resource still in use: res://assets/click_120.wav (AudioStreamWAV)
```

`demo.tres` (Chart) holds wav via `Chart.audio`, and `Main` holds it via `@export`.
Resource release order at process exit leaves references.
`AudioClock._exit_tree()` stops playback but doesn't cut the reference.

Process is dying anyway, cost is zero. When reading real errors from the log,
filter these three lines.

---

## Judgment and Score

### 7-grade (ADOFAI system)

```
TooEarly · VeryEarly · EarlyPerfect · Perfect · LatePerfect · VeryLate · TooLate
```

Perfect has 3 kinds (E/normal/L) and **only normal Perfect counts as perfect accuracy**.
This lets "got it all but slightly off" differ from "got it precisely",
so you can tell if feel improved. Rank is `P / SS / S / A / B / C / D / F` —
P only happens if all judgments are normal Perfect.

### Judgment window narrows by BPM

Fixed ±110ms and **when adjacent tile spacing drops below 220ms, windows overlap and
one keypress counts on both tiles.**

| beat | bpm | spacing | fixed window ±110 margin |
|---|---|---|---|
| 0.5 beat | 120 | 250ms | +30ms (tight) |
| 0.5 beat | 140 | 214ms | **−6ms overlap** |
| 1/6 beat | 340 | 29ms | **−191ms collapse** |

So we cap the entire judgment ladder at **half the distance to neighbors**
(`Judge.set_gaps()`). Overlap becomes structurally impossible. Grade ratio preserved.
ADOFAI does the same: "faster = stricter".

`tests/run_tests.gd:t_judge_windows()` locks that window width never exceeds spacing
at 250·214·125·29·8ms.

### HUD

- **TimingScale bar** — center is accurate, left is fast. Last 40 inputs tick as marks.
  Blue triangle is mean. **Graph and measuring tool**: marks bunched left means offset issue (slider fixes it),
  wide spread around center means jitter (won't fix). When window narrows, bar zoom matches so marks don't crowd.
- **felt BPM** = tile BPM ÷ current hop beat. One-sixth hop at 340bpm is 2040.
  The number shows why the window has to narrow.
- rank · accuracy · combo · music time · backward count and max size · output_latency · fps

### Effects

Neon glow (HDR 2D + `WorldEnvironment` glow — feed colors > 1.0 for bloom on that part),
grade color flash on planet (2 frames), screen shake on miss.
**Only shake uses frame time and decays** — pure effect, independent of audio clock.
All other visuals (orbit angle, camera) still derive from `now_ms()`.

## Test Constraints

**`--script` mode doesn't register autoload.** `AudioClock` identifier fails, so
`Main.gd` won't compile. Integration tests that boot `Main` use a **scene**
(`tests/SmokeScene.tscn`) to run the normal path.
`run_tests.gd` watching only pure functions uses `class_name` globals so it can use `--script`.

### Afterimage Trail

Both planets leave a 22-frame trail of where they went. Older trails thin and fade
(`PlanetPair._draw_trail`). Thickness varies per segment so we use per-segment `draw_line`
instead of `draw_polyline` — polyline has fixed width.

Trail **records, doesn't drive.** Each frame we just log position; nothing moves,
so we don't break rule 3 (one time axis).
Pivot doesn't move so we discard < 1px motion to avoid stacking.

---

## Real Song (song140)

```bash
python3 tools/make_song.py      # generate song (assets/song_140.wav + .json)
python3 tools/make_charts.py    # generate chart (reads song onsets)
```

140bpm 4/4 chiptune, 40 bars 69.6sec. Lead (square) + bass (triangle) + kick/snare/hihat.
A-B-A-C form with intro/outro.

**The most important output is `song_140.json` onsets, not the WAV.**
The chart generator reads that to build tile rhythm — song and chart must come from the same source
or they'll diverge. Retyping it by hand will always misalign.

174 tiles · 173 judgment targets · 6.43sec count-in (intro 4 bars as-is).
Autoplay result: **rank P · 100.00% · combo 173 · σ 2.4ms**.

### Song Constraints

**One tile can represent (0, 2] beats of wait.** `sweep` is (0, 360] and `beats = sweep/180`.
You can't make a 3-beat rest as one tile.

The first song had 9 beats of silence in the outro. `make_song.py:verify()` caught it.
Fixed it with a pair of long tones. This verification runs every time we make a new song.

### Rabbit / Snail Tiles

ADOFAI's `SetSpeed`. Goes into `Chart.speed_changes` as `(tile index, multiplier)`.
Multiplier is replacement not cumulative — you need to read the speed at each tile for debug.

song140 has C section (28 bars) with rabbit ×1.5, restored in outro, last two bars
snail ×0.7. Up triangle = speed up, down triangle = slow down.

**This is where the judgment cap earns its keep.** Speed up narrows tile spacing,
and `Judge.set_gaps` caps the window to neighbor distance so it narrows automatically.
Tested — even 4x speed section (125ms spacing) judgment (112ms) doesn't touch neighbors.

### Twirl — The Only Tool for Path Variety

`0.5 beat hops always bend −90° (right turn) in CCW.` Four eighths in a row make a closed square.
song140 has 80 half-beats, so the path was all loops.

Twirl flips the turn direction. Then **the same beat bends opposite**:

```
CCW:  cur = prev + 180 + b*180      0.5 beat -> prev - 90 (right)
CW :  cur = prev + 180 - b*180      0.5 beat -> prev + 90 (left)
```

Rhythm stays the same, shape changes. Landing invariant holds both ways
(end angle is always `angles[i-1]`). Tested.

`tools/make_charts.py` auto-places: flip before cumulative rotation hits threshold.
We tuned the threshold (song140, camera window ±5):

| loop_guard | twirl count | path waste |
|---|---|---|
| 90° | 77 (44%) | 3.28x |
| 180° | 39 (23%) | 1.76x |
| **270°** | **28 (16%)** | **1.46x** |
| 360° | 21 (12%) | 4.39x |

Non-monotonic. Flip too often and zigzags pile up so path gets long;
too rarely and loops come back. 270° = flip before 3/4 of a circle.

> When I first wrote it at 180° twirl count was 39 (22.5%), but measuring real ADOFAI charts
> showed 787/3158 = **24.9%**. A heuristic born from pure geometric need hit the same density
> as the original. Same constraint, same answer.

**Twirl solved the camera problem too.** Less loop means we can narrow the window:

| | camera window | path waste | planet distance |
|---|---|---|---|
| before twirl | ±5 (limit) | 4.75x | 274px |
| **after twirl** | **±3** | **1.75x** | **241px** |

Both metrics improved at once. Camera tuning could never break through that ceiling;
the problem was the path, not the camera.

### Path Planning — loop_guard Replaced by Beam Search (2026-08-07)

Multitrack real songs exposed loop_guard's ceiling. Watching cumulative rotation alone
**can't stop the path from folding back on itself** — measured overlaps (non-adjacent tile pairs, centerline < 0.92 tile width)
hit 564~4,902 pairs per song.

`make_charts.plan_path` replaced it. Beam search (width 64, deterministic) picks rotation per hop,
cost is "how much does the new tile overlap existing tiles".
Rhythm untouched — only shape is choosable.

**2-beat hops can't be fixed by spin alone.** Sweep is exactly 360° so
`exit direction = entry direction + 180`, always U-turn regardless of spin. Charts with 2-beat step chains
(mureka_07: 68% of hops) had tiles stacking dozens deep on the same spot.
So we added one more tile type:

**Ghost (auto-pass) tiles** — `Chart.ghost_tiles`. Split 2-beat wait into 1+1 and don't step the middle.
1-beat hops are straight so fill chains march in line instead of bouncing.
Tap rhythm unchanged (triad timing locked: Python recalc vs tempo map < 0.01ms · GDScript verify_chart.gd · 
stepping-tile cumulative beats == onset cumulative).
Judgment cursor skips ghosts (`Main._advance`), window cap uses "judgment neighbor" distance.
Render is half-size dim outline — we keep "bright stuff is what you play" rule.

**Repeat sections use pattern templates (tagging workshop dialect).** Greedy hop-by-hop unroll on 3+ same hops
(stream/fill chains) produces noise spins, no pattern. So we template entire sections — zigzag ·
2/3-period wave · steady-spin arc (spiral), 2-beat chains are line march · stairs · ladder ·
U-turn bounce. Collision cost applies equally so blocked spots drop patterns naturally.
Cut by 8-hop chunks so beam can switch patterns at boundaries.

Result: 19 songs overlap total 25,516 → 1,062 pairs (**avg 96% reduction**).
Remainder is 1/12-beat stream geometric overlap (15° sweep = 165° bend either way)
which reads orderly like real high-speed ADOFAI sections.

loop_guard stays in `angles_from_hops` (test/demo charts).
Real-song charts (`chart_from_song`) all use planner.

### Midspin — A Degree of Freedom That Wasn't There (2026-08-10)

As density rose, tight songs' paths coiled (mureka_06 395 pairs · mureka_08 305 pairs).
Planner couldn't unwind them no matter what, and the reason was clear:

**We could only choose one thing per hop: rotation direction.** Rhythm forces rotation *size*
(angle = beat × 180°) so short hops always bend hard:

```
0.25-beat hop -> sweep 45° -> heading turns 225° (= −135°) -> four of them lands you back
```

ADOFAI has one more: **midspin** — reach a tile and don't hand off, the planet keeps going.
Then orbit start angle flips 180°:

```
normal      exit = entry + 180 + spin*b*180
midspin     exit = entry       + spin*b*180
```

**Same beat, flipped shape.** Same 0.25-beat becomes **45° bend instead of 225°**, so the coil unwinds
to a gentle arc. Rhythm untouched, geometry alone changes. It's the only tool to reshape without
touching rhythm.

| | overlaps (pairs) |
|---|---|
| loop_guard heuristic | 25,516 |
| beam + ghost + template | 1,504 |
| **+ midspin** | **19** |

Per-song worst cases vanished: mureka_06 395 → 1 · mureka_08 305 → 0 · mureka_14 278 → 2.
Planner picks 4 (spin × midspin) per hop, and templates spawn 3 midspin flavors each (none/all/alternate)
per spin. `COST_MID = 1.2` throttles overuse — some songs don't use it at all (song140 is 0).

**Landing invariant is most at risk here.** Shifting start angle 180° means start angle and sweep
must be fixed together or the planet lands off-tile. We locked all 4 (spin × midspin) combos by coords
(`t_landing`, error 0.0000px).

Color: twirl is purple spiral, midspin is **cyan double-loop**. Without distinction,
"why does it suddenly turn the other way?" is unreadable.

### Tile Types — Checkpoint · Hold · Tri-Planet (2026-08-10)

Real game events. Missing types filled. Our **ghost tiles are the same as ADOFAI Auto Play Tiles**
— same constraint, same answer.

| ADOFAI | ours |
|---|---|
| SetSpeed (rabbit/snail) · Swirl · Auto Play Tiles | existing |
| — | midspin (we added first) |
| **Checkpoint · Hold · Multi Planet** | **added this time** |
| Beat Pause · Free Roam | not yet |

#### Checkpoint — Why We Unblocked Seek

Songs are 150~180sec with 500~850 tiles. Die at 80% and you replay 2 minutes — that's punishment, not challenge.
When health bottoms out, jump 1.6sec before the last checkpoint (same reason as count-in — can't judge 
the instant you revive). 4~6 per song, every 30sec.

**This requires seek.** Until now I hardcoded "don't make it" — the path lives on `now_ms()` monotone clamp
(`_last_ms = maxf(...)`), assuming time never goes backward, so calling `_player.seek()` could
**freeze the clock forever on an old value**. Not a crash — all judgments after would silently miss.

The fix was rules not code: clamp is invariant *within a playback run*, not across the whole song.
`start()` already resets history every run, so `AudioClock.seek()` does the same reset and it's indistinguishable
from a new segment. Direct `_player.seek()` paths still don't exist.

Unit tests can never catch it, so `tests/CheckpointScene.tscn` runs the real song, kills you, respawns,
and verifies **clock keeps flowing after the jump**
(measured: die at 33.3sec → revive at 29.9sec → clock normal, zero backward runs).

#### Hold — The Game's First Second Input Verb

Step it and the planet does N more spins in place while you keep the key down.
**Release counts as a judgment** so one hold is two judgments (count divisor twice).

- One lap = sweep 360° = **2 beats**. 360° multiple means **landing spot doesn't change** —
  adding holds doesn't warp path geometry.
- Release (`pressed == false`) is a value we threw away at the start of `_input` until now,
  so it's a new signal path. We hold `_hold_key` — judgment key is almost every key (both hands tapping)
  so "let go any key to end" risks another hand's tap breaking the hold.
- Release and don't, watcher confirms miss (symmetric with tap — both have no event).

**Hold alone shifts hitime forward.** Can't insert it later into sync'd charts — hold duration must be carved
from an existing hop, but we max out at 2 beats (the max hop) so **hold must span multiple onsets**.
That's a job for the converter (midi2song) that knows about sustains.

Real-song auto placement runs `place_holds`. **On by default** (disable with `--no-holds`).
Opt-in means one forgot `--holds` on a regenerate and holds silently vanish — nearly happened — so I made it opt-out.
Three rules: all from the music:

1. **Only over sustains** — only when melody note actually holds 2n+ beats (duration cap).
   Short note with hold means sound ends but hand's stuck — false action.
2. **Release-to-next-tap time** — gap must exceed the ms floor (150ms, same as fill).
   Release is a judgment, so release-press gap is same physics as tap-tap gap.
3. **No tiles during hold (press~release)** — held hand can't tap.
   Fill/boost taught the gait to skip from "release onward", and minimum spacing measured from release.

Absolute onset never moves — hold swaps 2n beats of wait for (2n-beat hold) + (remaining wait),
sum is unchanged, next tile lands at the same spot (original mode's hop-level tempo fit preserves endpoints
so hold presence doesn't break it).

Measured (mureka_09, real audio + --holds): 24 holds (50 beats total) placed on bass sustain,
density 3.75 → 3.43 taps/sec (holds absorb fill chains), file check 0.000005ms/tile · engine 0.0092ms ·
autoplay smoke rank P · 100% · 505 judgments (tiles 481 - ghosts 3 + holds 24×2 — divisor exactly doubled).
Smoke harness learned release — release at hitime and let go the key.

**Full-chart rollout (2026-08-10):** 14 songs, **116 holds · 147 laps**.
Per-song variance is honest — heavy sustain/pad songs are 16~24 but
**1/12-beat stream songs (mureka_06) are 0**. No sustain means no holds.

| song | holds | | song | holds |
|---|---|---|---|---|
| mureka_09 | 24 | | mureka_07 · 08 · 12 | 5 |
| mureka_03 · 04 | 16 | | mureka_01 | 3 |
| mureka_13 | 14 | | mureka_02 · 05 · 11 | 1 |
| mureka_14 | 13 | | mureka_06 | 0 |
| mureka_10 | 12 | | | |

Engine cross-check all 15 charts **max 0.0096ms** (allow 1.5ms).

> `mureka_09` is real-audio chart so regenerating without `--audio` falls back to synth.
> Lock prevents full regenerate from running there — intentional, we skip that song
> and ran the rest.

---

## Autoplay Demo and Auto Calibration (2026-08-11)

Three overlapping issues emerged in real use (with screenshots as evidence):

1. **Judgment averaged +79.7ms late, so offset slider maxed at +150.** Bluetooth headphones run 150~250ms normally — actual latency ~230ms was out of range. Widened the slider to -250~+400 and added result screen **A** showing this play's mean error stacked on offset (only suggested when 4+ samples, all ≥10ms). Asking someone with +80ms bias to tweak the slider manually isn't calibration, it's torture.
2. **Replay overwrote PB.** Failed replay with misses climbed to "career best". Added guard `not _replay_mode and not _auto_mode` to both record and replay saves — watching can't overwrite doing.
3. **"Autoplay must always be perfect."** V (replay) is faithful to my play, so if I can't hit it, replay can't either — that's a feature, not a bug. Instead **O** is the true autoplay demo: bot steps every tile with delta exactly 0 (including hold press/release). We bypass the frame-quantized input path and feed 0 straight to the same code (_apply_press) to skip even frame error. AutoScene test locks "all delta == 0 · P 100%".

## Difficulty·Rating·Badges — ADOFAI.gg Adoption (2026-08-11)

We borrowed three things from adofai.gg (ADOFAI community level database).

**Difficulty grade (1~21 scale + color ramp)** — adofai.gg's trusted curators assign grades, but our charts are all pipeline output so we measure (`make_charts.difficulty_of`, stored as `difficulty` in chart):

- **Speed** = peak taps/sec (2-sec window 95th percentile — max skewed by one burst) × 0.9 + mean taps/sec × 0.75. Started with log blending: 14 songs clustered at 11.1~13.0 with no separation. Switched to linear: now 8.5~11.2.
- **Density** = ratio of consecutive gaps < 130ms × 3.2 (length of near-limit sections).
- **Tech** = midspin·twirl density + boost sections + holds (each capped).

Calibration: click tracks (t01~) 1.0~3.8 · demo 7.5 · mureka 8.5~11.2. Not absolute scale — just "order within our catalog". Song select shows difficulty numbers with adofai.gg color ramp (cyan→green→yellow→orange→red→purple).

**Play rating** — `difficulty^1.6 × ((accuracy−70)/30)^2`. Hard songs gain exponentially; high accuracy zones steepen (100%: ×1 · 95%: ×0.69 · 90%: ×0.44). Failure is 0. **Overall rating** is decayed sum of per-song bests in descending order: 0.9^i (osu/adofai.gg style) — grinding one song has a ceiling, spreading across songs pays better. Shown at top of song select.

**Clear badges** — **PP** (every judgment Perfect) > **FC** (zero misses). Orthogonal to rank: all-E/L no-miss is "FC but A-rank", high-accuracy-with-misses is "S-rank no-badge". Checkpoint use means no badge — revived runs aren't no-miss. Record keeps only the best badge (PP covers FC).

## Tightening Judgment Window — "Half the Difficulty Was Just Timing" (2026-08-10)

Even after pushing chart density to original extra-hard (felt BPM p95 364~556), it felt easy. Miss window was ±110ms, so 100ms off didn't kill you. Measurements done: at actual human spread σ 20~30ms, Perfect ±30 was half luck.

Windows 110/60/30 → **80/45/25**. Window-to-neighbor cap (`set_gaps`) stays, so fast sections still narrow automatically. Retargeted test sets tied to window values (aiming at "band center" not boundary — frame hiccup margin).

## Replay — Rewinding Feel Debugging (2026-08-10)

This project's goal is "can evaluate feel", but where jitter broke doesn't show in numbers alone. Result screen lets you hit **V** to instantly rewatch the run just now.

Key design: **we log judgment results, not keypresses** — (type, tile, delta). Playback re-judges the recorded deltas so score·rank·spread replay **bit-for-bit** (ReplayScene test verifies element-wise). Frame quantization moves launch timing but doesn't shake judgment — proof it's handling lag correctly. We don't record misses or checkpoint revivals — same judgment sequence means observer and health recover at the same spot; rewind handles clock backup naturally (fire condition is "clock >= target", so backward clock just makes the next event wait).

Real input and replay take the same path (_apply_press) — splitting them risks one getting fixed while the other lies. Only real plays save to disk (`user://replays/`) — test runner doesn't pollute user files (stated principle). HUD shows REPLAY marker; R stops the replay so you can play live.

## Finishing and Exiting (2026-08-10)

- **Outro grace**: Results popped the instant you hit the last tile, cutting the song short. Now results overlay 1.5 seconds later while **music plays uncut to the end**. We only cut on failure — die mid-song then silence means you didn't notice. Smoke's "orbit frozen" gate excludes outros so planet sitting on the last tile is correct.
- **Mid-song exit**: ESC (pause) → **Q** song select. Judgment keys are nearly all keys so accidental fires happen; two steps is intentional.

## Headless Tests Shouldn't Make Sound

`--audio-driver CoreAudio` uses **real audio hardware.** Leave it on and every test run plays music from the speaker (actually happened once, causing confusion).

`tests/probe_clock.gd` and `tests/SmokeRunner.gd` call `AudioServer.set_bus_mute(0, true)` on startup. Bus mute stops audio output, not mixing, so `get_playback_position()` keeps flowing.

Verified no measurement impact: jitter 1.14ms (sound on) vs 0.95ms (muted) — both within run variance (0.78~1.14ms).

---

## Input Surface Testing

`tests/InputScene.tscn` — checks what autoplay can't see.

Autoplay presses at exact times only, so we know the judgment chain is self-consistent. These need the real input path:

| Check | Content |
|---|---|
| Grade mapping | +45ms → LATE PERFECT · −45 → EARLY PERFECT · ±85 → LATE!/EARLY! · 0 → PERFECT |
| No input | Watcher issues TOO_LATE |
| Key repeat | Echo 3× same frame advances tile by 1 only |
| Input during warmup | Ignored, doesn't pollute spread sample |
| Input after song end | 5 presses, no crash |
| R restart | Clears idx·finished·score, **keeps spread sample**, resets clock counter |

### Finding: Input Path Has +11ms Bias

Measurements all shifted positive — target 0ms came 8.8~12.3, −45 came −33.1, −85 came −72.3.

~7ms is harness polling once per frame, hitting max one frame late; rest is engine input dispatch. Real keyboard adds hardware/OS latency on top.

**This matches the design prediction that offset slider must go positive.** Next: measuring how much a human's average actually shifts.

---

## Path as Individual Tiles

Originally `Line2D` continuous strokes. Switching to tiles wasn't decoration — **handling convenience.** 

Continuous lines let your eye  can't count ahead. Separate tiles mean **tile count = remaining beats**, so you can visually prepare timing. Original does this for the same reason.

Each tile is a square with side = spacing, rotated to exit angle. Straight runs: center gap == side, so tiles touch perfectly. Bends: inside overlaps, outside spreads — original does the same.

**Tiles read as outlines, not fills.** Interior is nearly transparent (alpha 0.10~0.22), just the border glows. Boost border color > 1.0 (HDR) and `WorldEnvironment` glow makes it shine. Opaque fill makes the path look like a wall, killing the feel.

Colors change by state — you need to see what to tap now:

| State | Fill | Border |
|---|---|---|
| Passed | 0.10 alpha | dim (0.35, 0.42, 0.62) |
| Coming | 0.14 alpha | HDR (1.15, 1.35, 1.90) |
| **Target now** | 0.22 alpha | **HDR (2.20, 2.00, 1.10)** · width 3.5 |

### Tile Shape Isn't Decided by Exit Angle Alone (2026-08-10)

Even stacking tile types (ghost·midspin·hold·checkpoint) the path stayed "rectangle pile". Base shape was identical.

**Cause 1 — shape looked only at exit.** `_quad(center, deg, half)` rotated a square by `angles[i]` only. So at bends, previous tile's exit and this tile's entry faced different angles, misaligning; inside overlapped, outside gaped.

Build from **two angles** like original:

```
front ⊥ entry (angles[i-1])   ·   back ⊥ exit (angles[i])
```

Neighbors lock seamlessly — mathematically. **This design flipped inside a day.** Real wedge geometry was unstable: bend angle made tile area bounce (90° corner half-width), and midspin angle combos turned some quads into self-crossing **bow-ties** when rendered (screenshot: target tile, folded sliver). Marker sizing needed compensation.

Attempt 2 (fixed square + bisector spin) was stable but bends stacked diagonally — "card shuffle" look. Placed alongside original, original tiles **meet at seams as one ribbon**.

Final (③): tile i is a **bent domino** — leaves from mid-join (previous-tile center, perpendicular to entry), bends at center, ends at mid-join (next-tile center). Elbow point: polyline miter formula as-is `M = ±(v_in+v_out)·half / (1+u_in·u_out)`, clamped at 1.6half to stop spikes from sharp bends (clipped spots smooth). 

- Straight = exact-touch rectangle (joints = midpoint of centers, QED)
- Bend = elbow · U-turn = rectangle fallback (width → 0)
- Constant width/length so no ① instability, seams lock so no ② overlap

Shape silhouettes (diamond·stretched) removed — breaks track continuity. Tiles use markers (color·shape) instead. Ghost alone stays small (don't-step section reads as broken).

U-turns: front and back occupy the same spot so shape vanishes. Path actually doubles back there (overlap is correct) but you need to see it, so we draw a square (`_FOLD_DOT`). Fold detection **uses unit vectors before scaling** — else threshold drifts.

**Cause 3 — corners were sharp.** Up through 90° corners came out as perfect triangles, jerking visibly. Original tiles magnified: not sharp squares but **rounded-corner capsules**, exposed ends capped semi-circular. Rounded ends absorb angle differences with neighbors, so **any bend holds smooth seams** — sharp shapes needed exact miter math; rounded get it free.

`_round_poly` bends each vertex via quadratic Bezier (control = original vertex). Radius capped at `min(r, shorter of the two adjoining sides / 2)` — discard at zero-width spots or the shape flips. Coincident vertices removed first.

Cost: 4 points per tile → 20. TilePath redraws only on cursor change, not each frame — 848-tile autoplay stays at 137fps (was 145).

**Follow-up — markers dropped outside.** Shapes varied by type but markers (swirl·double-loop·diamond·ring) were "tile coords, fixed size". On narrow wedges, badges poke out **clipped looking** — measured mureka_08: 345 midspin tiles, **94** landed max 18px off.

Fixed with two values from the shape (`_marker_fit`):

| | Why |
|---|---|
| pos = **centroid by area** | wedge tile-center isn't shape-center |
| size = **inradius** at that point / half | tight, auto-shrink |

Square: centroid = origin, inradius = half, ratio exactly 1.0 — **old charts don't move 1px**. After: 94 overflow → **0**. Too-small gets unreadable so `MARKER_MIN_SCALE = 0.5` floors it.

Mid-fall tiles shrink but markers didn't, floating in air — scale by the same ratio.

**Cause 2 — type showed only in marker.** Swirl·diamond·ring on identical bases: path browsing shows "badge there?" not "what tile?". Shape itself explains function:

| Tile | Silhouette | Why |
|---|---|---|
| Normal | square (wedge if bent) | — |
| Ghost | small square + dashes | don't step |
| Checkpoint | **diamond** (45°) | landmark — trade fit for visibility |
| Hold | **stretched toward travel** (ratio to spins, capped 2.2×) | takes more time as length |

Scaling only **length**, not width. Extract perpendicular from stretched vector or the tile fattens — separate direction and magnitude, perpendicular first. 

Fall and impact use the same shape (`_quad_of` rotates/scales local shape). Otherwise landing tile flips to rectangle — jarring.

### Tile Impact

Hit tile **puffs in judgment color and vanishes** (0.22sec). Radial flare bursts too. Grows then fades, not return — reads like afterimage.

Colors = judgment: Perfect cyan · E/L Perfect lime · Very yellow · Miss red. Path holds what you just hit, so next prep section reads last result while committing to next.

Impact is pure effect, so frame-time decay, not audio clock (like shake). No active impacts → `set_process(false)` — don't redraw 174 tiles pointlessly every frame.

---

## Screen Elements

### Top Center — Judgment + Combo

Eyes follow the path, so side-judgments get missed. **One screen-fixed spot.** Judgment name and combo number in judgment color.

### Start Countdown

Intro is 16 beats. Counting all is tedious. **Count from 4 beats before first tile** (`Main.COUNTDOWN_BEATS`). Each beat, brightness rises; last is `GO`.

### Left — Key Viewer (2026-08-11)

Our take on ADOFAI community KeyViewer mode. Judgment key tiles light on press, showing per-key cumulative taps and **last-1-sec KPS** — which hand rests in dual-hand, peak taps/sec. Part of feel measurement.

- Default binding (empty = all keys judgment) **creates slots in press order** (max 8). With K binding, keys slot fixed from start.
- Main feeds data, not self-fed: real input goes through judgment filter only (ESC·R would flicker), replay·auto have no key events so `_apply_press` is the sole source (tap flash 110ms, holds promote sustain).

### Background — Beat-Sync Shader (2026-08-11)

`shaders/background.gdshader`. Zero-asset rule kept — no noise texture, just 3-layer sine drift + beat-sync exponential glow + Perfect echo + vignette.

- **Phase always derives from AudioClock.** DIY time means pause·seek breaks beat-sync and music parts ways.
- Tint = song difficulty color (SongSelect ramp) · energy = combo.
- First tuning: "too stroby" — Perfect every beat = 1.0 flash reset became 5 taps/sec strobe. Capped maxf(0.5) + half weight. Glow is breath, not lights.

### Settings — Song Select S Key (2026-08-11)

↑↓ items · ←→ adjust · Enter/ESC save & close. All stored in `records.json`.

| Item | Value | Notes |
|---|---|---|
| Judgment leniency | lenient ×1.4 (miss ±112ms) / normal ×1.0 (±80) / strict ×0.7 (±56) | ADOFAI judgment difficulty. Window-to-neighbor cap applies regardless — even lenient can't overlap windows |
| Music volume | 0~100% | AudioClock player. Count-in click baked into audio, scales together |
| SFX volume | 0~100% | hit/miss. Sits on −4dB trim |
| Input offset | −250~+400ms | same backing as in-game slider. Result screen A = auto-correct |

Leniency shows three places: **below start countdown** (clearly, pre-check) → **during play** (hidden normally; lenient=green/strict=red dim residue only) → **result screen** ("lenient judgment ×1.4"). Applied to real play only — runner drifts per-machine if it changes.

### Clear Result Screen

Rank · accuracy · judgment spread (way too fast / fast / fast! / perfect / slow! / slow / way too late) · max combo · **mean and stddev of judgment error**.

Last two matter: mean shifted means offset slider helps (fixable), stddev large means jitter (unfixable). Result screen shows the split every time.

Accuracy text: 100% flawless · 99%+ near flawless · 95%+ excellent clear · 90%+ clear · 70%+ complete · below try again.

### Failure Condition — Health (Replacing Accuracy-Based)

Started with "accuracy below 55% = fail". Real use broke it instantly:

- Accuracy is **cumulative** so one drop is hard to recover from. Miss early while learning and you're done — harsh for rhythm games.
- Silent watching reached fail in 12 judgments (1:09 song done in 11 seconds).

Switched to standard **health** (`Score.health`):

| Event | Health change |
|---|---|
| Miss (TooEarly/TooLate) | **−7** |
| Perfect | +1.6 |
| E/L Perfect | +1.0 |
| Very Early/Late | +0.4 |

- Start 100. Reach 0 and fail. Roughly **15 consecutive misses** to die.
- Good play recovers — bad start isn't execution.
- **Never pressed = no drain** (`Score.started`). Watching isn't failure.
- Health bar top center. Yellow below 60, red below 30.

Smoke measured: silent watch → safe clear · 20% miss rate → health 78 survive (rank B) · 50% miss rate → dead at tile 39 (health 0).

### Paused Clock

Pause freezes `get_playback_position()` to **0**. Raw math sends clock backward by song length (measured −20.9sec). `now_ms()` holds its last value during pause.

### Camera Guard is "Spike Ratio"

"Max frame move < 20px" was wrong — same code, 4 runs gave 5.2 / 10.0 / 17.5 / 36.3px max (p99 steady at 3.0~3.3px). That's measuring **OS frame hiccup**, not camera design. Real discontinuity spans frames, so measure **ratio of spikes** (frames > 8× median, threshold > 0.3% = fail).

### Passed Tiles Fall Away

Original's `trackDisappearAnimation`. Stepped-on tiles gravity-drop, spin, fade (1.15sec). Fully fallen tiles don't render.

Randomness (initial vel·spin) **drawn once at drop start, then stored.** Redraw every frame and tiles flutter in place. Several tiles advance per frame possible (lag spike) so `set_cursor` drops all from prior to new.

---

## MIDI → Song + Chart (AI Music Path)

> **Warning — mureka_* charts don't regenerate from this repo alone.**
> `.gitignore` rule: "generated assets rebuild from generators". mureka breaks it — sources are stems received from Mureka, not in repo. `.tres` files commit, `.wav` files ignore, so cloning another machine runs:
>
> ```
> ERROR: Resource file not found: res://assets/mureka_03.wav
> ERROR: res://charts/mureka_03.tres:11 - Parse Error: [ext_resource] ...
> ```
>
> Built-in charts (t01~t05·demo·song140·test_song) regenerate from `make_charts.py`·`make_song.py`·`make_click.py`·`make_test_midi.py`, unaffected. Two options: **ship source MIDIs** (86 files, 740KB — smaller than one WAV) or **exclude mureka from `.gitignore`**. Currently single-machine, kept as-is.

```bash
python3 tools/make_test_midi.py                 # generate fixture
python3 tools/midi2song.py assets/test_song.mid # MIDI -> wav + json + .tres
godot --headless --script res://tests/verify_chart.gd -- --chart=res://charts/test_song.tres
godot --headless --audio-driver CoreAudio res://tests/SmokeScene.tscn -- --autoplay --chart=res://charts/test_song.tres
```

Get MIDI from AI (AIVA·Suno etc) and one line builds song + chart. Why not AI audio directly (2026-08 survey): AI output has subtle tempo drift (0.5% = ~900ms over 3min), onset detection (madmom) collapses above 120bpm (11% accuracy). **MIDI ticks already live in beat domain** (tick/PPQ = beat), zero drift, no onset detection — we ask AI to compose, render audio sample-perfectly ourselves.

Converter enforces all game constraints (each logs):

| Trap | Fix |
|---|---|
| Notes off-grid | 1/12-beat quantize + report max error |
| Chords (simultaneous notes) | merge to one onset |
| No count-in | shift whole chart +N beats (audio·tempo·onsets shift together) |
| **MIDI tempo change** | **convert to rabbit/snail tiles.** Game is constant hop-multiplier so changes need tiles — forced if missing |
| **One melody part = boring** | **density boost via accompaniment** (below) |
| **Transcription glitch = stuck onsets** | 100ms+ gaps drop later tile (`--floor-ms`) |
| Gap > 2 beats | fill tile — **split evenly** (max 2-beat wait per tile) |
| Which melody track? | score pick: overlap·density·compactness (`--melody-track N` override) |

### Density Boost — Why Charts Felt Thin (2026-08-07)

Multi-song pass found it: **too few tiles.** Measured:

| | Taps/sec | 2-beat fill ratio | 800ms+ gaps |
|---|---|---|---|
| mureka_07 | **1.43** | **67%** | 177 |
| mureka_neon | 1.54 | 52% | 118 |
| 14-song avg | 2.0 | 33% | — |

**We tracked one melody part only.** When that part rests, the chart rests. mureka_07 melody = 96 onsets, filling 2/3 chart with "nothing to play", hitting filler every 841ms. Thin chart? No — **empty chart**.

ADOFAI workshop charts don't follow one part. Lead silent, tap drums. Drums missing, tap synth — tap what you hear now. So fills use **actual accompaniment onsets**, not metronome:

Layers by rhythmic prominence, earlier layers fill gaps from later ones:

```
drum backbeat (kick·snare) → bass → other parts → hihat → (real silence) filler tile
```

**Split units.** Key insight:

- **Ceiling = beats** (`--fill-above-beats`, default 1.0). Thin is music concept. Chartmakers think "gap over 1 beat, fill it", not "over 340ms". Beats make slow·fast songs feel equally full.
- **Floor = ms** (`--min-gap-ms`, default 150). Unplayable is physics. Fingers and windows don't know BPM.

Floor picked by measurement. 150ms filler-created tight spots (<150ms) matched melody's original count — doubled density without lowering minimum. 130ms pushed tight spots 3~5×  (mureka_09: 64 → 296).

Result (14 songs): **2.0 → 3.56 taps/sec**, 4,313 → 8,166 tiles, filler 1,502 → 228, removed 116 unplayable tiles, min spacing floor 17ms → 105ms.

**Sparse songs cut overlaps too.** 2-beat hops always U-turn (hard angles), pathological overlap source (see "path planning"), turning to real onsets broke them into 0.25~0.75-beat hops. mureka_07: 21 → 7 pair overlaps.

**Dense songs gained overlaps** — geometric consequence. Short hops = steep bends (0.25 beat = 135° turn). More density = more short hops = path coils. Planner can't unwind it — rhythm sets angle.

| | Median gap | Overlaps |
|---|---|---|
| mureka_09 | 271ms | 5 pairs |
| mureka_07 | 280ms | 7 pairs |
| mureka_14 | 173ms | 269 pairs |
| mureka_06 | 219ms | 372 pairs |

Original high-speed sections bunch into flowers/spirals — same phenomenon, not wrong. **Density and readability trade off.** Note for future: tighten density (`--fill-above-beats`) per-song, not planner edits.

#### Unplayable Gaps Cleanup (`--floor-ms`, default 100)

After boosting, logs showed **min gap 17ms**. Not filler-made (floor 150ms) — transcription melody already had it. 1/12-beat pairs landing in 300~375bpm sections = 17~33ms. Windows cap to 45% neighbor distance (`Judge.set_gaps`), so 17ms = ±7ms windows — both impossible, latter **confirmed miss**. Defect, not difficulty.

Final pass: drop onsets < 100ms apart (delete later tile).

**Two floors justified.** `--min-gap-ms` (150): safe-to-place minimum — conservative. `--floor-ms` (100): tolerate-if-present minimum — generous. Merge them and fast sections vanish.

**Speed tiles never drop.** Lose them and that section's speed breaks — drop adjacent instead. Protect list = **all tempo-map change points**, not just "newly inserted". Pre-existing notes overlapping them aren't on insert list; skipping them deletes them; broken "speed on tile" invariant.

Measured (mureka_14): min gap 29ms → 115ms, 120ms-under spans 104 → 13. Remaining 13 are melody + speed tile direct hits — can't drop either.

#### Two Caught-Together Bugs

1. **Fill made unplayable gaps.** Greedy 2-beat steps (`a+2, a+4, …`) left 1/12-beat after 2+1/12 gap — 172bpm = **29ms**. Switched to even split (two 1+1/12-beat pieces). Calculations also switched from beat (float) to grid units (int) — rounding could push last piece past 2-beat.
2. **Speed tiles got stuck between filler.** Speed can't move (breaks that section's speed) but filler can skip. So **insert speed tiles before density boost.** Reversed order had 35ms spans, 15 cases; reversed, min 105ms.

### Tone — "Doesn't Sound Like the Original" (2026-08-10)

Audio played fine but sounded wrong. Root: synthesis. Three things overlapped.

| | Before | After |
|---|---|---|
| Energy out-of-harmony (A6) | 2.87% | **0.000%** |
| Spectrum centroid | 10,199 Hz | **4,402 Hz** |
| 12kHz+ energy | 44.7% | **11.8%** |

**1. Naive square wave folds.** `1.0 if ph < duty else -1.0` has infinite harmonics; 24kHz+ all fold down. Folded parts aren't integer multiples so they clash as "crackle". Octave doubling (A3 0.36% → A6 2.87%). → **Band-limited wavetable** (`tools/synth.py`). Pre-calculate harmonics only below Nyquist, bake to table. Bucket by power-of-2 harmonic count, only 9 tables (mipmaps), runtime = table lookup — faster, 22sec/song.

**2. Flat envelope.** 5ms attack then 1.0 until release — organ drone regardless. → **Per-role ADSR.** Measured envelope (220Hz, 0.5sec):

| Role | 5ms | 200ms | 450ms | Feel |
|---|---|---|---|---|
| lead | 0.84 | 0.55 | 0.41 | pluck, sustain |
| bass | 0.99 | 0.82 | 0.82 | sustain |
| pluck | 0.95 | 0.31 | 0.08 | pluck, decay |
| pad | 0.42 | 0.55 | 0.31 | slow rise |

**3. Drum as white noise = hiss.** White noise: flat Hz-per-octave so top octave (12~24kHz) = half energy. Measured hat 15.2kHz, snare 11.9kHz centroid. 1-pole (6dB/oct) can't fix — cut at 11kHz, still 12.5kHz. → **3-pole (18dB/oct) bandpass**, hat 8.0kHz, snare 5.6kHz.

Harmonic ceiling doubles as tone knob — bass to 16 harmonics (soft without runtime filter) cheaper than filtering 8.8M samples.

Tuning by number, re-measurable:

```bash
python3 tools/synth.py    # spectrum centroid · peaks · folds self-check
```

### Real Audio Adoption (`--audio`) — Play Actual Song, Not Synth (2026-08-10)

Tuned tone still isn't original. MP3 → tiles-only, MIDI just places:

```bash
python3 tools/midi2song.py ~/Downloads/midis\ \(8\)/*.mid --name mureka_09 \
    --title 과부하루프 --audio ~/Downloads/과부하\ 루프.mp3
```

Last section's worry — "alignment breaks window" — half-true. **과부하 루프 measured** (6-segment cross-correlation):

| Chart follows | Global vs original | Local wander | Residual σ |
|---|---|---|---|
| raw transcription | −2.2ms | 8ms | **2.2ms** |
| dejitter-cleaned | −25.7ms | 48ms | 7.8ms |

**Raw transcription = original timebase.** Error all from dejitter (self-reported drift 92.2ms). Using raw means 501 tempo events (20ms-grid noise) every speed tile: dropping to 15ms dejitter-cap leaves 115 segments — grid (20ms) > cap (15ms) so caps don't stick.

Solution: `midilib.resample_tempos_at_tiles` — tempo boundaries **tile-only**, fit hop-wise time-preserving bpm. Boundaries=tiles → "speed on tile" invariant holds structurally, **chart wall-clock matches raw map exactly** (0ms error). Leftover chart-original error = grid snap (½ cell, ≤12.3ms at 202bpm).

Trade: speed_changes gets fine-grained noise (±7%, mureka_09 212 instances), meaningless to players — mechanical correction. Separate display: intentional changes (cleaned map) → `speed_display_beats` → `Chart.speed_display` (markers·HUD), speed itself = speed_changes (all). Measured (kick·snare vs original energy cross-corr): global −5.0ms, local σ 5.4ms, range 14ms, pass. File check 0.000002ms/tile · engine 0.058ms · autoplay smoke P·100%·σ 2.5ms.

Source map (stem MIDI ↔ original): **mureka_NN ↔ `~/Downloads/midis (NN−1)`** (01 unnumbered). Get real MP3 per-song from Mureka; currently mureka_09 only.

### Mix — "Performance Melody" ≠ "Song Star" (2026-08-10)

Even after tone-tuning, some felt off. Two causes, one is us.

**Our mistake — led with the backline.** `track_role` gave biggest volume to the chart-follow part, but two are different:

> Playable melody is **what you can tap** — too dense, it drops. Song star is **what you hear** — denser = more likely star.

Measured mureka_01: chart follows bass (268 notes) but synth lead (2,487) leads the ear. Lead classified `pad` amp 0.14 — quietest. mureka_03 (1,638) · mureka_07 (1,335) same. 

Shift: amp from **instrument name**, melody gets boost (`MELODY_BOOST` 1.35) only — players follow what they play.

**Unforced issue — transcription MIDI has holes.** Silent render ≈ source silence (below):

| Song | Source silent | Render silent |
|---|---|---|
| mureka_11 | 13.5% | 12.9% |
| mureka_03 | 10.4% | 11.0% |
| mureka_02 | 9.2% | 9.2% |
| Rest | 0~5% | 0~4% |

mureka_11 has 5-second voids (12~16sec, 148~153sec) with zero notes on all 5 tracks. Unsalvageable by us — only **real audio mode (`--audio`)** fixes it. mureka_09 already there.

### Difficulty Curve — Intro and Climax (2026-08-10)

Uniform boost flattened charts. Measured 10-sec spans:

```
mureka_01  mean 3.15 σ0.60   ▃▄▄▄▅▄▄▃▄▃▄▄▄▄▁      flat
```

**Song has structure — chart buried it.** Same song intensity: `▃▄▅▃█▆▅▅▇▆▆▃▃▃▃`. Quiet sections got force-filled, loud already maxed (can't go higher).

Resample **intensity curve**, per-section target gaps. Not invented difficulty — expose what music already has.

- **Intensity** = onset density 0.6 + concurrent-track count 0.4, 8-sec window, smoothed. Mix because onsets alone spike on drum rolls, track-count alone makes pad-sustained sections climax-biased.
- **Normalize = half rank + half minmax.** Minmax alone makes intensity-skewed songs entirely intro (mureka_14 measured 3.55 → 2.44 taps/sec). Rank alone fakes structure on truly flat songs.
- **Target gap = ms.** Thin is music (beat). Hard is physics (ms) — hands don't know BPM. 300ms (3.3 taps/sec, intro) → 150ms (6.7 taps/sec, climax).

#### Fixed Twice

**1. Ceiling-only gating.** Just "if gap > ceiling, fill" lets nobody decide density. Melody-silent sections gap seconds; any ceiling breaches, then floor floors everything — **quiet sections max-density**. Ceiling must be **target gap** to let intro be intro.

**2. Greedy converges 1.35× target.** Place greedily every target spacing: 400ms gap, 150 target, place 150 then 250 left < floor (115ms) splits = **201ms actual**. → **n-divide gap, snap nearest onset in each slot.** Absent onsets (outside 70% target) skip.

#### Result (13 songs)

| | Before | After |
|---|---|---|
| Per-section taps/sec σ | 0.53~1.03 (mostly 0.6) | **avg 0.98** |
| Climax peak | 3.9~5.1 | **4.4~6.4** |
| Intro floor | 0.9~2.3 | 0.3~2.3 |
| Full-song avg | ~3.3 | 3.38 |

Examples: `mureka_11 ▁▁▂▃▄▅▄▅▅▅▅▄▂▃▂▂▃▁` · `mureka_06 ▄▂▁▃▃▃▃▃▃▄▆▆▃▅▄`

Knobs: `CEIL_EASY_MS` (intro) · `CEIL_HARD_MS` (climax). Tighten both for overall hard, spread them for arc.

### Rabbit Isn't Tempo, It's Chart-Side (2026-08-10)

13 of 14 songs had zero rabbits, all from tempo-change transcription dejittered-flat. Real rabbit is **chart effect**, not beat.

`pick_boost_sections` applies ×2 to top-intensity zones. Speed m preserves wall-clock — **hop beats × m · rate × m** keeps wall = beats·spb/mult constant. Same tap time, planet spins faster (0.5-beat bend becomes straight). Verification gate locks this tick-to-tick.

Pick conditions all from geometry/structure: gaps ≤1 beat in section (max 2× sweep), no holds (wheels fixed 2-beat), 8+ seconds, capped 32sec (can't be half song — mureka_06 90sec). **First found "intensity window" then checked; all climaxes had violations, gave 0.** Flipped: clean sections first, pick by intensity mean. 14 songs, 24 sections result.

### Count-In·Tail·Virtual Render (2026-08-10)

- **Count-in = wall-clock**: Fixed 4 beats = 1.2sec at 203bpm (no hand-up time), 3.6sec silence at 66bpm (song seems stuck). Find int beats closest to 2.5sec by **tempo-map integrate** — per-beat bpm differs. Real fade = **4 ticks** (last octave higher), baked to audio (raw mode's dejitter-prepend tap too).
- **Tail anchor**: Melody ends, accompaniment's tail (max 11.4sec) beyond chart — "complete" mid-song. Anchor **all tracks' last note**, boost's tail buffer (max tail 11.4 → 5.4sec, rest is note sustain echo). ⚠️ Insert speed before tail — after, tail's tempo change points lose tiles (measured mureka_07 433-beat FAIL).
- **Virtual render**: 850 tiles every cursor = 20-point rounded polygon + marker = hitches (28fps measured). Skip off-screen (camera radius 1050px). Stays 30~60 tiles around cursor. 693-tile chart hit 145fps.

### Verification Two-Pass — Never Math Twice

1. **Python**: Tempo-map integral "true wall-clock" vs **file .tres parsed** recalculated hitime. Not memory midpoint — file under test catches serialize truncation, dropped fields, tile bugs (0.005ms error measured).
2. **GDScript** (`tests/verify_chart.gd`): Engine's `ChartRuntime.hit_times_ms` matches same truth. Python alone misses "understood same wrong way" — game code is final arbiter (0.004ms error).

Fixture (`make_test_midi.py`) plants all traps: 2 tempo changes (one no-note spot), chord, off-grid note, 5-beat gap, 0-beat start. Autoplay: **P · 100% · σ 2.5ms** — tempo-change charts verified live.

Precision: `.tres` numbers `%.9g` format. `%g` (6sig) truncates 2/3 ratio → 0.666667, hitime drifts long songs.

### Parser Verified vs Writer

`tools/test_midilib.py` — hand-crafted SMF bytes fed straight to parser. Self-testing (writer-output only) risks shared misunderstanding. Our writer skips running status; real AI MIDIs commonly use it (chained note-on, vel0=off, meta cancels, skip events, duplicate same-pitch on, FIFO). All tested here only.

External integration: Wikipedia MIDI sample (format 1, 6 tracks, 177 notes) through full pipeline, engine verify **0.0000ms** (products unlicensed, not archived). Real finding: multitracks start melody late (guitar 87.5sec) — converter warns >12sec intro.

---

## Precision and Sound — What 14 Real Songs Revealed

These issues only showed up after adding real songs. Fixture charts are short and geometrically exact, so all four stayed silently quiet.

### U-turns Are Poised on the Wrap Boundary (`TURN_EPS_DEG`)

A U-turn is when sweep equals exactly `0 = 360`. But that value sits on the boundary of `fposmod`. When just 0.001° of error slips in, one side gives `0.0006` (→ 0.0 beats) and the other gives `359.9994` (→ 2.0 beats) — **the same U-turn reads backwards**. `is_zero_approx`(1e-6) catches only one end.

Measured: in the same chart, Python(float64) gave 2 beats and the engine(float32) gave 0 beats — hit times **diverged by 6.5 seconds**. The angle accumulation error was 0.0006°.

Both ends count as U-turns. A 1.0° margin is 1000× bigger than float error (~0.001°) and 15× smaller than the smallest grid hop (15° = 1/12 beat) — no valid values exist in between. `ChartRuntime.TURN_EPS_DEG` and `make_charts.TURN_EPS_DEG` must be identical.

### Hit-time Accumulation Uses Double Precision

`hit_times_ms` returns `PackedFloat32Array`. If you read `out[i-1]` to add and rewrite as `out[i] = out[i-1] + ...`, it gets **rounded to float32 every tile** and that error accumulates as a random walk. At the 200-second mark, float32's step is 0.03ms, so 848 tiles gives drift of 0.03 × sqrt(848) ~ 0.85ms.

Measured: mureka_08 came in at 1.011ms, right against the cross-check tolerance of 1.5ms. Moving accumulation to a double local variable (storage stays float32) — **0.0078ms** — exactly one float32 step at that time point. Result is now independent of song length, and all 15 charts sit at 0.008~0.010ms. `run_tests.gd` locks this with a 900-tile accumulation test (reverting to the old way gives 2.53ms instant FAIL).

### Loudness Normalization, Not Peak

Peak normalization per song reads as different volume. When you mix several stems, a lucky peak alignment decides the whole gain — 6-stem compositions land at 18–20dB crest with −19 to −21dB RMS, but single-track song140 is 14dB / −15dB. Hit-sound volume tuned to song140's level, so **the same sound burst 6dB louder in a new composition**.

`make_song.loudness_normalize()` matches RMS and then a limiter clips overflow peaks (block max → lookahead min → release smooth → per-sample interpolation). ~5ms lookahead is needed so gain drops **before** the peak peaks, preserving transients. Block-to-block gain interpolation must clamp to that block's required gain — otherwise it overshoots the ceiling.

**One pass isn't enough.** Raising gain to meet the target then limiter clipping brings RMS back down — measured (after density boost) target −15.0dB but it settled at −16.1 to −18.7dB, a 3.7dB gap widened again. So we "recalculate → push harder by the shortfall → limiter again" in a loop (`passes`). We don't push indefinitely (`max_extra_db=6`) — forcing a high-crest song narrows the limiter and flattens the tone; slightly quiet is better.

Result: 14 songs at RMS **−15.7 to −15.0dB**, hit-sound headroom variance **0.7dB**, zero clipping. Songs using real audio (`--audio`) also land at −15.0dB.

| Stage | Headroom variance |
|---|---|
| Peak normalization (start) | 6.0dB |
| Loudness 1-pass | 3.7dB |
| + Limiter shortfall loop | 1.3dB |
| + Drum level tuning (mix side) | **0.7dB** |

The last step came from **mixing**, not normalization. Drum notes are overwhelming (measured mureka_03: 1150 drums vs 126 bass), eating 55–74% of energy — lowering them makes peaks less extreme, the limiter clips less, and RMS sits closer to target. **Unfixable via normalization gets cheaper by fixing the source.**

### Input Effects Can Be Toggled (M Key)

This sound has two purposes that diverge by song type. On metronome clicks, "timing gap between song click and my input sound = my error" — it's a calibration tool (A DOFAI default). But on real music, tiles sit on melody onsets by design, so **effect plays on the same sample as the melody note**.

I can't always mute it even so. Fill tiles have no melody note at all, so muting them makes those tiles silent when hit — measured across 14 songs, 8,166 tiles, **255 (3.1%)** are fills; worst case 8.2%. So default is on, toggled via M in song select, saved to `records.json`.

> This ratio moves with the pipeline. Before density boost/`--floor-ms`/hop splitting, the same songs had 4,838 tiles with 31.3% fills (one song 69%). If mute/unmute reasoning changes, remeasure the ratio — `filled_gap_tiles + inserted_speed_tiles` ÷ `melody_onsets_beats`.

I put it in song select, not play mode: binding is empty means M is a judgment key. Reserve M and you lose key binding slots for dual-hand tapping on fast sections.

---

## Smoke Test Lies

When a test blames itself instead of the game, it hides real regressions.

### Autoplay Pressed 1.5 Frames Late

Frame quantization (average +½ frame) and `parse_input_event` queuing through **next-frame delivery** (+1 frame) stack. At 145fps that's +10.35ms.

Measured exactly +10.4ms, then run headless at 32000fps and it dropped to **+0.3ms**, so frame quantization was confirmed. This delay broke some fast-song verdict: "autoplay perfect but accuracy 95.43%" false-fail happened.

Correction: when press `C_k + aD >= ht` on frame k, mean error is `(1.5-a)D`. a=0 → +10.4ms · a=1 → +3.5ms · **a=1.5 → +0.0ms** (all measured). Fast songs' corrected perfect charts all became rank P / 100.00%.

**Lookahead has an upper bound.** Correction's `delta` proportional, so a frame skip lets you press early and miss a clean tile — 5 runs in a row saturated the machine, then the same chart dropped from P/100% to **D/64.7%(43 misses)**. Single runs reproduced fine. `MAX_LOOKAHEAD_MS`(Perfect window half) caps it — **when you narrow the window, scale this down too**. Perfect ±30 → ±25 needed 15.0 → 12.0. Lookahead wider than the window destabilizes judgment itself.

Accuracy is judged **only when the harness presses exactly**. Input scatter σ is harness precision, widening if the machine stalls — measured (AV writing 400MB WAV):

| Input scatter σ | Accuracy |
|---|---|
| 2.3~2.9ms (quiet) | 100% |
| 9.0ms | 99.42% (just under 99.0 gate) |
| 12.6ms | **97.69% — FAIL** |

Perfect ±25 narrows things so even small σ drops it. At that point accuracy measures the test rig, not the game — if σ > 5ms we skip judgment and log the fact (`AUTOPLAY_JITTER_MS`). Bad σ but low accuracy = real; normal σ but low accuracy = regression.

Miss verdict also tolerates hiccup: count frames stalled 25+ms **only fail if misses exceed hiccup count**. Pinning to zero makes flaky tests whose value goes ignored — they flicker.

### Camera Waste Isn't Absolute

`waste > 3.0` mixed camera behavior WITH **the path's own shape**. mureka_06's path inherently wastes 22.5×; camera cuts it to 8.5× and still gets flagged. Widening window ±2 → ±12 improves path to 9.4 → 6.0 but planets drift 402px away — camera can't fix it.

So measure **attenuation ratio** (camera multiplier ÷ path multiplier). Baseline is **0.85**, tuned by measuring both ends:

| Scenario | Attenuation |
|---|---|
| Normal (`CAMERA_WINDOW=3`) | 0.61 · 0.66 · 0.68 · **0.77**(song140, highest) |
| Regression (no smooth, window=0) | **1.00** |

**Set baseline high and regressions hide forever.** I had it at 1.0, regression test passed silently because smoothing removed means camera path matched tile path *exactly* — attenuation 1.00. A gate criterion on the boundary isn't a gate. Flip side: don't tighten it. Smoothing's effectiveness depends on path wavelength (longer paths resist it more) — 0.75 broke song140(0.77). Sharp smoothing indicators are separate — bounce ratio and camera spike metrics.

---

## Game Shell

**Song select screen appears on startup** (`SongSelect.tscn` is the main scene).

| Control | Action |
|---|---|
| ↑↓ + Enter | Pick and start (remembers last selection) |
| Any key | Judgment — **almost every key is a judgment key, like ADOFAI.** Dual-hand tapping is needed for fast sections. R·ESC·modifiers only reserved |
| ESC | Pause during play · Return to select from results |
| R | Restart (from pause too) |

**Hit sound**: 28ms click on keypress. Gap between song beat and input sound = your error — faster feedback than on-screen judgment (ADOFAI has hitsound as default). `Main.tscn` has `HitSound.volume_db` to adjust.

**Pause sync**: `stream_paused` freezes `get_playback_position()`. Frozen clock = no time passes = observer can't issue miss. No separate save/restore. Measured: 90 frames paused, clock drift **0.0ms**, zero missed judgments (`tests/InputScene.tscn` locks this).

Song list length comes from **the last hit time in the chart**, not audio file length — test charts share a 60-second click track so audio length misleads.

Fresh clone: `sh tools/gen_all.sh` rebuilds all generated assets.

---

## License

**Source-available — not open source.** The code is public so you can read it,
not so you can use it. Reusing it in another project, redistributing it, or
using it commercially requires prior written permission. Full text in
[LICENSE](LICENSE), Korean guide in [LICENSE.ko.md](LICENSE.ko.md).
