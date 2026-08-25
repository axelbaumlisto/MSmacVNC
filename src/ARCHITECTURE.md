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
                 │   MacVNCCompositor (frame → canvas, locking)  │
                 │   MacVNCCaptureSession (per-run streams)      │
                 │   MacVNCInput (kbd/ptr)  MacVNCPowerMgmt      │
                 │   MacVNCDisplayWake      ScreenCapturer (SCK) │
                 └───────────────┬──────────────────────────────┘
                                 │ function-pointer / block seams
                 ┌───────────────▼──────────────────────────────┐
   Pure logic    │ DisplayLayout · DisplaySelection              │
   (C, tested)   │ CompositeFramebuffer · MacVNCStatusText       │
                 │ MacVNCPermissionUI · MacVNCStartFailure       │
                 │ NetworkAccess · NetworkCIDR · NetworkInventory │
                 │ NetworkPolicyResolver · ReadinessPolicy        │
                 │ FrameMailbox · PointerState                    │
                 │ KeyboardModifierState · CaptureRate · RFBKeySym│
                 └───────────────────────────────────────────────┘
```

The core holds no permission policy: it asks through `macVNCCaptureAllowed`
(NULL = unrestricted). Reading TCC in the core would put the decision that can
raise macOS's own screen-recording dialog inside the file that starts the
server, and would make the "no permission, no capture" rule untestable.

## Module responsibilities

Pure C (each with a `tests/test_*.c`):
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
- **ReadinessPolicy** — first-frame timeout/promotion state machine, plus
  `macVNCReadinessNow()`, the one shared monotonic clock.
- **FrameMailbox** — thread-safe single-slot latest-frame handoff with
  injected release/activity callbacks.
- **PointerState / KeyboardModifierState** — input resolution state machines.
- **CaptureRate** — validate FPS, derive the frame interval.
- **MacVNCStatusText** — status-bar strings from observed state (a stopped
  server reports no clients whatever the counter holds).
- **MacVNCPermissionUI** — chips, hint, button title, and the
  `shouldStartServer` / `shouldShowPanel` decisions, from one snapshot.
- **MacVNCStartFailure** — what to say when the server does not come up.
  Silence on a real failure and a port-collision alert stacked over the
  permission panel are both wrong; the decision is pure and tested.

Objective-C glue:
- **AppDelegate** — status-bar UI, timers, server start/stop, permission flow;
  installs the capture-permission policy into the core.
- **MacVNCCompositor** — composites a captured frame into the shared canvas.
  Takes every client's `sendMutex` with `trylock` only: LibVNCServer holds it
  for the whole encode-and-write, so waiting would let one stalled viewer
  freeze the screen for all clients. A refused frame must be re-submitted, not
  dropped.
- **MacVNCCaptureSession** — the per-run set of `ScreenCapturer` streams;
  start/stop/count and a *shared* first-frame budget, so a two-monitor Mac does
  not make the client wait twice as long.
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
- **MacVNCPowerMgmt** — legacy IOPM dim/sleep control (`undim` is throttled).
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
- `FrameMailbox` / `CompositeFramebuffer` callbacks — producers are agnostic to
  how frames are freed and how dirty regions are consumed.

## Concurrency model

- `serverLifecycleMutex` serialises start/stop; `compositorMutex` guards the
  shared canvas; `clientLifecycleMutex` guards per-client state and the
  connected-client count; `vncConnectedClients` / `publishedServerPort` are
  `_Atomic`.
- **Lock order:** `compositorMutex` → per-client `sendMutex`
  (`lockCurrentClients` retains each client so it can't be freed mid-composite).
  `clientLifecycleMutex` is never taken while holding the compositor lock.
- **Teardown ordering** (`vncServerStopLocked`): `rfbShutdownServer(TRUE)` joins
  every client thread **before** capturers stop and before `macVNCInputShutdown`
  clears the injected context — so input/compositing callbacks can never touch
  freed objects.
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
