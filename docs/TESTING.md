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
- `capture_rate`: unset/empty 12 FPS default, valid values and `1..60` boundaries, malformed/out-of-range rejection, and integer ceiling conversion (`12 FPS → 84 ms`) for global per-client framebuffer deferral.
- `frame_mailbox`: latest-pending replacement and balanced ownership, one concurrent drain owner, no lost wakeup at the empty boundary, metadata ownership, and lifecycle quiescence.
- `readiness_policy`: deterministic one-total-deadline budget arithmetic, immediate readiness, one timeout transition, delayed recovery, and no repeated timeout/recovery diagnostics.
- `server_init_failure`: a compile-only capturer-initialization fault seam verifies the injected fault is consumed, `vncServerStart()` failure cleans lifecycle resources (including keyboard maps), reports port `-1`, leaves the authenticated count at zero, and tolerates concurrent/repeated stop. Hosts without an active display explicitly skip. The seam is absent from the production app target.

### Fail-closed configuration test

```bash
python3 tests/test_config_failclosed.py \
  --app "$PWD/build-arm64/macVNC.app/Contents/MacOS/macVNC" \
  --listen "<private-overlay-ip>" \
  --base-port 5920
```

Missing, empty, wrong-owner, group/other-readable, non-regular, or symlinked configured password paths must open no listener. A non-empty `MACVNC_CAPTURE_FPS` that is not a decimal integer in `1..60` must also open no listener. The automated test covers missing, empty, exposed mode, FIFO, symlink, and malformed/out-of-range FPS cases; owner validation is enforced by the same descriptor-based path.

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
3. First successful password check starts capture and waits for a non-black first framebuffer.
4. A valid auth response may disconnect immediately without reading `SecurityResult` or `ServerInit`, interleaved with a successful reconnect.
5. Second authenticated client reuses capture streams without duplicate starts.
6. After the first of two clients disconnects, the second receives another usable real frame and measured CPU remains above idle.
7. Disconnecting the last authenticated client stops capture and returns CPU to idle.
8. Rapid authenticated start/stop churn cannot leave capture running.
9. Logs contain post-auth start and last-authenticated-client stop events.

### Active shutdown test

```bash
python3 tests/test_active_shutdown.py \
  --app "$PWD/build-arm64/macVNC.app/Contents/MacOS/macVNC" \
  --password-file "$HOME/.config/macvnc/password" \
  --fixture tests/fixtures/dual-display-5552x2715.json \
  --port 5918 \
  --cycles 3
```

By default each cycle keeps both display captures active, sends a Cocoa terminate request to the exact PID, and requires the RFB client to observe closure, the capture-stop log to appear, and the process to exit 0. The disruptive pointer-motion variant is opt-in only: add both `--stress-pointer-input --allow-input-injection`. It moves the real macOS pointer with button mask zero, so it never clicks or drags, and must never be run in an interactive session without explicit approval.

### Cold first-frame readiness test

```bash
python3 tests/test_first_frame.py \
  --app "$PWD/build-arm64/macVNC.app/Contents/MacOS/macVNC" \
  --password-file "$HOME/.config/macvnc/password" \
  --fixture tests/fixtures/dual-display-5552x2715.json \
  --attempts 10
```

Every fresh process must return real content on its first full framebuffer request. With explicit fixture metadata, every named physical-display region must independently exceed its non-black threshold; without `--fixture`, the portable fallback asserts only aggregate real content. The successful password check starts capture and delays SecurityResult/ServerInit completion for at most one shared three-second deadline across all selected displays. The pure readiness-policy regression covers deterministic remaining-budget arithmetic and a frame arriving after the initial deadline: the client transitions from timed out to ready exactly once instead of remaining stale or logging on every framebuffer hook.

### Composite RFB test

```bash
python3 tests/test_rfb_multidisplay.py \
  --app "$PWD/build-arm64/macVNC.app/Contents/MacOS/macVNC" \
  --password-file "$HOME/.config/macvnc/password" \
  --fixture tests/fixtures/dual-display-5552x2715.json \
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

### Backpressure black-box test (controlled hardware/TCC fixture only)

```bash
python3 tests/test_backpressure.py \
  --app "$PWD/build-arm64/macVNC.app/Contents/MacOS/macVNC" \
  --password-file "$HOME/.config/macvnc/password" \
  --fixture tests/fixtures/dual-display-5552x2715.json \
  --listen "<private-overlay-ip>" \
  --port 5930 \
  --low-fps 3 \
  --duration 4 \
  --allow-input-injection
```

The script runs two fresh app processes: one with `MACVNC_CAPTURE_FPS` explicitly unset (therefore 12 FPS) and one at the requested low FPS. During continuous RFB pointer motion and incremental framebuffer requests it counts actual `FramebufferUpdate` messages, enforces the configured ceiling with declared tolerance/slack, samples RSS and bounds both median growth and total span, checks the exact final `PointerPos` and its cursor region become fresh, records updates during an idle interval, then requires new motion to deliver its exact `PointerPos` through the outstanding incremental request. Idle update count is measured rather than constrained because unrelated on-screen animation is not stopped by the test. It requires Screen Recording and Accessibility approval for the exact app signature and explicit matching fixture geometry. It posts real macOS pointer events and therefore fails closed unless `--allow-input-injection` is supplied. Never run it during an interactive session without explicit approval. It is intentionally not registered in CTest or generic GitHub-hosted CI.

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

For high-motion validation, keep both displays selected and confirm RSS reaches a plateau rather than growing with retained samples. After motion stops, current content should replace intermediate frames promptly, and disconnect/shutdown should wait for at most the processing frame plus latest pending frame per display. Capture is capped independently per display (12 FPS by default), while LibVNCServer defers/coalesces actual framebuffer sends globally per client across the one composite desktop using `ceil(1000 / FPS)` milliseconds (84 ms by default). Input processing and pointer defer behavior remain unchanged. Inspect logs for at most one readiness timeout and one recovery per affected client.

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
