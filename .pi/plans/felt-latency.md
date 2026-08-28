# Felt latency: make the picture arrive sooner, not just cheaper

## Context

The compositor work (0.3.71–0.3.76) cut server cost 3–4× and killed the long
stalls, but measurement with a real client stack showed it did **not** make the
remote screen feel faster:

```
                 frames/s   p50     p90     p99      max
baseline r1        5.1     142ms   287ms   1888ms   1888ms
current  r1        6.9     134ms   191ms    294ms    431ms
baseline r2        6.4     146ms   205ms    358ms    611ms
current  r2        6.6     138ms   191ms    596ms    628ms
```

Median gap between frames is unchanged at ~140 ms. Compositing is now ~3 ms of
that budget — 2%. So the remaining 98% is elsewhere, and the code already tells
us where:

- `MACVNC_CAPTURE_FPS_DEFAULT` is **12**, i.e. one captured frame per **83 ms**;
- `rfbScreen->deferUpdateTime` is set to the SAME interval
  (`macVNCCaptureFrameIntervalMilliseconds`), i.e. the server then holds the
  update for another **84 ms** before sending it.

Two deliberate delays stacked on top of each other. 83 + 84 ≈ the 140 ms we
measure. Nothing is bandwidth-bound and nothing is CPU-bound: this is pacing.

The defer was reasonable when a frame cost 44 ms of CPU to composite. It costs
3 ms now, which is exactly the headroom this plan spends.

### Non-goals

- Encoding/quality tuning. Tight/ZRLE parameters are chosen by the CLIENT via
  pseudo-encodings; the server cannot force them. Out of scope.
- Server-side scaling. It changes what the user sees and needs its own UI
  decision.
- Adaptive/dynamic frame rates. No evidence yet that a fixed rate is the
  problem; adding a control loop before measuring would be guessing.

### Measurement caveat to respect throughout

`/tmp/feel` runs the client on the SAME Mac as the server, so client decode
competes with the server for CPU, and the network path is not real. It is
still the right instrument for A/B (both sides measured identically), but
absolute numbers must not be quoted as "what the iPad sees". Final acceptance
needs one confirmation from the user's real device.

## Approach

Spend the CPU headroom the compositor work created, in the order of measured
impact, verifying each step before taking the next:

1. Stop deferring a whole frame interval (pure latency, no extra work).
2. Raise the capture rate now that a frame is cheap (latency + smoothness,
   costs CPU).
3. Make the rate a real setting rather than an env var, so a slow link or a
   battery-conscious user can turn it down.
4. Re-measure the breakdown and stop when the next lever is no longer pacing.

Each step is independently reversible and independently measurable.

## Tasks

### Task 1: Baseline harness that both sides can trust
**Files:** `tests/measure_felt_latency.sh` (new), `tests/feel_client.c` (new,
from `/tmp/feel.c`)
**Acceptance:** one command produces frames/s and p50/p90/p99/max gap plus the
server's CPU-seconds over the same window; two consecutive runs of the same
build agree within ~15%.
**Verify:** `bash tests/measure_felt_latency.sh 20`
**Steps:**
1. Move `/tmp/feel.c` into the repo as `tests/feel_client.c`; it is the only
   instrument that measures completed framebuffer updates rather than rects.
2. Add a build target (EXCLUDE_FROM_ALL, like `bench_composite`) linking
   `libvncclient`.
3. Write `tests/measure_felt_latency.sh`: run the client for N seconds against
   a running server, sample the server's CPU-seconds across the same window,
   print one line.
4. Record the current numbers in the script's header as the reference point.

### Task 2: Stop deferring a full frame interval
**Files:** `src/CaptureRate.h`, `src/CaptureRate.c`, `src/mac.m`,
`tests/test_capture_rate.c`
**Depends:** Task 1
**Acceptance:** p50 gap drops by roughly the defer time (~80 ms → expect
~60–90 ms p50) with no increase in CPU-seconds beyond noise, and no increase in
p99.
**Verify:** `ctest -R capture_rate` then `bash tests/measure_felt_latency.sh 20`
**Steps:**
1. Add `macVNCFramebufferDeferMilliseconds(framesPerSecond)` next to the
   existing interval helper: the defer is a SEPARATE decision from the capture
   interval and must stop being derived from it.
2. Return a small fixed coalescing window (start at 10 ms) clamped to never
   exceed the capture interval — its only job is to batch the tiles of one
   captured frame into one update, which the compositor already does in a
   single `rfbMarkRegionAsModified` call.
3. Unit-test the new function including the clamp at high FPS (at 60 FPS the
   interval is 17 ms, so the defer must not exceed it).
4. Use it in `mac.m`; keep the existing log line so the chosen values remain
   visible.
5. Measure. If p99/max degrade (more, smaller updates), record the number and
   try 20 ms before concluding.

### Task 3: Raise the default capture rate to 30 FPS
**Files:** `src/CaptureRate.h`, `tests/test_capture_rate.c`,
`RELEASE_NOTES.md`
**Depends:** Task 2
**Acceptance:** p50 gap approaches the new capture interval (~33 ms) and
frames/s roughly doubles; CPU-seconds stay at or below the PRE-optimisation
baseline (10.6 s per 30 s window measured on `be4c83e`) — i.e. we spend the
headroom we earned and no more.
**Verify:** `ctest -R capture_rate` then `bash tests/measure_felt_latency.sh 20`
plus a two-display CPU check
**Steps:**
1. Change `MACVNC_CAPTURE_FPS_DEFAULT` from 12 to 30; the min/max already allow
   it and the parser is already tested.
2. Measure single-display and two-display CPU-seconds; two displays double the
   capture work, and that is the case that must stay affordable.
3. If two-display CPU exceeds the baseline budget, keep 30 for one display and
   record the two-display number in the plan rather than silently lowering it.
4. Re-verify the first-frame path: `test_first_frame_wait` and a cold connect
   must still show no placeholder.

### Task 4: Make the capture rate a setting, not an env var
**Files:** `src/MacVNCDefaultsKeys.h`, `src/MacVNCDefaultsKeys.m`,
`src/MacVNCStartupConfig.m`, `tests/test_defaults.m`,
`tests/test_startup_config.m`
**Depends:** Task 3
**Acceptance:** `defaults write net.christianbeier.macVNC captureFPS 15` is
honoured; an invalid value falls back to the default with a log line and does
not prevent start; `MACVNC_CAPTURE_FPS` still wins for debugging.
**Verify:** `ctest -R 'defaults|startup_config'`
**Steps:**
1. Add `MacVNCKeyCaptureFPS` with the default registered alongside the others,
   so `test_defaults`' set-equality check covers it automatically.
2. Read it in `MacVNCStartupConfig`, keeping the env override as the higher
   precedence (it is the debugging seam), and reuse `macVNCParseCaptureFPS` for
   both so the validation rule exists once.
3. Extend `test_startup_config` for: default, valid setting, invalid setting,
   env override beating the setting.
4. Document the setting in `README.md` next to the other defaults.

### Task 5: Re-measure the breakdown and decide whether to continue
**Files:** `.pi/plans/felt-latency.md` (this file), `RELEASE_NOTES.md`
**Depends:** Task 4
**Acceptance:** a table of before/after felt-latency and CPU numbers, plus an
explicit statement of what now dominates the remaining gap.
**Steps:**
1. Run the harness against `be4c83e`, against 0.3.76, and against the new
   build, alternating, as in the earlier A/B sessions.
2. Instrument one run to attribute the remaining gap: capture interval vs
   defer vs encode+send (the server's per-client statistics printed on
   disconnect give bytes and compression ratio).
3. If pacing no longer dominates, STOP and write down what does — the next
   lever (encoding, resolution) belongs to a different plan and needs a
   product decision, not a tuning change.
4. Ask the user to confirm on the real iPad; the local harness cannot answer
   that question.

## Verification

- [ ] `ctest --test-dir build-release-arm64` fully green (currently 33 targets)
- [ ] analyzer clean on every touched file; `leaks` reports 0
- [ ] `packaging/check_architecture.sh` passes, with the new module documented
- [ ] mutation-test every new assertion with `tests/mutate.sh`
- [ ] measured p50 gap at least halved versus 0.3.76, with p99 no worse
- [ ] CPU-seconds no higher than the pre-optimisation baseline (`be4c83e`)
- [ ] cold connect still shows no placeholder checkerboard
- [ ] user confirms on the real device
