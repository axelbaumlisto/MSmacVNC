# Frame rate and image quality as app settings

Supersedes `felt-latency.md`, which had the settings bolted on at the end and
in the wrong order: its UI task needed a defaults key that a LATER task
created, and both tasks added the same key. This is the same work, ordered so
nothing depends on code that does not exist yet.

## Context

### The problem the user reported

Compositor work in 0.3.71–0.3.76 cut server cost 3–4× and removed the long
stalls, but a real client stack shows it did **not** make the screen feel
faster:

```
                 frames/s   p50     p90     p99      max
baseline r1        5.1     142ms   287ms   1888ms   1888ms
current  r1        6.9     134ms   191ms    294ms    431ms
baseline r2        6.4     146ms   205ms    358ms    611ms
current  r2        6.6     138ms   191ms    596ms    628ms
```

Median gap unchanged at ~140 ms. Compositing is ~3 ms of that — 2% of the
budget. I optimised 2% and the other 98% is untouched.

### Where the 140 ms actually goes

Two deliberate delays, stacked:

- `MACVNC_CAPTURE_FPS_DEFAULT` is **12** → one captured frame per **83 ms**;
- `rfbScreen->deferUpdateTime` is set to the SAME interval via
  `macVNCCaptureFrameIntervalMilliseconds` → the update is then held another
  **84 ms**.

83 + 84 ≈ the 140 ms measured. The defer made sense when a frame cost 44 ms of
CPU; it costs 3 ms now, and that headroom is what this plan spends.

### What a real viewer negotiates (measured, not assumed)

I first claimed the server cannot influence compression. That was wrong.
Server log from a real libvncclient session:

```
Using tight encoding for client
Using compression level 5, image quality level 7, JPEG subsampling 0, Q86
tight : 2724 events | 11996562/272461296 (95.6% saved)
```

- The encoding in use is **Tight with JPEG**, so `tightQualityLevel` and
  `tightCompressLevel` are exactly the right knobs.
- 12.0 MB sent for 272 MB of raw pixels = **1.5 MB/s** on the wire. Nothing is
  bandwidth-bound, which independently confirms pacing is the target.
- There is no `setEncodingsHook`, but `displayHook` fires "just before a frame
  buffer update" (`rfb.h:307-308`) and the server owns those fields by then.

So both knobs the user asked for are reachable, and the profile must be applied
by the SERVER on top of the client's request - otherwise the setting would be
invisible, because iOS viewers send their own levels. "Follow the viewer" is
offered as an explicit choice rather than as hidden behaviour.

### Non-goals

- **Server-side scaling.** Changes what the user sees; a product decision, not
  a tuning knob.
- **Choosing the encoding for the client.** The server may only pick among what
  the client advertised, and libvncserver discards part of that list, so
  forcing an encoding risks breaking viewers. Levels only.
- **Adaptive rate / bandwidth estimation.** No evidence a fixed rate is the
  problem; a control loop before measurement is guessing.
- **Live application of settings.** The Preferences window already states
  "Changes take effect after restarting macVNC" (`MacVNCPreferences.m:356`).
  These two follow that existing contract.

### Measurement caveat to respect throughout

The measuring client runs on the SAME Mac as the server, so its decode competes
for CPU and the network path is not real. Valid for A/B (both sides measured
identically), invalid as "what the iPad sees". The real device is the final
judge.


## Measured results: what the ideal settings actually are

Everything below is measured, and three earlier attempts at this measurement
were thrown away because they were invalid. Recording that, because the traps
are the reason to trust the final numbers:

1. The probe saved the framebuffer after the first "update finished", which can
   be an empty update - producing PURE BLACK images that an entire quality
   sweep was then computed from. The tool now waits for the region's worth of
   pixels and prints a content signature, so an empty capture cannot pass.
2. The regions were picked by eye at (0,0), which is a solid black area of this
   desktop. Regions are now chosen by measurement.
3. Comparing codec settings against the LIVE desktop was meaningless: over the
   ~60 s a sweep takes, 10-40% of every candidate region repainted, so the
   "JPEG artefacts" were mostly content changes. Codec fidelity is now measured
   against a static image served by a purpose-built libvncserver instance
   (`/tmp/qserver.c`), which removes the desktop from the experiment.

### Codec fidelity and size, static UI+photo image (1600x600)

| setting | wire KB | vs lossless | PSNR text | PSNR photo | max error |
|---|---|---|---|---|---|
| lossless (JPEG off), compress 1-9 | 305 | 1.00x | perfect | perfect | 0 |
| lossless, compress 0 | 1315 | 4.31x | perfect | perfect | 0 |
| JPEG quality 9 | 748 | **2.45x** | 53.0 dB | 56.2 dB | 4 |
| JPEG quality 7 | 261 | 0.86x | 35.7 dB | 39.1 dB | 52 |
| JPEG quality 5 | 191 | 0.63x | 31.5 dB | 35.5 dB | 85 |
| JPEG quality 2 | 124 | 0.42x | 28.2 dB | 31.3 dB | 90 |
| JPEG quality 0 | 90 | 0.29x | 25.4 dB | 28.1 dB | 139 |

Two conclusions that change the design:

- **Quality 9 must never be offered.** It costs 2.45x MORE than lossless and is
  still lossy. "Maximum quality" means JPEG OFF, not quality 9.
- **The compression knob is inert and must not be exposed.** Levels 1 through 9
  produce byte-identical output (305435 bytes every time, identical CPU). Only
  level 0 differs, by being 4.3x larger for the same pixels. A setting whose
  only working value is "not 0" is not a setting.

### The same profiles on the LIVE desktop, 15 s streaming

| profile | MB/s | server CPU-s | fps | mean gap | max gap |
|---|---|---|---|---|---|
| lossless | 9.4 | 7.29 | 6.0 | 169 ms | 221 ms |
| quality 7 | 2.1 | 3.42 | 8.5 | 119 ms | 187 ms |
| quality 5 | 1.7 | 3.26 | 7.9 | 127 ms | 200 ms |
| quality 0 | 0.9 | 3.38 | 8.5 | 118 ms | 163 ms |

Lossless wins on a static UI image and LOSES badly on a real desktop: 4.4x the
bytes, 2.1x the CPU, and it costs frames. Real screens contain photographs,
gradients and video, which is exactly what JPEG is for. So "maximum quality"
belongs in the menu as an honest option, not as the default.

### Pacing sweep: capture rate x defer, quality 7, two displays

| capture | defer | CPU-s | fps | mean | p90 | p99 | max |
|---|---|---|---|---|---|---|---|
| 12 (today) | 84 (today) | 3.37 | 8.1 | 125 ms | 155 ms | 173 ms | 174 ms |
| 12 | 20 | 4.09 | 12.1 | 83 ms | 93 ms | 113 ms | 322 ms |
| 12 | 10 | 4.47 | 24.4 | 41 ms | 58 ms | 67 ms | **86 ms** |
| 12 | 0 | 8.35 | 13.0 | 77 ms | 141 ms | 1395 ms | 2142 ms |
| 30 | 84 | 5.18 | 7.3 | 139 ms | 186 ms | 352 ms | 387 ms |
| 30 | 20 | 6.18 | 21.3 | 47 ms | 59 ms | 106 ms | 293 ms |
| 30 | 10 | 5.99 | 30.9 | 33 ms | 42 ms | 76 ms | 112 ms |
| 30 | 0 | 15.69 | 61.6 | 16 ms | 32 ms | 104 ms | 358 ms |
| 60 | 84 | 4.85 | 5.5 | 185 ms | 266 ms | 2114 ms | 2114 ms |
| 60 | 20 | 5.55 | 16.2 | 62 ms | 65 ms | 549 ms | 919 ms |
| 60 | 10 | 6.70 | 30.5 | 33 ms | 45 ms | 114 ms | 445 ms |
| 60 | 0 | 14.36 | 65.9 | 15 ms | 26 ms | 97 ms | 749 ms |

- **The defer, not the capture rate, is what was crippling this.** Dropping it
  from 84 ms to 10 ms at the CURRENT 12 FPS triples the delivered frame rate
  (8.1 -> 24.4) and halves the worst case (174 -> 86 ms), for 33% more CPU.
- **Defer 0 is a trap and must not be offered.** Frame rate looks spectacular
  and the tail explodes: p99 of 1.4 s and a 2.1 s stall at 12 FPS, with CPU
  doubling. Unbatched marking thrashes the update threads.
- **60 FPS buys nothing over 30** - the same ~30 fps delivered, worse tails.
- Two displays each mark independently, so 12 FPS capture can deliver ~24
  updates/s. That is why 12/10 already feels smooth.

### Combined sweep: best pacing x profile

| capture/defer | profile | MB/s | CPU-s | fps | mean | p99 | max |
|---|---|---|---|---|---|---|---|
| 30/10 | lossless | 5.5 | 5.96 | 4.0 | 256 ms | 2086 ms | 2086 ms |
| 30/10 | quality 7 | 6.0 | 6.52 | 26.9 | 37 ms | 158 ms | 353 ms |
| 30/10 | quality 5 | 3.9 | 5.55 | **33.4** | **30 ms** | **53 ms** | 128 ms |
| 30/10 | quality 2 | 2.9 | 5.71 | 31.3 | 32 ms | 68 ms | 131 ms |
| 12/10 | lossless | 14.3 | 9.66 | 12.3 | 82 ms | 288 ms | 310 ms |
| 12/10 | quality 7 | 3.3 | 4.15 | 17.8 | 56 ms | 100 ms | 105 ms |
| 12/10 | quality 5 | 2.4 | 3.32 | 24.1 | 42 ms | 78 ms | **84 ms** |
| 12/10 | quality 2 | 1.2 | 3.18 | 20.6 | 49 ms | 82 ms | 195 ms |

### The settings this measurement argues for

- **Default: capture 30 FPS, defer 10 ms, image quality 5.** Measured 33.4 fps,
  mean gap 30 ms, p99 53 ms, 3.9 MB/s, 5.55 CPU-s per 15 s. That is 4x the
  delivered frame rate and 4x lower latency than today, for CPU comparable to
  the PRE-optimisation server.
- **Quality 5 beats quality 7 on every axis here** - more frames, lower
  latency, 35% fewer bytes - because fewer bytes means less time in encode and
  transfer. Fidelity cost: 31.5 dB vs 35.7 dB on text.
- **Battery/slow-link option: 12 FPS, defer 10 ms, quality 5** - 24 fps, mean
  42 ms, best worst case of the whole matrix (84 ms), 2.4 MB/s, 3.32 CPU-s,
  which is CHEAPER than today's 3.37 while delivering 3x the frames.
- **Offer "Maximum quality (JPEG off)" honestly**, with its measured cost: it
  drops to 4-12 fps and multiplies traffic. Right for reading a static page,
  wrong as a default.
- **Do not expose compression level, and do not offer quality 9 or defer 0.**

The defer therefore stops being derived from the capture rate and becomes a
fixed 10 ms coalescing window, as Task 2 already proposed - now with numbers.

## Approach

1. Build the instrument first — nothing else can be accepted without it.
2. Remove the pointless half of the delay (defer), which costs nothing.
3. Add both settings end to end (keys → parse → startup) BEFORE anything reads
   them, so no task depends on unwritten code.
4. Only then change the default rate, so a user on a slow link or a battery can
   already turn it down.
5. Add the image-quality profile behind the same setting mechanism.
6. Surface both in Preferences.
7. Re-measure and stop when pacing is no longer what dominates.

## Tasks

### Task 1: Felt-latency harness in the repo
**Files:** `tests/feel_client.c` (new), `tests/measure_felt_latency.sh` (new),
`CMakeLists.txt`
**Acceptance:** one command prints frames/s, p50/p90/p99/max gap and the
server's CPU-seconds over the same window; two runs of the same build agree
within ~15%.
**Verify:** `bash tests/measure_felt_latency.sh 20`
**Steps:**
1. Bring `/tmp/feel.c` in as `tests/feel_client.c`: it counts COMPLETED
   framebuffer updates (`FinishedFrameBufferUpdate`), not rectangles — the
   per-rect version reported 171/s for a screen that visibly changed ~6 times
   a second.
2. Add a build target with `EXCLUDE_FROM_ALL`, like `bench_composite`, linking
   `libvncclient`. It is an instrument, not a test: it needs a running server.
3. Write the script: run the client N seconds, sample the server's CPU-seconds
   across the same window, print one line.
4. Put today's numbers in the script header as the reference point.

### Task 2: Stop deferring a whole frame interval
**Files:** `src/CaptureRate.h`, `src/CaptureRate.c`, `src/mac.m`,
`tests/test_capture_rate.c`
**Depends:** Task 1
**Acceptance:** p50 gap drops by roughly the defer time (140 ms → expect
60–90 ms) with no CPU increase beyond noise and no p99 regression.
**Verify:** `ctest -R capture_rate`, then `bash tests/measure_felt_latency.sh 20`
**Steps:**
1. Add `macVNCFramebufferDeferMilliseconds(framesPerSecond)` to the existing
   module (which already has `test_capture_rate`): the defer is a SEPARATE
   decision and must stop being derived from the capture interval.
2. Return a small coalescing window (start at 10 ms), clamped to never exceed
   the capture interval — at 60 FPS the interval is 17 ms. Its only job is to
   batch one captured frame's tiles into one update, which the compositor
   already does in a single `rfbMarkRegionAsModified`.
3. Extend `test_capture_rate`: the 10 ms case, the clamp at 60 FPS, and the
   invalid-FPS case returning 0 like its sibling.
4. Mutation-test with `tests/mutate.sh` (clamp removed, 0 returned for valid
   input).
5. Use it in `mac.m`, keeping the log line that reports both values.
6. Measure. If p99 degrades from more, smaller updates, record the number and
   try 20 ms before drawing a conclusion.

### Task 3: Both settings, end to end, no UI yet
**Files:** `src/MacVNCDefaultsKeys.h`, `src/MacVNCDefaultsKeys.m`,
`src/MacVNCImageProfile.h` (new), `src/MacVNCImageProfile.c` (new),
`src/MacVNCStartupConfig.h`, `src/MacVNCStartupConfig.m`,
`tests/test_defaults.m`, `tests/test_startup_config.m`,
`tests/test_image_profile.c` (new)
**Depends:** Task 2
**Acceptance:** `defaults write net.christianbeier.macVNC captureFPS 15` and
`… imageProfile sharp` are both honoured; invalid values fall back to the
default WITH a log line and never prevent start; `MACVNC_CAPTURE_FPS` still
wins over the stored setting.
**Verify:** `ctest -R 'defaults|startup_config|image_profile'`
**Steps:**
1. Add `MacVNCKeyCaptureFPS` (number) and `MacVNCKeyImageProfile` (name) with
   defaults registered in `macVNCAllDefaultsKeys()` — that is what makes
   `test_defaults`' set-equality check cover them automatically.
2. New pure `MacVNCImageProfile`: name → `{quality, compress, followViewer}`.
   `sharp` = 9/1, `balanced` = 7/5 (today's measured behaviour), `slowLink` =
   4/9, `viewer` = leave both fields alone. Unknown or empty → `balanced`,
   never an undefined level.
3. Read both in `MacVNCStartupConfig`, reusing `macVNCParseCaptureFPS` for the
   env override AND the stored setting so the validation rule exists once, with
   env at higher precedence (it is the debugging seam).
4. Extend `test_startup_config`: default, valid setting, invalid setting, env
   beating the setting — for the rate; and default/valid/unknown for the
   profile.
5. Mutation-test the profile mapping and the fallback.

### Task 4: Raise the default capture rate to 30 FPS
**Files:** `src/CaptureRate.h`, `tests/test_capture_rate.c`
**Depends:** Task 3
**Acceptance:** p50 gap approaches the new interval (~33 ms) and frames/s
roughly doubles, while CPU-seconds stay at or below the PRE-optimisation
baseline (10.6 s per 30 s window, measured on `be4c83e`) — spend the headroom
that was earned, and no more.
**Verify:** `bash tests/measure_felt_latency.sh 20` single- and two-display,
then `ctest`
**Steps:**
1. Change `MACVNC_CAPTURE_FPS_DEFAULT` 12 → 30. Min/max already allow it and
   the parser is already tested; the setting from Task 3 is the escape hatch.
2. Measure one display and two displays: two displays double the capture work
   and that is the case that has to stay affordable.
3. If two displays exceed the budget, record the number and lower the DEFAULT
   deliberately (e.g. 20) rather than quietly shipping something that costs
   more than the version we started from.
4. Re-verify the first-frame path: `test_first_frame_wait`, plus a cold connect
   showing no placeholder.

### Task 5: Apply the image profile per frame
**Files:** `src/mac.m`, `src/ARCHITECTURE.md`
**Depends:** Task 3
**Acceptance:** each profile visibly changes `Transmit/RawEquiv` in the
server's per-client statistics; the applied profile is logged ONCE per client;
`viewer` leaves the client's own levels untouched.
**Verify:** one 8-second run per profile, comparing the statistics block
**Steps:**
1. Install a `displayHook` that sets `cl->tightQualityLevel` and
   `cl->tightCompressLevel` from the resolved profile before each update,
   unless the profile is `viewer`.
2. Comment WHY this overrides the viewer's request: without it the setting
   would do nothing for viewers that send their own levels, which is most of
   them. `viewer` exists for people who disagree.
3. Log once per client, not per frame (a per-frame log at 30 FPS is a
   self-inflicted performance problem).
4. Measure bytes/s and CPU per profile and put the table in this plan, so the
   shipped default is chosen from data.
5. Document the hook in `ARCHITECTURE.md` — including that `displayHook` was
   deleted in `28b7b62` for having no purpose and now has one.

### Task 6: Both settings in the Preferences window
**Files:** `src/MacVNCPreferences.m`, `README.md`
**Depends:** Task 4, Task 5
**Acceptance:** two popups showing the stored choice on reopen; changing them
and restarting produces the new values in the log; nothing else in the window
shifts or breaks.
**Verify:** open Preferences, change both, restart, read the log line
**Steps:**
1. Follow the `listenPopup` pattern already in this file — label plus
   `NSPopUpButton`, same window, no new controller.
2. **Frame rate:** `Battery saver (8 fps)`, `Balanced (15 fps)`,
   **`Smooth (30 fps)` — default**, `Maximum (60 fps)`.
3. **Image quality:** `Sharp — more data`, **`Balanced` — default**,
   `Slow link — less data`, `Follow the viewer`.
4. Persist as number and name respectively, so a hand-edited `defaults write`
   stays readable and matches Task 3's parser.
5. Rely on the window's existing "Changes take effect after restarting macVNC"
   line rather than implying live application.
6. Document both settings in `README.md` with their measured cost.

### Task 7: Re-measure, then stop or escalate
**Files:** `.pi/plans/quality-and-frame-rate-settings.md`, `RELEASE_NOTES.md`
**Depends:** Task 6
**Acceptance:** a before/after table (felt latency + CPU + bytes) and an
explicit statement of what dominates the remaining gap.
**Steps:**
1. Alternating A/B against `be4c83e`, 0.3.76 and the new build, as in the
   earlier sessions — never sequential single runs.
2. Attribute what is left: capture interval vs defer vs encode+send, using the
   per-client statistics for the last term.
3. If pacing no longer dominates, STOP and write down what does. The next
   lever (resolution, encoding choice) is a product decision and belongs to its
   own plan.
4. Ask the user to confirm on the real iPad, including which image profile
   reads best for code — the local harness cannot answer that.

## Verification

- [ ] `ctest --test-dir build-release-arm64` green (33 targets today, plus the
      new ones)
- [ ] every new assertion mutation-tested with `tests/mutate.sh`
- [ ] analyzer clean on every touched file; `leaks` reports 0
- [ ] `packaging/check_architecture.sh` passes with the new module documented
- [ ] p50 gap at least halved versus 0.3.76, p99 no worse
- [ ] CPU-seconds no higher than the pre-optimisation baseline (`be4c83e`)
- [ ] cold connect still shows no placeholder checkerboard
- [ ] both settings survive a restart and appear in the log
- [ ] user confirms on the real device
