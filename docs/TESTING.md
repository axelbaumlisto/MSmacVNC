# Testing

## Test layers

### Unit tests

```bash
ctest --test-dir build-arm64 --output-on-failure
```

Registered tests:

- `keysym_mapping`: ASCII, RFB Unicode, legacy X11 Cyrillic lower/upper, `ё`/`Ё`, unsupported non-BMP input.
- `display_layout`: negative origins, vertically offset displays, seams, gaps, order independence, overlap rejection, RFB size limits, pointer mapping.
- `compositor`: BGRA placement, padded source rows, alpha-only noise suppression, black gaps, unchanged frames, partial dirty tiles, isolation of unrelated pixels.
- `pointer_state`: valid positions, gap suppression, drag into gap, and release at the last valid position.
- `keyboard_modifiers`: left/right modifier tracking, macOS flag mapping, one-shot Fn auto-release, and reset.

### Fail-closed configuration test

```bash
python3 tests/test_config_failclosed.py \
  --app "$PWD/build-arm64/macVNC.app/Contents/MacOS/macVNC" \
  --listen "<private-overlay-ip>" \
  --base-port 5920
```

Missing, empty, wrong-owner, group/other-readable, non-regular, or symlinked configured password paths must open no listener. The automated test covers missing, empty, exposed mode, FIFO, and symlink cases; owner validation is enforced by the same descriptor-based path.

### Lifecycle black-box test

The lifecycle test launches an isolated server on a temporary port and verifies authenticated behavior:

```bash
python3 tests/test_lifecycle.py \
  --app "$PWD/build-arm64/macVNC.app/Contents/MacOS/macVNC" \
  --password-file "$HOME/.config/macvnc/password" \
  --listen "<private-overlay-ip>" \
  --port 5916 \
  --display -2 \
  --expected-width 5552 \
  --expected-height 2715
```

Acceptance gates:

1. Listener idle CPU is below 10%.
2. Pre-auth TCP/RFB churn starts no capture.
3. First authenticated framebuffer request starts capture and receives a non-black framebuffer.
4. Second authenticated client's framebuffer request does not create duplicate captures.
5. Disconnecting the first client keeps capture active for the second.
6. Disconnecting the last authenticated client stops capture and returns CPU to idle.
7. Rapid authenticated start/stop churn cannot leave capture running.
8. Logs contain post-auth start and last-authenticated-client stop events.

### Active shutdown test

```bash
python3 tests/test_active_shutdown.py \
  --app "$PWD/build-arm64/macVNC.app/Contents/MacOS/macVNC" \
  --password-file "$HOME/.config/macvnc/password" \
  --port 5918
```

This keeps both display captures active, sends a Cocoa terminate request to the exact PID, and requires client shutdown, synchronous ScreenCaptureKit quiescence, and process exit code 0.

### Composite RFB test

```bash
python3 tests/test_rfb_multidisplay.py \
  --app "$PWD/build-arm64/macVNC.app/Contents/MacOS/macVNC" \
  --password-file "$HOME/.config/macvnc/password" \
  --listen "<private-overlay-ip>" \
  --port 5917
```

For the documented two-display fixture, it verifies:

- one `ServerInit` reports aligned `5552×2715`;
- external display region is non-black;
- internal display region is non-black;
- upper-left and lower-right physical gaps are exactly black;
- one TCP/RFB endpoint is used.

Temporary test ports are closed when tests finish.

## Manual RealVNC E2E

Record the exact viewer device/version and verify:

1. Connect through the private overlay address and VNC password.
2. Confirm both physical displays are reachable by panning/zooming one desktop.
3. Confirm black areas match the macOS display arrangement rather than missing content.
4. Move and click the pointer on each display.
5. Confirm pointer input in black gaps causes no unintended click.
6. Type Latin and Russian text, including `ё` and `Ё`.
7. Press mobile Fn, type a normal key, and verify Fn is no longer latched; typing `F` afterwards must not toggle fullscreen.
8. Disconnect while a modifier is down and verify reconnect starts with clear modifier flags.
9. Disconnect and confirm server CPU returns near zero.
10. Reconnect and confirm both capture streams restart.

## Performance evidence

Do not compare implementations using different resolutions or workloads. A valid comparison fixes:

- framebuffer dimensions;
- client pixel format and encodings;
- visual workload;
- test duration;
- network path.

Measure separately:

- update FPS;
- input-to-frame latency (average, p50, p95);
- wire bitrate;
- compressed bytes per update;
- changed area and rectangle count;
- active and idle CPU;
- RSS;
- subjective mobile input quality.

## TCC note

An ad-hoc signature can change after rebuilding, invalidating Accessibility or Screen Recording approval. Run tests from the same stable signed path when possible. If a permission is stale, use System Settings or scoped `tccutil reset`—never edit the TCC database directly.
