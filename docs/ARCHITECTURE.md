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
- Compares 64×64 tiles against the composite canvas.
- Copies only changed tiles.
- Reports dirty rectangles already offset into composite RFB coordinates.
- Never modifies pixels belonging to another display or a black gap.

### `ScreenCapturer`

Objective-C ScreenCaptureKit adapter.

- Owns one `SCStream` for one display.
- Serializes start/stop state on a private queue.
- Uses a monotonically increasing generation token so late asynchronous discovery/start callbacks cannot create orphan streams after start→stop→start churn.
- Captures BGRA at the display's active pixel dimensions.
- Includes the system cursor in the framebuffer.

### `RFBKeySym`

Pure C input conversion module.

- Converts RFB Unicode keysyms.
- Converts legacy X11 Cyrillic keysyms used by mobile VNC clients.
- Covers lower/upper Russian letters and `ё`/`Ё`.

### `mac.m`

System/RFB orchestration only.

- Enumerates and selects displays.
- Creates the layout and one zeroed composite framebuffer.
- Creates one `ScreenCapturer` per selected display.
- Serializes compositor access across capture callback queues.
- Locks LibVNCServer clients while modifying framebuffer tiles.
- Starts all captures on the first client and stops all captures after the last client.
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
  └─ first post-auth frame request → start every display capturer
N authenticated clients
  └─ additional frame request      → no additional capture streams
1 authenticated client
  └─ last disconnect               → stop every display capturer
0 authenticated clients            → listener remains, capture CPU returns near zero
```

A per-client state is counted only from LibVNCServer's post-auth `displayHook`; unauthenticated TCP/RFB clients cannot start capture. Client counting is atomic. Each capturer independently guards asynchronous ScreenCaptureKit discovery, start, stop, and output callbacks with its generation token.

## Concurrency

Each ScreenCaptureKit stream has its own serial callback queue. All callbacks enter one process-wide compositor mutex before modifying the shared canvas. LibVNCServer client send mutexes are held during tile copies and dirty-region publication, preventing clients from reading torn composite pixels.

## Pointer policy

A pointer position is hit-tested against half-open display rectangles:

- inside a display: map through that display's own pixel-to-logical scale and post to global macOS coordinates;
- on a seam: exactly one display owns the coordinate;
- inside a black gap: post no macOS pointer event;
- outside the RFB canvas: clamp to the RFB bounds, then apply the same hit test.
