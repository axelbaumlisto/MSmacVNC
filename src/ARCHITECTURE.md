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
                 │   MacVNCCurtainWindow (black locally only)    │
                 │   MacVNCCurtainInput (local keys and clicks)  │
                 │   MacVNCCurtainController (when, and only when)│
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
                 │ MacVNCCurtainPolicy                            │
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
- **CaptureRate** — parses and validates the capture rate, derives the framebuffer
  defer window from it (`macVNCFramebufferDeferMilliseconds`, a fixed 10 ms
  coalescing window rather than the frame interval it used to be), and owns the
  rate ladder the settings UI offers. The ladder lives here, not in the UI, so
  a test can assert the SHIPPED default is on it - otherwise changing the
  default would silently downgrade the popup to "Custom - N fps".
- **MacVNCEncryptionPolicy** — decides whether an unencrypted viewer is admitted
  (`macVNCEncryptionAdmits`). Pure, so "who is let in" is tested without a
  socket. It exists because the ORDER of security types cannot be controlled:
  LibVNCServer inserts each handler at the head of its list and sends the list
  from the head (`auth.c:58-69`, `:224`), and registers its own VncAuth handler
  lazily on the FIRST connection - after ours - so plain is always offered
  first and every viewer takes it. Refusing is the only reliable lever.
  Enforced in `macVNCPasswordCheck`, the first moment the answer is known:
  `cl->sslctx` is non-NULL only once the VeNCrypt handshake has completed.
  The refusal is indistinguishable from a wrong password on the wire, and
  explicit in the log.
- **MacVNCImageProfile** — maps a stored setting name (`viewer`, `lossless`, or
  a level `0`-`7`) to encoder levels (`macVNCParseImageProfile`). Pure, and the
  ladder is measured rather than chosen: levels 8 and 9 are refused because both
  cost MORE bytes than lossless while being worse than lossless, and the
  compression level is fixed because levels 1-9 are byte-identical. On a
  rejected name the output is left untouched, so callers pre-load the default
  instead of restating it in every branch.
- **MacVNCCurtainPolicy** — the way BACK from curtain mode: whether what the
  person standing at the Mac typed lifts the curtain
  (`macVNCCurtainPolicyFeed`). Pure, because the caller is a `CGEventTapCallBack`
  behind a black screen: the module never sleeps, never allocates and never
  reads a clock — the caller passes the monotonic timestamp in, and the throttle
  after a wrong attempt is a CAPPED deadline it compares against, since a
  blocking callback makes WindowServer disable the tap and an uncapped backoff
  is indistinguishable from a lockout. It compares only the 8 effective bytes
  VNC's DES auth keys itself from (`MACVNC_CURTAIN_SECRET_EFFECTIVE_BYTES`,
  mirroring `MACVNC_VNC_PASSWORD_EFFECTIVE_MAX`), constant-time and with no
  early exit; a full-string comparison would refuse a password the server
  itself accepts. Its input is already-translated UTF-16 units, as
  `CGEventKeyboardGetUnicodeString` produces them, buffered as UTF-8 BYTES so
  the comparison agrees with the server on non-ASCII secrets. It refuses to arm
  without a usable secret (`macVNCCurtainPolicyArm`) — deliberately breaking the
  parser modules' leave-the-output-untouched rule, because here "untouched"
  would mean a curtain still armed with a password the owner just cleared. The
  typing buffer is fixed and cleared on every outcome, and
  `macVNCCurtainPolicySecretChanged` is the seam for "any change to the secret
  lifts the curtain".
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
  It also owns the curtain's capture half
  (`macVNCCaptureSessionSetSelfExcluded`): every stream's filter is rebuilt to
  exclude THIS APPLICATION and swapped onto the RUNNING stream with
  `-updateContentFilter:completionHandler:`. Excluding by application rather
  than by window is what makes the exclusion survive window recreation, so
  display hot-plug is a pure window-creation problem — but it is NOT
  order-independent, as this document claimed until a live run said otherwise:
  naming ourselves needs an `SCRunningApplication`, and a discovery lists only
  the owners of shareable WINDOWS, so the caller must already have a window on
  screen when it asks. A session with no live stream reports FAILURE, because
  "nothing to exclude" must not read as "the curtain may go up".
  WHICH application the filter names is resolved by `ScreenCapturer`, and that
  resolution is the one thing 41 green test targets did not cover: see below.
- **MacVNCCurtainWindow** — the curtain's screen half: one borderless black
  window per `NSScreen` at `NSScreenSaverWindowLevel` (joining all Spaces, and
  auxiliary to full-screen apps, because the level alone covers neither),
  ordered in with `orderFrontRegardless` so the LSUIElement app never activates
  or takes focus. Three rules are load-bearing. (1) The window is `setOpaque:NO`
  with `MACVNC_CURTAIN_ALPHA` = 0.999: an opaque occluder would make every
  window under it report `NSWindowOcclusionState` "not visible", well-behaved
  apps would stop drawing, and the REMOTE viewer would get a frozen desktop
  that a "not black" acceptance test still passes. 0.999 is a luminance
  criterion, not a taste: `(1 - alpha) * 255 = 0.255` of one 8-bit level, which
  quantises to 0 even over pure white — stated for 8-BIT output, since the same
  arithmetic yields level 1 of 1023 on a 10-bit panel (the header says so, and
  the on-device luminance check is what would justify changing the value). (2)
  The raise ARMS before it asks: the windows are ordered in at
  `MACVNC_CURTAIN_ARMING_ALPHA` = 1/255 FIRST, because ScreenCaptureKit lists
  an application only while it owns a window and this LSUIElement app owns none
  — a live run with 797 delivered frames proved the previous "filter first"
  order impossible, not merely slow. 1/255 is the mirrored luminance criterion:
  non-zero, since a window at alpha 0 is a plausible thing for a window server
  not to composite at all, and at most ONE 8-bit level of dimming over pure
  white, since at that instant the exclusion is not yet in place and whatever
  the armed window costs, it costs the REMOTE viewer too. The mapping from the
  two states to the two alphas is a published pure function
  (`macVNCCurtainOccluderAlpha`) so it is checkable without a window server.
  (3) Raise and lift are MIRRORED orders — arm the windows, swap the filter,
  then make them opaque; make them transparent and order them out, then restore
  the filter — and a swap that never answers is a FAILURE, bounded by
  `MACVNC_CURTAIN_FILTER_SWAP_TIMEOUT_NANOSECONDS`, after which the windows are
  ordered out WHILE STILL INVISIBLE and the exclusion is taken back, so a
  refused raise leaked nothing to either party. The window set, the ordering and
  the timeout sit above injected seams (occluders, exclusion, scheduler), so
  `tests/test_curtain_window.m` exercises hot-plug (including hot-plug WHILE
  armed, which must stay armed), both orders, the timeout
  and the late-answer race with no display attached, plus the rule that a
  curtain which is DOWN answers `NSApplicationDidChangeScreenParameters` with
  nothing at all — a resolution change or a display sleep must not quietly
  allocate a window per screen for a curtain nobody raised.
  `tests/test_capture_exclusion.m` covers the other side of the seam: one
  answer per request, on the main thread, surviving a session rebuilt from
  another thread. A curtain dropped mid-transition still ANSWERS its pending
  completion, and one deallocated while Up hides its windows AND gives the
  stream back — hiding only the windows would leave the remote viewer without
  this application forever, with nobody left to ask for it back.
- **MacVNCCurtainController** — the one place that answers "should the curtain
  be up", above five injected seams (the curtain, the input suppression the tap
  will provide, the capture health, the secret and the clock), so every raise
  and lift transition is a unit test with no device, no tap, no window and no
  real time. Four rules carry the design. (1) The raise is EDGE-triggered, on
  the transition to a first authenticated client and on nothing else: a
  level-triggered raise would make the escape hatch a no-op — lift,
  re-evaluate, re-raise — so every other input can only LIFT. (2) A local lift
  LATCHES the rest of the app run down; latching only until the next connection
  would let whoever holds the VNC password re-blind the local user by
  reconnecting in a loop. (3) A live stream plus an authenticated client is a
  CONTINUOUSLY enforced invariant, not a raise-time precondition: it is
  re-checked on every event and on a heartbeat
  (`MACVNC_CURTAIN_HEARTBEAT_NANOSECONDS`), which is also what catches the two
  failures nobody reports — a stream that died after the raise, and a session
  rebuilt by a server stop/start, whose new streams carry the default filter
  again and no longer exclude us (`macVNCCaptureSessionSelfExcluded`). A beat
  that arrives more than `MACVNC_CURTAIN_HEARTBEAT_STALL_NANOSECONDS` late means
  time nobody observed (suspension, sleep, a stalled main queue) and lifts,
  because input fails open by itself while the SCREEN does not. (4) Without
  input suppression there is no curtain: a controller with no tap seam, or a
  tap that reports it cannot be armed, refuses to raise rather than producing a
  black screen with a live keyboard. It also refuses without a usable password
  (`macVNCCurtainPolicyArm`) and lifts when the secret changes in the 8 bytes
  the server can actually see (`macVNCCurtainPolicySecretChanged`). Raised
  state is never persisted and nothing raises at launch. **AppDelegate**
  constructs it at launch and feeds it: the preference (`MacVNCKeyCurtain`,
  off by default), the server's running state, the authenticated client count,
  the capture-failure report, and the local session's usability. The CURTAIN is
  passed in rather than built by the factory, because its window set is also
  the tap's focus seam and there must be exactly one of it.
- **MacVNCCurtainInput** — the curtain's input half: the event tap that
  swallows what the person standing at the Mac types and clicks, and the only
  path back in (it feeds **MacVNCCurtainPolicy** and reports the unlock). Six
  rules carry it. (1) THREE preconditions, not one: Accessibility trust
  (checked with the prompt SUPPRESSED — no code path here may raise a macOS
  dialog), a non-NULL `CGEventTapCreate`, AND the keyboard bits still present
  in the EFFECTIVE mask, read back with `CGGetEventTapList`
  (`macVNCCurtainInputMaskKeepsKeyboard`). The third is not a re-check of the
  first: without trust the keyboard bits are silently cleared while the tap is
  still created, which would give a black screen with a fully live keyboard
  typing into invisible applications — so any of the three failing means
  `-beginSuppressingInput` answers NO and the curtain stays down. (2) Our own
  injection passes through UNMODIFIED: `CGEventPost` delivers to taps at the
  same location, so the remote viewer's own input arrives here. It is
  recognised by `MACVNC_CURTAIN_INPUT_EVENT_MAGIC`, set on the server's private
  event source in **MacVNCInput**, plus the posting process id for the one
  legacy path (`CGPostMouseEvent`) that has no source to tag
  (`macVNCCurtainInputEventIsSelfInjected`). (3) The tap runs on ITS OWN thread
  and run loop, and is torn down there (disable, invalidate, release) —
  cross-thread invalidation is a use-after-free, and a wedge on the main thread
  would take the callback and the AppKit path down together. (4) The callback
  cannot block: no shared lock, no I/O, no sleep, no keystroke logging; the
  unlock policy has exactly ONE owner (the tap thread), so keys arriving
  through the window are carried onto it rather than locked against. (5) FOCUS:
  the curtain window is NOT key while the tap is healthy — the tap is the only
  path to the policy and a key window would collect the REMOTE party's
  keystrokes — and becomes key ONLY while the tap path is known unavailable
  (secure input on, or a tap that could not be re-enabled), where its `keyDown:`
  applies the same self-injection tag. Secure input is polled ON THE TAP'S OWN
  THREAD (`IsSecureEventInputEnabled` is not thread safe), corroborated by
  "keys stopped while the pointer kept moving"
  (`macVNCCurtainInputSecureInputSuspected`), and the focus hand-over LATCHES
  for the rest of the suppression session — taking focus is an app activation,
  which deactivates the secure-input owner, so following the next reading back
  down would flap at 10 Hz with the local user's password split across two
  applications. (6) The watchdog measures LATENCY, NOT SILENCE
  (`macVNCCurtainInputWatchdogEvaluate`) — with one deliberate exception. An
  idle user produces no EVENTS, so "no callbacks for N seconds" would fire in
  the feature's normal state; a callback is therefore judged only by how long
  it has been in flight, and the main-thread heartbeat by how long it has gone
  unacknowledged. THE POLL IS THE EXCEPTION: it is timer-driven, so nobody has
  to act for it to run, and its silence IS a fault — it is the only detector of
  a tap that went deaf without saying so (a disabled tap never delivers the
  disable notification, which is itself an event) and it shares the run loop
  with the callback, so without that clause a wedged tap thread reads as
  healthy while the screen is black and the keyboard live. Unobserved time is
  not a wedge: `CLOCK_MONOTONIC` advances while a frozen process sleeps, so the
  watchdog measures its OWN observation gap first and re-baselines rather than
  killing a healthy server on lid-open. Its action, when something really is
  stuck, is `abort()`, because process death is the only thing that restores
  the SCREEN from outside a wedged main thread. Everything above the tap seam is exercised by
  `tests/test_curtain_input.m` with real `CGEvent`s and no tap at all; the tap
  itself, the thread, the watchdog's abort and the AppKit key window need a
  device. **AppDelegate** constructs it as the controller's suppression seam,
  with the controller as its observer through a one-way bridge (the controller
  retains the input, so a direct back-reference would be a cycle). That
  observer is load-bearing rather than decorative: the focus hand-over on
  secure input latches, and it is safe only because the controller LIFTS
  synchronously inside the same main-queue block, ending suppression and giving
  the focus back. An observer that kept the curtain up would leave the curtain
  window key, where `-keyDown:` drops self-injected events - the REMOTE
  viewer's keyboard would die while their mouse kept working.
  `tests/test_curtain_controller.m` exercises that composition with the real
  input module above a fake tap.

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
  would mean an empty allowlist, not loopback-only). `MacVNCKeyCurtain` is off
  by default, and that value is a safety decision: the curtain is raised by
  whoever connects with the VNC password, so shipping it on would let the
  remote party blind the person standing at the Mac.
- **MacVNCStartupConfig** — pure builder: `NSUserDefaults` + environment →
  `MacVNCServerConfig` (owns backing storage; unit-tested).
- **MacVNCPreferences** — the Preferences dialog (view build / policy resolve /
  persist).
- **MacVNCPermissions / MacVNCPermissionsPanel** — Screen-Recording &
  Accessibility checks and the gate panel.
- **MacVNCInput** — keyboard/pointer injection; owns the CGEventSource, keymaps
  and input mutexes; geometry is injected via `macVNCInputSetContext`. The
  event source carries `MACVNC_CURTAIN_INPUT_EVENT_MAGIC` so a raised curtain's
  tap can tell the remote viewer's input from the local user's; the one path
  that cannot be tagged (`CGPostMouseEvent`, kept because it takes a button
  MASK plus a position, so drags and double clicks need no synthesis) is
  identified by process id instead. The tag is inert without a tap, so a server
  that never raises a curtain behaves exactly as before.
- **MacVNCPowerMgmt** — two session-scoped IOPMAssertions (system sleep +
  display sleep), created by the capture reconciler when the first client
  connects and released when the last leaves; `undim` is a throttled activity
  nudge. Never touches global Energy Saver values.
- **MacVNCDisplayWake** — one-shot display wake (no persistent assertion).
- **MacVNCPassword** — password load/store (plaintext in defaults, by request)
  and the hardened `MACVNC_PASSWORD_FILE` reader.
- **ScreenCapturer** — one display's SCStream lifecycle + readiness, and the
  resolution of THIS process's own `SCRunningApplication` — the object the
  curtain's filter excludes.
  `applications` lists the owners of shareable CONTENT, and content means
  WINDOWS — so a menu-bar app that owns none is ABSENT from every discovery
  result. TWO live runs were needed to establish that. The first showed
  "application no" for every display with the plain
  `+[SCShareableContent getShareableContentWithCompletionHandler:]`; the fix
  that followed — asking
  `+getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:completionHandler:`
  with `onScreenWindowsOnly:NO` — printed the SAME line on the same hardware.
  So the variant was never the cause, and the ordering was: the curtain now
  arms an invisible window BEFORE the request (see **MacVNCCurtainWindow**),
  and the application is resolved when it is NEEDED
  (`-resolveOwnApplicationWithCompletionHandler:`, one round trip per stream,
  then cached) rather than only at stream start — but ONLY behind a running
  stream, because a discovery is what can raise a Screen Recording prompt and a
  live stream is the proof the permission is already granted. Because that was
  twice guessed and twice wrong, it is now MEASURED: every discovery is
  censused (`macVNCTakeShareableContentCensus`) and logged
  (`macVNCLogShareableContentCensus`) at stream start, when this process owns no
  curtain window, and again at the exclusion request, when it does — so one run
  of the app decides whether owning a window is what makes us listed, and the
  log says outright when it is not ("SCK lists N window(s) of this process but
  not the process itself"), which is the only evidence that would justify
  excluding by window instead. Unresolved still fails CLOSED:
  `macVNCCaptureExclusionMayProceed` refuses an exclusion that
  can name nobody, since a filter excluding nothing would report success and
  hand the remote viewer a black screen. The discovery is an injected seam
  (`macVNCSetOwnApplicationDiscovery`, applications AND windows), so
  `tests/test_capture_exclusion.m` feeds it each of the three census states —
  including "we own windows and are still not listed", the one that would refute
  the design — without reaching ScreenCaptureKit.

## Key seams (dependency inversion)

- `vncServerStart(const MacVNCServerConfig *)` — immutable config **by value**;
  the core keeps a private copy. No ambient mutable globals in the public API.
- `macVNCInputSetContext(screen, layout)` — input module never reaches into
  server-core globals for geometry.
- `macVNCScreenCaptureFailureHandler` — function pointer so the core reports
  capture failures without depending on AppKit/UI.
- `macVNCCaptureAllowed` — the core asks whether it may touch capture and never
  reads TCC itself.
- `macVNCAuthenticatedClientsChangedHandler` — the core says only "the
  authenticated client count may have moved", never how far: notifications are
  raised on client threads, and two of them delivered out of order with a count
  attached could invent a connection that never happened. The reader hops to
  the main queue and asks `vncAuthenticatedClientsReceivingUpdates`, which is
  atomic and current. That is the NARROWER of the two client counts on purpose:
  it moves only after a client's first frames arrived, while
  `vncConnectedClients` moves at password-accept time because captures have to
  start before any frame can exist. A curtain raised on the earlier number
  would black the local screen out for up to the readiness timeout while the
  remote viewer still had a placeholder.
- `vncServerCopyPassword` — the password the RUNNING server authenticates
  against, whatever it was configured from. Curtain mode arms its escape hatch
  with THAT secret and no other: one read from defaults instead would arm the
  curtain with a password the server does not accept whenever it came from
  `MACVNC_PASSWORD_FILE`, i.e. a curtain nobody can type away. A password that would not fit the caller's buffer is refused rather
  than truncated, because a truncated secret is a different secret.
- `FrameMailbox` / `CompositeFramebuffer` callbacks — producers are agnostic to
  how frames are freed and how dirty regions are consumed.

## Tests

`ctest` runs 41 targets (the number is enforced: `architecture_doc` compares
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
  per-client state and BOTH client counts; `vncConnectedClients` /
  `vncAuthenticatedClientsReceivingUpdates` / `publishedServerPort` are
  `_Atomic`. The two counts differ by the first-frame wait, and each client's
  per-client state records which of them it was added to, so a viewer that
  leaves during that wait subtracts from exactly the ones it joined. Both
  counts move through one set of functions that the production paths AND the
  test hooks call, so `tests/test_client_counts.m` asserts the rules rather
  than a copy of them; `tests/test_curtain_controller.m` pins the other half,
  which count the wiring feeds the curtain. The narrow count moves when the
  wait ENDS, not when it succeeds - a timed-out wait still counts, because
  gating on success would disable curtain mode for viewers that are merely
  slow, and the controller's live-stream invariant covers the broken case.
- `passwordMutex` is a LEAF taken only around the `strdup`/`free`/`memcpy` of
  the installed password: the curtain reads it from the main thread
  (`vncServerCopyPassword`) while a start or stop may be replacing it, and
  `serverLifecycleMutex` - the other candidate - is held across client-thread
  joins for seconds. It is only ever nested INSIDE the lifecycle lock, never
  the reverse, and nothing is called while it is held.
- **MacVNCCaptureSession** holds ONE lock, and EVERY function takes it. It used
  to be only three, on the argument that the other readers run on client
  threads which `rfbShutdownServer(screen, TRUE)` joins before any writer runs.
  That argument was false and the counter-example ships: the capture keep-warm
  timer fires on `gCaptureStopQueue` — a queue nothing joins — and calls
  `macVNCCaptureSessionStopAndWait()` and `macVNCCaptureSessionCount()` after
  dropping `captureControlMutex`, so it can overlap the `Reset` inside
  `vncServerStopLocked` that nils and releases the list it is enumerating. The
  main thread is the other unjoined caller (`macVNCCaptureSessionSetSelfExcluded`
  and `macVNCCaptureSessionSelfExcluded`, the curtain's seams). So the rule is
  now the one with no per-caller reasoning to keep true: readers snapshot the
  list under the lock, which retains every stream for the call, and work on the
  snapshot; writers swap the pointer under the lock and release the old list
  outside it. The lock is a LEAF (taken under `serverLifecycleMutex`, never held
  while messaging a capturer) and is never held across
  `-[ScreenCapturer dealloc]`, whose bounded sample-queue drain would otherwise
  stall the main thread for seconds.
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
- **Image profile is imposed per frame, on purpose:** `displayHook` sets
  `cl->tightQualityLevel` and `cl->tightCompressLevel` from the configured
  profile before every framebuffer update. It OVERRIDES what the viewer asked
  for, because most viewers send their own level and a setting that only applied
  when they stayed silent would do nothing on real devices; the honest way to
  disagree is the `viewer` profile, which does not install the hook at all.
  LibVNCServer offers no hook after SetEncodings, so this is the only seam - the
  same `displayHook` that was deleted in `28b7b62` for having no purpose.
  Verified live: with the client requesting quality 7 in every run, bytes per
  megapixel followed OUR profile (level 0: 155 KB, level 5: 167 KB, lossless:
  205 KB).
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
