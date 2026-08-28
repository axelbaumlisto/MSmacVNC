# macVNC — Architecture

A menu-bar macOS VNC **server**: it captures the local display(s) with
ScreenCaptureKit, composites them into one framebuffer, and serves them over
RFB via LibVNCServer. Written in C + Objective-C with **Manual Reference
Counting** (no ARC).

## Design in one sentence

Keep all non-trivial logic in small, dependency-free, unit-tested **pure C
modules**, and keep the Objective-C layer as thin glue to macOS frameworks
(AppKit, ScreenCaptureKit, IOKit, Security) and to LibVNCServer.

## Layers

```
                 ┌──────────────────────────────────────────────┐
   UI / glue     │ main.m → AppDelegate (status bar, lifecycle)  │
   (Obj-C)       │   MacVNCPreferences · MacVNCPermissionsPanel  │
                 │   MacVNCStartupConfig (defaults+env → config) │
                 │   MacVNCRelauncher · MacVNCLoginItem          │
                 │   MacVNCPassword · MacVNCDefaultsKeys         │
                 └───────────────┬──────────────────────────────┘
                                 │ MacVNCServerConfig (by value)
                                 │ macVNCCaptureAllowed (policy in)
                 ┌───────────────▼──────────────────────────────┐
   Server core   │ mac.m: ScreenInit, client lifecycle,          │
   (C / Obj-C)   │        start/stop, listener teardown          │
                 │   MacVNCCaptureSession (owns ScreenCaptureKit) │
                 │   MacVNCCompositor (pixels → canvas, locking) │
                 │   MacVNCInput (kbd/ptr)  MacVNCPowerMgmt      │
                 │   MacVNCDisplayWake      ScreenCapturer (SCK) │
                 └───────────────┬──────────────────────────────┘
                                 │ function-pointer / block seams
                 ┌───────────────▼──────────────────────────────┐
   Pure logic    │ DisplayLayout · DisplaySelection              │
   (C, tested)   │ CompositeFramebuffer · MacVNCStatusText       │
                 │ MacVNCPermissionUI · MacVNCStartFailure       │
                 │ MacVNCAllowlistPlan                           │
                 │ NetworkAccess · NetworkCIDR · NetworkInventory │
                 │ NetworkPolicyResolver · FirstFrameBudget       │
                 │ FrameMailbox · PointerState                    │
                 │ KeyboardModifierState · CaptureRate · RFBKeySym│
                 └───────────────────────────────────────────────┘
```

The core holds no permission policy: it asks through `macVNCCaptureAllowed`
(NULL = unrestricted). Reading TCC in the core would put the decision that can
raise macOS's own screen-recording dialog inside the file that starts the
server, and would make the "no permission, no capture" rule untestable.

## Module responsibilities

Pure logic, each with a unit test wired into `ctest` (`.c` for C modules,
`.m` for the Objective-C ones — `MacVNCStatusText`, `MacVNCPermissionUI`,
`MacVNCStartFailure`, which are Foundation-only and free of AppKit):
- **DisplayLayout** — build a non-overlapping composite layout; map a
  framebuffer point back to a global display coordinate.
- **DisplaySelection** — which attached displays a run captures (all / primary /
  one index); order is preserved because the composite layout depends on it.
- **CompositeFramebuffer** — tile-diff copy of one BGRA display into the shared
  canvas; reports dirty rects through an injected callback.
- **NetworkAccess / NetworkCIDR / NetworkInventory** — IPv4/CIDR parsing,
  allowlist matching, interface enumeration.
- **NetworkPolicyResolver** — pure decision `defaults/env → {bind, allowlist,
  access mode}`; fail-closed by default.
- **FirstFrameBudget** — ONE deadline for "every display has produced its first
  frame", shared across displays so a two-monitor Mac does not double a client's
  wait, plus `macVNCMonotonicNow()`, the one shared monotonic clock.
- **FrameMailbox** — thread-safe single-slot latest-frame handoff with
  injected release/activity callbacks.
- **PointerState / KeyboardModifierState** — input resolution state machines.
- **CaptureRate** — validate FPS, derive the frame interval.
- **MacVNCStatusText** — status-bar strings from observed state (a stopped
  server reports no clients whatever the counter holds).
- **MacVNCPermissionUI** — chips, hint, button title, and the
  `shouldStartServer` / `shouldShowPanel` decisions, from one snapshot.
- **MacVNCAllowlistPlan** — turns a Preferences selection into the allowlist
  that gets saved: interface preset plus manual entries, de-duplicated in order,
  with a verdict of OK / admits-nobody / admits-everyone. Allow-all is detected
  by PREFIX (any `/0`), never by matching the literal `0.0.0.0/0`.
- **MacVNCStartFailure** — what to say when the server does not come up.
  Silence on a real failure and a port-collision alert stacked over the
  permission panel are both wrong; the decision is pure and tested.

Objective-C glue:
- **AppDelegate** — status-bar UI, timers, server start/stop, permission flow;
  installs the capture-permission policy into the core.
- **MacVNCCompositor** — composites raw BGRA pixels into the shared canvas
  (`macVNCCompositorSubmitFrame(geometry, pixels, stride, hint)`); OWNS the screen
  pointer (`macVNCCompositorSetScreen`) — detach takes the compositor lock, so
  returning from it means no in-flight composite can reach the screen.
  Taking pixels rather than a `CMSampleBuffer` is what makes the hot path
  unit-testable without a live capture stream — see `tests/test_compositor_submit.m`.
  Takes every client's `sendMutex` with `trylock` only: LibVNCServer holds it
  for the whole encode-and-write, so waiting would let one stalled viewer
  freeze the screen for all clients. A refused frame must be re-submitted, not
  dropped.
- **MacVNCImageProfile** — maps a stored setting name (`viewer`, `lossless`, or
  a level `0`-`7`) to encoder levels (`macVNCParseImageProfile`). Pure, and the
  ladder is measured rather than chosen: levels 8 and 9 are refused because both
  cost MORE bytes than lossless while being worse than lossless, and the
  compression level is fixed because levels 1-9 are byte-identical. On a
  rejected name the output is left untouched, so callers pre-load the default
  instead of restating it in every branch.
- **MacVNCSweepSchedule** — decides when a display must be composited in full
  regardless of the dirty hint (`macVNCSweepScheduleDueAt`). Pure, so the
  safety net under the hint is tested directly: first frame always sweeps, the
  deadline is inclusive, a display that went quiet owes ONE sweep rather than
  a burst, and a missing schedule fails safe by sweeping.
- **MacVNCCaptureSession** — owns ScreenCaptureKit. Builds one stream per
  display from a `MacVNCDisplayLayout`, unwraps each `CMSampleBuffer` to plain
  BGRA pixels, reads the frame's dirty-rectangle metadata into a
  `MacVNCDirtyHint`, classifies `SCStreamError` into "permission denial or not",
  and shares ONE first-frame budget across displays so a two-monitor Mac does
  not make the client wait twice as long. Because it holds the framework,
  `mac.m` no longer includes ScreenCaptureKit at all.

### The dirty hint is an optimisation, never the source of truth

Comparing all 29.5 MB of a captured frame against the canvas was the most
expensive thing the server did per frame (measured: 44 ms average, 536 ms worst,
29% CPU while streaming). ScreenCaptureKit already reports which rectangles it
repainted, so that metadata now bounds the comparison — 3 ms average, 5% CPU.

Being wrong about a hint means a region of the client's screen stays stale, so
the hint is treated as untrusted input at four levels:

The entry point is `macVNCCompositeDisplayFrameHinted`; passing no hint falls
back to `macVNCCompositeDisplayFrame`, the full sweep.

1. **Every hinted tile is still compared** before being copied, so an
   over-reporting hint costs a scan and nothing else, and a rectangle whose
   pixels did not actually change produces no client traffic.
2. **Rectangles are clamped into the frame and aligned down to the tile grid.**
   `compositeTileRange` asserts the band it receives is in range, so deleting a
   clamp fails the tests instead of forming pointers outside the buffers.
3. **Anything unexpected means "sweep everything"**, never "nothing changed":
   missing or malformed metadata, or more than `MACVNC_MAX_HINT_RECTS` (32)
   rectangles, all yield `count == 0`, which the compositor treats as a full
   sweep.
4. **Every display is swept in full every 5 seconds regardless.** If a hint
   ever under-reports, the next sweep repairs the region rather than leaving a
   permanent hole. That schedule is `MacVNCSweepSchedule`, a pure module rather
   than a timestamp inside the capture callback: it is the rule that makes
   trusting a hint safe, so it is worth being able to test it without a live
   capture stream.

Verified empirically, not just by construction: a temporary audit ran a FULL
sweep immediately after each hinted composite over the same pixels and counted
the tiles the hint had missed. Under window-dragging and scrolling load across
two displays — 500 hinted frames, 61 225 tiles found by the hint — the audit
found **0** missed tiles, which is also what proves the rectangles arrive in
pixels rather than points.
- **MacVNCRelauncher** — `posix_spawn` of our own executable, used when a newly
  granted permission needs a fresh process. Both permissions bind at launch.
- **MacVNCDefaultsKeys** — defaults keys *and* their registered fallbacks, so a
  new key without a default cannot slip through (an absent allowlist default
  would mean an empty allowlist, not loopback-only).
- **MacVNCStartupConfig** — pure builder: `NSUserDefaults` + environment →
  `MacVNCServerConfig` (owns backing storage; unit-tested).
- **MacVNCPreferences** — the Preferences dialog (view build / policy resolve /
  persist).
- **MacVNCPermissions / MacVNCPermissionsPanel** — Screen-Recording &
  Accessibility checks and the gate panel.
- **MacVNCInput** — keyboard/pointer injection; owns the CGEventSource, keymaps
  and input mutexes; geometry is injected via `macVNCInputSetContext`.
- **MacVNCPowerMgmt** — two session-scoped IOPMAssertions (system sleep +
  display sleep), created by the capture reconciler when the first client
  connects and released when the last leaves; `undim` is a throttled activity
  nudge. Never touches global Energy Saver values.
- **MacVNCDisplayWake** — one-shot display wake (no persistent assertion).
- **MacVNCPassword** — password load/store (plaintext in defaults, by request)
  and the hardened `MACVNC_PASSWORD_FILE` reader.
- **ScreenCapturer** — one display's SCStream lifecycle + readiness.

## Key seams (dependency inversion)

- `vncServerStart(const MacVNCServerConfig *)` — immutable config **by value**;
  the core keeps a private copy. No ambient mutable globals in the public API.
- `macVNCInputSetContext(screen, layout)` — input module never reaches into
  server-core globals for geometry.
- `macVNCScreenCaptureFailureHandler` — function pointer so the core reports
  capture failures without depending on AppKit/UI.
- `macVNCCaptureAllowed` — the core asks whether it may touch capture and never
  reads TCC itself.
- `FrameMailbox` / `CompositeFramebuffer` callbacks — producers are agnostic to
  how frames are freed and how dirty regions are consumed.

## Tests

`ctest` runs 34 targets (the number is enforced: `architecture_doc` compares
this sentence against CMakeLists.txt's `add_test` count, so a target added or
commented out fails the suite until this line is updated deliberately). Every
assertion added here is checked by mutating the source and confirming the test
goes red — a green test proves nothing until it has been seen to fail. Test
targets and `macvnc_core_testable` get `-UNDEBUG` automatically, and
`tests/assert_guard.c` (compiled into each of them) makes the build **fail**
if NDEBUG survives anywhere: a hand-maintained list once shipped a test that
printed "all assertions passed" while checking nothing, and the old property
check verified a flag it had set itself two lines earlier.

`tests/*.py` are end-to-end scripts driven by hand (they need a live server, a
real client and a granted permission). They are **not** part of `ctest` and
must not be counted as automated coverage.

## Concurrency model

- `serverLifecycleMutex` serialises start/stop; `compositorMutex` (owned by
  **MacVNCCompositor**) guards the shared canvas; `clientLifecycleMutex` guards
  per-client state and the connected-client count; `vncConnectedClients` /
  `publishedServerPort` are `_Atomic`.
- **MacVNCCaptureSession** holds no lock of its own. Its set is mutated only
  under `serverLifecycleMutex` at points where no client thread is running, and
  merely read from client threads; see the header for the invariant that makes
  this sound.
- `captureControlMutex` serialises capture start/stop and is **never** held
  together with `clientLifecycleMutex`, so no order can arise between them.
  Captures run iff `vncConnectedClients > 0`; both the connect and disconnect
  paths call `reconcileCaptureState()` after updating the count and after
  dropping the client lock, because stopping waits (bounded) for in-flight
  ScreenCaptureKit work and holding the client lock across that would stall a
  reconnect.
- **Lock order:** `serverLifecycleMutex` → `compositorMutex` → per-client
  `sendMutex` → per-client `updateMutex`. The first edge exists because
  `vncServerStopLocked` calls `macVNCCompositorSetScreen(NULL)` while holding
  the lifecycle mutex, and the detach blocks on the compositor lock — anyone
  adding a lifecycle acquisition INSIDE the composite path would deadlock the
  server. The last edge is LibVNCServer's own order, verified in the 0.9.15
  sources: the update thread takes `sendMutex` (main.c:507) and then
  `updateMutex` (rfbserver.c:3234) inside `rfbSendFramebufferUpdate`, while
  `rfbMarkRectAsModified` — which our composite path calls — takes only
  `updateMutex` (main.c:419). Both sides therefore order sendMutex above
  updateMutex; no ABBA edge exists.
  `lockCurrentClients` retains each client so it can't be freed mid-composite;
  `clientLifecycleMutex` is never taken while holding the compositor lock.
  The compositor takes every `sendMutex` with `trylock`, and that stands on its
  own argument: LibVNCServer holds a client's `sendMutex` for the whole
  encode-and-write, so ONE viewer that stops reading its socket (congested link,
  suspended laptop, hostile peer) would freeze the screen for every client.
  A refused frame is re-submitted by `ScreenCapturer`'s retry, not dropped.
- **Screen publication:** `rfbScreen` is set to NULL *before* `rfbScreenCleanup`,
  because the capture stop is deliberately bounded and a late frame must see
  NULL rather than a freed pointer.
- **First-frame wait ends on the answer, not on the clock:** a capture failure
  goes through `-[ScreenCapturer reportCaptureError:]`, which broadcasts the
  readiness condition BEFORE calling the error handler. Without that, a client
  that had just authenticated sat out the whole 8-second budget waiting for a
  frame that was never coming (`tests/test_first_frame_wait.m` fails if the
  wait starts consuming its budget again). The wake does not fake readiness:
  `_firstFrameReady` stays NO, so the waiter reports "not ready" immediately.
- **Main-thread rule:** every server query the menu timer makes
  (`vncServerCopyActiveBindAddress`, `vncServerActivePolicyAllowsEveryone`,
  `vncServerCloseListeners`) takes the lifecycle
  lock with `trylock` and returns the safe answer when it is busy. Blocking
  would freeze the menu bar behind a stop that is waiting on capture.
- **Teardown ordering** (`vncServerStopLocked`): `rfbShutdownServer(TRUE)` joins
  every client thread AND the listener thread (verified in the 0.9.15 sources,
  main.c:1200-1250: per-client `pthread_join` at :1218, listener join at :1245)
  **before** capturers stop and before `macVNCInputShutdown` clears the injected
  context — so input/compositing callbacks can never touch freed objects.
- **ScreenCapturer quiescence:** a `dispatch_group` is entered for every async
  unit and drained on stop/dealloc; a generation counter rejects stale
  callbacks. Do not "simplify" this without a concurrency argument.

## Build & test

```
cmake -S . -B build -DBUILD_TESTING=ON -DCMAKE_PREFIX_PATH=/opt/homebrew/opt/libvncserver
cmake --build build -j
ctest --test-dir build          # keep the display awake (caffeinate) for capture tests
```

Release/notarization lives in `packaging/make_release.sh` (+ `packaging/entitlements.plist`):
Developer ID + hardened runtime + `com.apple.security.cs.disable-library-validation`
(required so the bundled Homebrew dylibs load for VNC DES auth).

Two invariants that are easy to “optimise” and thereby break — both learned the hard way:

1. **Bundle the real dylib targets** (`os.path.realpath`), never the version symlinks,
   or a stale OpenSSL gets shipped.
2. **Keep `disable-library-validation`.** Verified by A/B re-signing one bundle twice:
   without it the reference client gets `INIT_FAILED` and the server logs
   `rfbAuthProcessClientMessage: password check failed`; with it, `AUTH_OK`. This is
   true even though the script signs every bundled dylib with our own Developer ID,
   so “the dylibs are same-team signed, drop the entitlement” does **not** work.
   Validate any change here with the reference libvncclient — `vncdotool` reports a
   false `AUTH OK` and will hide the regression.

These files are intentionally under `packaging/`, not `build/`: `build/` is CMake
scratch and is git-ignored, so keeping the signing recipe there meant a routine
`rm -rf build` destroyed it irrecoverably.
