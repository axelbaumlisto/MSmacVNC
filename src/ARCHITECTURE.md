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
                 ┌─────────────────────────────────────────────┐
   UI / glue     │ main.m → AppDelegate (status bar, lifecycle) │
   (Obj-C)       │   MacVNCPreferences · MacVNCPermissionsPanel │
                 │   MacVNCStartupConfig (defaults+env → config)│
                 │   MacVNCLoginItem · MacVNCPassword           │
                 └───────────────┬─────────────────────────────┘
                                 │ MacVNCServerConfig (by value)
                 ┌───────────────▼─────────────────────────────┐
   Server core   │ mac.m: ScreenInit, client lifecycle,         │
   (C / Obj-C)   │        compositing pump, start/stop           │
                 │   MacVNCInput (kbd/ptr)  MacVNCPowerMgmt       │
                 │   MacVNCDisplayWake      ScreenCapturer (SCK)  │
                 └───────────────┬─────────────────────────────┘
                                 │ function-pointer / block seams
                 ┌───────────────▼─────────────────────────────┐
   Pure logic    │ DisplayLayout · CompositeFramebuffer          │
   (C, tested)   │ NetworkAccess · NetworkCIDR · NetworkInventory│
                 │ NetworkPolicyResolver · ReadinessPolicy       │
                 │ FrameMailbox · PointerState                    │
                 │ KeyboardModifierState · CaptureRate · RFBKeySym│
                 └───────────────────────────────────────────────┘
```

## Module responsibilities

Pure C (each with a `tests/test_*.c`):
- **DisplayLayout** — build a non-overlapping composite layout; map a
  framebuffer point back to a global display coordinate.
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

Objective-C glue:
- **AppDelegate** — status-bar UI, timers, server start/stop, permission flow.
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

Release/notarization lives in `build/make_release.sh` (+ `build/entitlements.plist`):
Developer ID + hardened runtime + `com.apple.security.cs.disable-library-validation`
(required so the bundled Homebrew dylibs load for VNC DES auth).
