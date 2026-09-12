# A stream that stopped delivering must not look like a screen that stopped changing

## What was actually wrong

11.09.2026: macVNC served a viewer a frame from **10.09 02:40** for ~42 hours.
No error, no modal, no log line — the listener, the auth and the framebuffer
path all worked. Measured with an RFB probe:

- three full-framebuffer requests in a row returned the **same** md5
  (`6af5aa5db7`), while the real screen was changing;
- an incremental request got **nothing for 20 s** (viewer sees a still image);
- process CPU grew 0.18 s per 40 s — no frames were arriving at all;
- framebuffer was `1472x956` = ONE display in the layout, while the desk had
  two (`id=3` 3840x2160 main, `id=1` 1710x1112 built-in), both online/active;
- `2026-09-10 02:38:32 WindowServer (SkyLight) WSDisplayStreamGetDisplay:
  display = NULL, displayStream->displayID = 1` — the desk changed shape two
  minutes before the last delivered frame. The server had started at 00:39,
  when the built-in was alone and its logical size was 1472x956.

On every new connection macVNC dutifully built a fresh `SCStream` for the
stale `displayID`/geometry (confirmed in the ScreenCaptureKit log:
`initWithFilter` → `addStreamOutput` → `startCaptureWithCompletionHandler`,
no error) and that stream delivered nothing either. A restart of the app fixed
it instantly: `fb 5552x2715`, changing md5s, incremental in 0.0 s.

## What this refutes

`.pi/plans/display-reconfiguration.md` closed "react to reconfiguration while
running" as out of scope, with one load-bearing claim:

> The unplug case never reaches it anyway. `reportCaptureFailure` already stops
> the server and shows a modal within milliseconds of a monitor going away.

Measured false. A desk change can leave `SCStream` **silent rather than
failed**: `didStopWithError` never fires, so nothing on the failure path runs.
That is the gap this plan closes. Its other three objections stand and shape
the design below — no waking probe, no server restart, no reconfiguration
subscription.

## The invariant

Today: *captures run if and only if a client is connected*
(`reconcileCaptureState`). Extend it by what the viewer actually needs:

> While a client is connected, captures must **deliver frames**. Silence is a
> failure to act on, not a screen that happens to be still.

Safe because a still screen is not silence... except that this founding
assumption was measured FALSE on 2026-09-12, one commit after this plan
shipped: a two-display desk where the user worked on only one panel produced
NINE re-arms in about two minutes on the IDLE panel's stale stamp alone,
while the active display's viewer received a real, working session the whole
time (session stats: 3144 ZRLE events, 1547 FramebufferUpdate requests). A
display with nothing to redraw does NOT get a new sample buffer from
ScreenCaptureKit - "silence" and "a still picture" are the same event for an
IDLE display, whatever they are for a genuinely dead stream.

FIX-C's correction: "silence" must be judged per LAYOUT, not per display -
the watchdog may only act when NO display in the layout has produced a frame
recently (the MAXIMUM per-display stamp, not the minimum - see
`freshestFrameStamp()` in `src/mac.m`). This deliberately gives up catching
"one of several displays died while the rest keep working"; that is a
different, narrower failure this mechanism no longer detects, and adding it
back would need its own, more conservative mechanism (a much longer
per-display threshold, re-arming only the affected display) - left undone on
purpose, not forgotten. The measured incident this plan was written for (the
WHOLE desk going silent, `didStopWithError` never firing) is still caught:
when every display stops, the maximum is exactly as stale as the minimum was.

## The change

Four small pieces, one responsibility each. Nothing new subscribes to
CoreGraphics notifications; nothing restarts the server; no new thread.

### 1. `src/CaptureLiveness.{h,c}` — pure decision (new, tested)

```c
typedef struct {            /* limits, injected — not constants in glue */
    uint64_t graceNs;       /* after a start, before silence counts   */
    uint64_t silenceNs;     /* no frame for this long = not alive     */
    uint64_t cooldownNs;    /* minimum spacing between re-arms        */
    unsigned maxRearms;     /* then stop lying and report the failure */
} MacVNCCaptureLivenessLimits;

typedef struct {
    bool     capturesRunning;
    bool     clientsConnected;
    uint64_t nowNs, lastFrameNs, capturesStartedNs, lastRearmNs;
    unsigned rearmsSinceFrame;
} MacVNCCaptureLivenessInput;

typedef enum { MacVNCCaptureAlive, MacVNCCaptureRearm, MacVNCCaptureGiveUp }
    MacVNCCaptureLivenessVerdict;

MacVNCCaptureLivenessVerdict macVNCResolveCaptureLiveness(
    const MacVNCCaptureLivenessInput *, const MacVNCCaptureLivenessLimits *);
```

Rules, in order — all six are test rows:
1. no client, or captures not running → `Alive` (do nothing; this is what kept
   the old plan's 3am wake-loop out of the design);
2. no frame yet and `now - capturesStartedNs < graceNs` → `Alive`;
3. `now - max(lastFrameNs, capturesStartedNs) < silenceNs` → `Alive`;
4. `now - lastRearmNs < cooldownNs` → `Alive` (one re-arm in flight per window);
5. `rearmsSinceFrame >= maxRearms` → `GiveUp`;
6. otherwise → `Rearm`.

Shipped limits: grace 6 s (first-frame budget is 5 s), silence 4 s (= 120
missed frames at 30 fps), cooldown 10 s, maxRearms 3 → a dead stream is either
alive again or honestly reported inside ~35 s.

### 2. One write point for "a frame arrived" (DRY)

`compositeCapturedFrame()` (`src/mac.m:499`) is the only place a frame becomes
pixels, so it is the only place that stamps time:
`atomic_store(&gLastFrameNs[displayIndex], macVNCMonotonicNow())`.
Per display, indexed by layout position; the watchdog reads the **minimum**
over the layout, so one dead panel of two is caught, not averaged away.

### 3. The watchdog — glue in `mac.m`

One 1 Hz `dispatch_source` timer on the **existing** `gCaptureStopQueue`
(no second queue), armed and disarmed by `reconcileCaptureState()` alongside
the captures it watches. Body: take a snapshot under `captureControlMutex`,
release it, call the pure resolver, then act — the keep-warm timer's exact
shape, for the same reason (a re-arm waits on in-flight SCK work).

- `Rearm` → `rearmCaptures()`, then `++rearmsSinceFrame`, `lastRearmNs = now`.
- `GiveUp` → `reportCaptureFailure(false)`, the path that already exists:
  `macVNCResolveCaptureFailure` decides keep-serving vs stop, the curtain comes
  down, the menu and the modal already say what happened.

### 4. `rearmCaptures()` — the only new operation

1. `macVNCCaptureSessionStopAndWait()`.
2. Re-read the desk **without waking it**: `readAttachedDisplays()` split into
   `collectDisplayInputs(wake:)` + the waiting loop, so re-arm reuses the
   reading and skips `macVNCWakeDisplays()` (the old plan's second objection).
3. `macVNCDisplayLayoutsEqual(old,new)` — new pure function in
   `DisplayLayout.c`, next to the builder that owns that struct.
4. Equal → `macVNCCaptureSessionBuild(&displayLayout, fps, ...)` +
   `macVNCCaptureSessionStart()`. Same two calls `ScreenInit` uses. Done.
5. Different → swap the canvas in place, in this order:
   `macVNCCompositorSetScreen(NULL)` (returns only when no composite is in
   flight) → allocate new canvas → `rfbNewFramebuffer(rfbScreen, buf, w, h,
   8,3,4)` (viewers already announce NewFBSize/ExtDesktopSize — verified in the
   TigerVNC handshake log) → `macVNCInputSetContext(rfbScreen, &displayLayout)`
   (**mandatory**: without it the pointer maps to the old desk) →
   `macVNCCompositorSetScreen(rfbScreen)` → free the old canvas → Build+Start.
6. Any failure → listener untouched, `reportCaptureFailure(false)`. The server
   never takes itself down over this; the old plan's "restart has no safe
   failure branch" objection is answered by not restarting the server.

### 5. Logs that survive (separate, tiny, and why we were blind)

`macVNC`'s stderr is `/dev/null` when launched from Finder — 29 KB of `rfbLog`
was thrown away during this incident. Install a log sink (LibVNCServer's
`rfbLog`/`rfbErr` function pointers) writing to
`~/Library/Logs/macVNC/macvnc.log`, size-capped with one rotation. No
LaunchAgent required, works however the app is started.

## SOLID / DRY / KISS

- **SRP** — decide (`CaptureLiveness`), execute (`rearmCaptures`), observe
  (timestamp in the one composite callback), read hardware (`collectDisplayInputs`):
  four separate things that used to be one missing thing.
- **OCP** — limits are a parameter, so the policy changes without touching the
  executor; tests pin the shipped values.
- **DIP** — the resolver knows neither ScreenCaptureKit nor LibVNCServer; time
  enters through the existing `macVNCMonotonicNow()` seam.
- **DRY** — one frame-arrival stamp; one capture start pair
  (`Build`+`Start`); one timer queue; one failure path (`reportCaptureFailure`);
  layout comparison lives with layout construction; display reading shared with
  startup.
- **KISS** — 1 Hz timer, three verdicts, four limits. No reconfiguration
  callback, no server restart, no extra thread, no new IPC.

## Tests

| test | asserts |
|---|---|
| `tests/test_capture_liveness.c` (new ctest `capture_liveness`) | the six rules; recovery resets `rearmsSinceFrame`; cooldown blocks a second re-arm; `GiveUp` after the cap; idle server is always `Alive` |
| `tests/test_display_layout.c` (extend) | `macVNCDisplayLayoutsEqual`: identical, reordered, one display resized, count differs, empty |
| `MACVNC_ENABLE_TEST_HOOKS` | add `gCaptureRearmCount` + a limits override, so an e2e run can force silence in seconds |
| `tests/manual/desk-change.md` | the RFB probe procedure used above: connect, change the desk, assert incremental frames resume and `fb` size follows |

## Staging

1. **S1** timestamp + `CaptureLiveness` + watchdog, `Rearm` = stop/Build/Start
   with the same layout. Catches a silently dead stream.
2. **S2** `macVNCDisplayLayoutsEqual` + non-waking re-read + canvas swap with
   `rfbNewFramebuffer` + input context. Catches this incident.
3. **S3** log sink.
4. **S4** (was optional; shipped as part of FIX-E) pin `displayNumber` by
   display ID, not list index. Stopped being optional the moment FIX-D made
   re-selection happen LIVE, mid-session, on a connected client's desk - a
   bug that only mattered at server start before FIX-D now had a path to fire
   unattended, while someone was watching.

Each stage ships alone and is verifiable alone.

## Out of scope

- Restarting the server, the listener or the auth on any of this.
- Mirroring changes, resolution changes inside one display beyond what the
  layout comparison already covers.

~~Subscribing to `CGDisplayRegisterReconfigurationCallback` (the watchdog needs
no notification, and the old plan's reasons against it still hold).~~
**Revisited and shipped as FIX-D below** - not because the watchdog above
needed it, but because production found a case the watchdog cannot see BY
CONSTRUCTION: a display that is RESIZED, not silenced, keeps delivering
frames forever, so nothing about it ever looks like silence. See FIX-D.

## FIX-D — react to macOS's own reconfiguration notice

Measured on the installed build (2026-09-12): changing the built-in
display's mode mid-session (1710x1112 -> 1470x956) while a client was
streaming produced 753 client updates and ZERO re-arms, with the canvas
stuck at the pre-change 5552x2715 composite size the whole time.
`ScreenCapturer.m` pins `SCStreamConfiguration.width`/`height` at `Build`
time, so a reconfigured display keeps delivering frames - just rescaled to
the OLD dimensions - and the watchdog above, which only ever reacts to
silence, has nothing to react to.

`AppDelegate` now observes `NSApplicationDidChangeScreenParametersNotification`
and calls one new, unconditional, AppKit-free core entry point,
`vncServerNoteDeskShapeMayHaveChanged()`. A no-op while idle (the next
connect already reads the desk fresh). Otherwise debounces 500ms on the
EXISTING `gCaptureStopQueue` (real reconfigurations fire this notification
several times as the desk settles) and, once settled, re-reads the desk
WITHOUT waking it (`resolveDeskLayoutWithoutWaking()`, the same call
`rearmCaptures()` already uses), compares against the published layout with
the EXISTING `macVNCDisplayLayoutsEqual()`, and rebuilds - via the EXISTING
`rearmCaptures()`, unchanged - only if they differ.

This is cheap specifically because the three objections the ORIGINAL
`display-reconfiguration.md` plan raised against reacting to reconfiguration
are each already answered by machinery this file's own earlier follow-ups
built for an unrelated reason - see that plan's "superseded by FIX-D" note
for the point-by-point mapping. Nothing here restarts the server, touches
the listener/auth, or shares the silence watchdog's own
`gRearmsSinceFrame`/`gLastRearmNs`/`gCaptureRearmCount` bookkeeping - a
shape-driven rearm gets its own counters
(`macVNCDeskShapeRebuildCountForTesting`/`...FailureCountForTesting`), so a
display reconfiguring repeatedly cannot push the silence watchdog toward a
`GiveUp` it never earned. A failed shape-driven rebuild still reaches the
user through the same `reportCaptureFailure()` every other trigger uses.

Tests: `tests/test_capture_liveness_rearm_deskshape.m` asserts the decision
(debounce coalescing, equal => no rebuild, different => exactly one rebuild,
idle => no-op), driving the real core entry point directly rather than
faking a CoreGraphics reconfiguration.

Also while here: `tests/test_capture_liveness_rearm_multidisplay.m`'s Test A
("an idle second display cannot trigger a re-arm") used to fall back to a
bare `printf(...SKIPPED...)` with no real ctest `SKIP` on a single-display
host, so the whole binary still exited 0 whether or not that half's
assertions ever ran. Split into its own target,
`test_capture_liveness_rearm_multidisplay_idle.m`, with its own
`SKIP_RETURN_CODE 77`, so ctest can tell "proved the fix" from "never ran
it" apart.

## FIX-E — an honest log, and S4 finally done

Two loose ends a whole-diff review found in FIX-D itself.

**The log claim was false.** This plan and `src/ARCHITECTURE.md` both said an
unchanged desk "does nothing and logs nothing" once FIX-D's comparison found
it equal. True for captures, false for the log: FIX-D's debounce evaluation
reads the desk through `resolveDeskLayoutWithoutWaking()` purely to COMPARE
against the published layout, and that function calls the same
`collectDisplayInputs()` startup uses - which unconditionally logs one
"Found ... display ..." line per attached display. A burst of
screen-parameter notifications on a connected session printed a full display
enumeration on every evaluation, changed or not; verified live, the log
showed the "Found primary/secondary display" pair on every debounce tick
regardless of outcome. Fixed at the source: `collectDisplayInputs()` and
`resolveDeskLayoutWithoutWaking()` both take a `logEnumeration` flag now -
TRUE for a caller already committed to ACTING on the read (startup;
`rearmCaptures()`'s own re-read, which only runs when a rebuild is really
happening), FALSE for FIX-D's debounce probe, the one caller that might
discard the read entirely. The existing `Display configuration changed:
canvas AxB -> CxD; re-arming display captures` line - printed only when a
rebuild is really about to happen - is unchanged and still the one honest
signal.

**S4, finally done.** `displayNumber >= 0` selected by POSITION in whatever
CoreGraphics enumerated - harmless while only startup ever selected, live
and unattended the moment FIX-D made re-selection happen mid-session. A desk
event reordering the enumeration could silently move a pinned capture to a
different physical monitor, with only a log line noticing after the fact
(`logIfPinnedSelectionChangedDisplay()`, now removed as unreachable). Fixed
by resolving `displayNumber >= 0` to a concrete `CGDirectDisplayID` the
FIRST time a server run selects it (`gPinnedDisplayID` in `mac.m`, reset to
0 - never a real id - at every server start alongside `displayNumber`
itself) and selecting by that IDENTITY on every later call
(`macVNCSelectDisplayByID()`, new in `src/DisplaySelection.c`, pure and
covered in `tests/test_display_selection.c`: pinned id present, pinned id
absent, pinned id present but at a DIFFERENT index than before - the exact
shape a hot-unplug/replug reorder produces). If the pinned display is no
longer attached, `applySelectionAndBuildLayout()` refuses outright rather
than substituting another monitor - the same `reportCaptureFailure(false)`
path a failed rebuild already uses, never a server stop. `-1` (primary) and
`-2` (all) are untouched: they never populate `gPinnedDisplayID` and keep
re-evaluating live, which is what those settings mean. The settings format
is untouched too - Preferences still writes an index; the pinning is purely
a runtime resolution detail.
