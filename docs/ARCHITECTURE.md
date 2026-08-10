# Architecture

## Overview

MSMacVNC exposes one RFB desktop backed by one or more macOS displays:

```text
SCStream(display A) ─┐
                     ├─> serialized compositor ─> one LibVNCServer framebuffer
SCStream(display B) ─┘
```

Capture is active only while at least one VNC client is connected.

## Responsibilities

### `DisplayLayout`

Pure C geometry module.

- Normalizes negative macOS display origins into RFB coordinates.
- Computes the composite framebuffer dimensions.
- Stores each display's logical bounds, pixel size, and framebuffer offset.
- Maps RFB pointer coordinates back to global macOS logical coordinates using the selected display's own scale.
- Rejects invalid, overlapping, mixed-scale-incompatible, or RFB-dimension-overflow layouts instead of producing ambiguous pixels.
- Returns no target for black gaps between physical displays.

### `CompositeFramebuffer`

Pure C pixel module.

- Accepts one BGRA display frame at a time.
- Honors source row padding.
- Compares 64×64 tiles against the composite canvas using only BGR channels advertised by the 24-bit RFB depth.
- Ignores ScreenCaptureKit alpha-only noise and normalizes the unused alpha byte to zero.
- Copies only color-changed tiles.
- Reports dirty rectangles already offset into composite RFB coordinates.
- Never modifies pixels belonging to another display or a black gap.

### `ScreenCapturer`

Objective-C ScreenCaptureKit adapter.

- Owns one `SCStream` for one display.
- Serializes start/stop state on a private queue.
- Uses a monotonically increasing generation token so late asynchronous discovery/start callbacks cannot create orphan streams after start→stop→start churn.
- Captures 32BGRA at the display's active pixel dimensions and the immutable validated FPS supplied at startup (default 12).
- Configures ScreenCaptureKit with `queueDepth=2`.
- Admits frames through a lock-protected latest-frame mailbox: one sample may be processing while one pending sample is replaceable; intermediate pending samples are released immediately.
- Stores the source stream and generation with each sample, and validates both before handling and before marking first-frame readiness.
- Includes the system cursor in the framebuffer.

### `RFBKeySym`

Pure C input conversion module.

- Converts RFB Unicode keysyms.
- Converts legacy X11 Cyrillic keysyms used by mobile VNC clients.
- Covers lower/upper Russian letters and `ё`/`Ё`.

### `KeyboardModifierState`

Pure C modifier state machine.

- Tracks left/right Shift, Control, Meta, Alt, Level3, and Fn independently.
- Produces deterministic macOS Shift/Control/Option/Command/Fn flags for every event.
- Preserves the existing mobile mapping Meta→Option and Alt→Command.
- Treats mobile Fn as one-shot and auto-releases it after the next non-modifier key-up.
- Clears all modifiers when the last authenticated client disconnects.

### `mac.m`

System/RFB orchestration only.

- Enumerates and selects displays.
- Creates the layout and one zeroed composite framebuffer.
- Creates one `ScreenCapturer` per selected display.
- Serializes compositor access across capture callback queues.
- Locks LibVNCServer clients while modifying framebuffer tiles.
- Globally defers/coalesces framebuffer transmissions per client across all displays by `ceil(1000 / FPS)` milliseconds (84 ms at 12 FPS), without changing input processing or pointer deferral.
- Starts all captures on the first authenticated client and synchronously stops all captures after the last authenticated client.
- Routes keyboard and pointer events to macOS.

### `AppDelegate`

Configuration and status-bar lifecycle.

- Reads app defaults.
- Applies `MACVNC_*` environment overrides.
- Starts/stops the RFB server.
- Does not implement capture, layout, composition, or input conversion.

## Composite coordinates

macOS display bounds may have negative origins and vertical offsets. The layout subtracts the minimum logical X/Y origin to obtain non-negative RFB offsets.

For example:

```text
external: logical (0, 0),       pixels 3840×2160
internal: logical (-1710,1603), pixels 1710×1112
```

becomes:

```text
internal framebuffer rect: (0,1603)       1710×1112
external framebuffer rect: (1710,0)       3840×2160
logical display union:                      5550×2715
RFB framebuffer (4-pixel aligned):          5552×2715
```

The uncovered upper-left/lower-right regions and the two-column right alignment padding remain zero-filled black.

## Capture lifecycle

```text
0 authenticated clients
  └─ successful password check → start every display capturer
                              → wait for each first composited frame
                              → complete VNC authentication
N authenticated clients
  └─ additional password check → reuse ready capture streams
1 authenticated client
  └─ last disconnect           → stop every display capturer
0 authenticated clients        → listener remains, capture CPU returns near zero
```

A wrapper around LibVNCServer's password check starts capture only after the password has been validated, then blocks authentication completion while selected displays consume one shared three-second first-frame deadline. Each successive wait receives only the budget remaining from that one monotonic deadline; the bound does not multiply by display count. Invalid and pre-auth clients cannot start capture. Client counting is atomic. Each capturer independently guards asynchronous ScreenCaptureKit discovery, start, stop, output, and readiness callbacks with its generation token.

If the shared initial deadline expires, that client enters a timed-out readiness state and one warning is logged. Later framebuffer hooks query current-generation capturer readiness and promote the client after every selected display has composited a frame, logging one recovery transition. Framebuffer requests while still waiting do not emit repeated warnings.

## Concurrency

Each `ScreenCapturer` owns one serial ScreenCaptureKit sample-handler queue for its full lifetime and one serial mailbox-drain queue. Mailbox scheduling and empty/unschedule decisions use the same mutex, so a producer cannot lose a wakeup at the drain boundary. Admission and the single drain are covered by the capturer dispatch group. Stop invalidates the generation and enters the group before requesting definitive stream stop; after stop completion, an ordinary asynchronous sentinel on the serial sample-handler queue runs after callbacks already admitted to that queue and then leaves the group. Group wait therefore cannot return while an already queued callback may still touch state. Restart reuses that drained queue, and the queue is released only after final quiescence.

At most one frame per display enters composition at a time. All drains enter one process-wide compositor mutex before modifying the shared canvas. LibVNCServer client send mutexes are held during tile copies and dirty-region publication, preventing clients from reading torn composite pixels. Capture remains independently rate-limited per display, while actual RFB framebuffer sends are globally deferred/coalesced per client across the composite desktop. This bounds retained sample memory and stale-frame age without changing the one-RFB-desktop composition model.

## Pointer policy

A pointer position is hit-tested against half-open display rectangles:

- inside a display: map through that display's own pixel-to-logical scale and post to global macOS coordinates;
- on a seam: exactly one display owns the coordinate;
- inside a black gap: post no macOS pointer event;
- outside the RFB canvas: clamp to the RFB bounds, then apply the same hit test.
