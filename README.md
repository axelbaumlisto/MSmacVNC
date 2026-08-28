# MSMacVNC

A native macOS VNC server based on [LibVNC/macVNC](https://github.com/LibVNC/macVNC) and [LibVNCServer](https://github.com/LibVNC/libvncserver).

This branch adds a single composite RFB desktop for all active displays, on-demand ScreenCaptureKit lifecycle, efficient tile updates, modern macOS input fixes, and network binding suitable for a private overlay such as Tailscale.

## Features

- Native Apple Silicon build.
- Screen capture through ScreenCaptureKit.
- One RFB desktop containing either one display or all active displays.
- Correct placement for displays with negative and vertically offset macOS coordinates.
- Black framebuffer gaps where no physical display exists.
- Per-display capture streams feeding one serialized composite framebuffer, with a bounded latest-frame mailbox to prevent motion backlog.
- 64×64 dirty-tile updates through LibVNCServer, comparing only the advertised 24-bit BGR channels and normalizing the unused alpha byte.
- Capture starts after successful VNC password validation, shares one total three-second initial-readiness deadline across all selected displays, self-heals readiness if frames arrive late, and synchronously stops after the last authenticated client disconnects.
- Near-zero idle CPU while the listener remains available.
- Mouse mapping across accepted composite display layouts.
- Correct legacy X11 Cyrillic and RFB Unicode keyboard input, including `ё`/`Ё`.
- Deterministic Shift/Control/Option/Command/Fn state, one-shot mobile Fn auto-release, and modifier reset after the last client disconnects.
- System cursor captured by ScreenCaptureKit, avoiding flipped custom RichCursor rendering.
- VNC password authentication.
- Optional bind to a specific IPv4 address.

## Requirements

- macOS 13 or later. macOS 15/26 is recommended for the tested ScreenCaptureKit path.
- Xcode command-line tools.
- CMake.
- LibVNCServer 0.9.15 or later (required for joined client-thread shutdown semantics).
- `pycryptodome` for Python black-box tests.
- Accessibility and Screen Recording permissions for the macVNC binary/app bundle.

On Apple Silicon with Homebrew:

```bash
/opt/homebrew/bin/brew install cmake libvncserver
python3 -m pip install pycryptodome
```

## Build

```bash
cmake -S . -B build-arm64 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_PREFIX_PATH=/opt/homebrew/opt/libvncserver \
  -DBUILD_TESTING=ON
cmake --build build-arm64 -j
ctest --test-dir build-arm64 --output-on-failure
```

The bundle is created at:

```text
build-arm64/macVNC.app
```

## Configuration

The app stores normal settings in macOS preferences. Use **Preferences…** from the menu bar icon to configure:

- port;
- VNC password;
- listen mode: localhost, all interfaces, custom IPv4, or a selected active IPv4 network interface;
- encryption policy: allow unencrypted viewers, or require TLS;
- allowed client networks: checked active network rows plus manual IPv4/CIDR entries;
- explicit allow-all mode;
- **frame rate** and **image quality** (see below).

The network policy is IPv4-only in this version. The IPv6 listener is disabled in every mode until IPv6 allowlist semantics exist. Empty allowed-client lists are fail-closed unless **Allow all IPv4 clients** is explicitly checked.

Examples:

```text
127.0.0.1
192.168.100.0/24
100.100.242.110/32
```

Interfaces in `100.64.0.0/10` are labeled CGNAT/Tailscale-like, but the app does not call Tailscale or infer identity from that range. If you manually allow `100.64.0.0/10`, keep Tailscale ACLs as the primary security boundary.

### Frame rate and image quality

Both are measured settings, not preferences of taste. Numbers below come from
this repository's own instruments (`tests/measure_felt_latency.sh` and
`tests/reference_server.c`) on a two-display Mac; your link and content will
move the absolute values, not the ordering.

**Frame rate** is shared by every viewer: there is one ScreenCaptureKit stream
per display, so it cannot be per-connection.

| Setting | Delivered to a viewer | Server CPU |
|---|---|---|
| Battery saver — 8 fps | ~16 fps with two displays | lowest |
| Balanced — 15 fps | ~24 fps | low |
| **Smooth — 30 fps (default)** | **~33 fps, 30 ms average gap** | ~5.5 s per 15 s |
| Maximum — 60 fps | ~30 fps, worse worst case | highest |

60 fps is offered but measured no faster than 30 with worse tails, because the
limit is encode and transfer rather than capture.

**Image quality** is honestly a bandwidth control: across the whole JPEG range
the delivered frame rate and CPU barely move, while bandwidth spans 1.9 to
5.1 MB/s.

| Setting | Bandwidth | Fidelity (PSNR on text) |
|---|---|---|
| Follow the viewer's own setting | whatever the device asks for | — |
| Maximum — lossless, no JPEG | 5.7 MB/s, highest CPU | perfect |
| 7 — sharpest JPEG | 5.1 MB/s | 35.7 dB |
| 6 | 4.4 MB/s | 33.4 dB |
| **5 — balanced (default)** | **3.8 MB/s** | **31.5 dB** |
| 4 | 3.2 MB/s | 29.8 dB |
| 3 | 2.6 MB/s | 28.5 dB |
| 2 | 2.6 MB/s | 28.2 dB |
| 1 | 2.1 MB/s | 27.3 dB |
| 0 — smallest bandwidth | 1.9 MB/s | 25.4 dB |

Levels 8 and 9 exist in the VNC protocol and are deliberately NOT offered: each
sends MORE data than lossless while looking worse than lossless (level 9 costs
2.45x the bytes of lossless). The Tight compression level is not offered either
— levels 1 to 9 produce byte-identical output, and level 0 is 4.3x larger for
the same pixels.

macVNC applies the chosen level on top of what the viewer requests, because most
viewers send their own and a setting that only applied to silent viewers would
do nothing. Choose **Follow the viewer's own setting** to let each device decide
for itself.

### Encryption

macVNC always offers VeNCrypt/TLS alongside classic VNC authentication, but the
**viewer** chooses which to use — and in practice it chooses the unencrypted
one. That is not a setting we can flip by reordering: LibVNCServer inserts each
security handler at the head of its list and sends the list from the head, and
registers its own classic handler on the first connection, i.e. after ours. So
plain is always listed first, and refusing it is the only reliable lever.

| Setting | Effect |
|---|---|
| **Allow unencrypted connections (default)** | Both paths accepted; the viewer decides. Works with viewers that have no TLS support. |
| Require encryption (TLS) | Viewers that will not use TLS are refused. The refusal looks like a wrong password on the wire and is explicit in the log. |

The default is the compatible one deliberately: shipping "required" would lock
out every viewer without VeNCrypt support on an upgrade, which is a worse
failure than an unencrypted session on a trusted network. If macVNC is only
reachable over a VPN such as Tailscale, the transport is already encrypted and
this setting is a second layer.

Measured cost of TLS on the same 57.5 MB frame: **0.13 s of server CPU
unencrypted versus 0.35 s with TLS**, about 3x — worth knowing before requiring
it on a busy machine.

Environment overrides remain for debug/headless launches:

| Variable | Meaning | Example |
|---|---|---|
| `MACVNC_LISTEN` | IPv4 address to bind. Overrides GUI listen address when non-empty. | Tailscale address |
| `MACVNC_ALLOWED_CLIENTS` | IPv4/CIDR allowlist override. Empty value does not clear a non-empty GUI allowlist. | `100.64.0.0/10` |
| `MACVNC_PORT` | RFB port. | `5903` |
| `MACVNC_DISPLAY` | `-2`: all active displays; `-1`: primary; `0+`: enumerated display index. | `-2` |
| `MACVNC_PASSWORD_FILE` | UTF-8 file containing the VNC password. | `~/.config/macvnc/password` |
| `MACVNC_CAPTURE_FPS` | Integer capture rate for every selected display; allowed `1..60`, default `30`. Overrides the Preferences setting. | `30` |
| `MACVNC_IMAGE_PROFILE` | `viewer`, `lossless`, or a level `0`..`7`. Overrides the Preferences setting. | `5` |
| `MACVNC_ENCRYPTION` | `optional` or `required`. Overrides the Preferences setting. | `required` |

A stored frame rate or image profile that cannot be parsed falls back to the
default and logs it, because a hand-edited value must not make the Mac
unreachable. The environment variables are stricter: they are typed
deliberately, so an invalid one fails closed rather than being silently ignored.

A non-empty invalid `MACVNC_CAPTURE_FPS`, invalid bind address, invalid allowed-client list, or missing password fails closed and opens no listener. The configured password path is also fail-closed: it must be a non-empty regular UTF-8 file owned by the current UID and inaccessible to group/others. Symlinks and special files are rejected.

```bash
chmod 600 ~/.config/macvnc/password
```

## Run from the build tree

```bash
MACVNC_LISTEN="<private-overlay-ip>" \
MACVNC_PORT=5903 \
MACVNC_DISPLAY=-2 \
MACVNC_CAPTURE_FPS=12 \
MACVNC_PASSWORD_FILE="$HOME/.config/macvnc/password" \
nohup "$PWD/build-arm64/macVNC.app/Contents/MacOS/macVNC" \
  > /tmp/macvnc.log 2>&1 &
```

`MACVNC_DISPLAY=-2` exposes all active displays in one RFB `ServerInit`. Display rectangles retain the macOS arrangement. Areas not covered by a display remain black and ignore pointer input.

## macOS permissions

Enable both permissions for the exact binary/app signature being run:

1. **System Settings → Privacy & Security → Accessibility**
2. **System Settings → Privacy & Security → Screen & System Audio Recording**

Replacing an ad-hoc-signed binary can invalidate TCC approval. For repeatable deployments, use a stable signing identity before granting permissions.

## Security

Classic VNC authentication and RFB traffic are not a replacement for transport encryption.

- Bind only to a trusted private interface using `MACVNC_LISTEN`.
- Use Tailscale/WireGuard/another authenticated VPN.
- Restrict access with overlay-network ACLs.
- Do not expose the VNC port through router port forwarding.
- Use a dedicated password rather than a macOS or administrator password.

## Testing

Pure unit tests cover:

- RFB/X11 keysym to Unicode mapping.
- Multi-display layout and pointer coordinate transforms.
- Composite framebuffer placement, row padding, gaps, and dirty tiles.
- Pointer button-state handling across black gaps, including drag release.
- Strict capture-FPS parsing, bounded latest-frame mailbox replacement/concurrency/quiescence, shared readiness-deadline budgeting, delayed readiness transitions, and transactional capture-initialization failure cleanup.

Each display captures independently and retains at most one frame being processed plus one replaceable latest pending frame. Intermediate motion frames are dropped rather than queued FIFO, while ScreenCaptureKit itself uses `queueDepth=2`. LibVNCServer globally defers and coalesces framebuffer transmissions per client across all displays by `ceil(1000 / MACVNC_CAPTURE_FPS)` milliseconds (84 ms at the default 12 FPS); input processing and pointer defer behavior are unchanged.

Black-box tests cover:

- idle → first client → second client → last disconnect → idle lifecycle;
- pre-auth churn, immediate post-auth-response disconnect, and authenticated rapid reconnects;
- continued usable frames for the second client after the first disconnects;
- repeated active shutdown, with motion-only (never click/drag) pointer stress available only through two explicit input-injection safety flags;
- fail-closed password-file and capture-FPS configuration;
- composite RFB dimensions and fixture-scoped real pixels from both displays;
- black inter-display gaps;
- fixture-scoped update-rate, bounded short-run RSS median half-to-half growth and total sampled span, final freshness, and idle recovery at default and explicit low FPS.

See [docs/TESTING.md](docs/TESTING.md).

## Architecture

The implementation separates layout, pixel composition, capture lifecycle, input mapping, and RFB orchestration. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Known limitations

- Display topology is read at server startup. Hot-plugging, mirroring, or rearranging displays requires a restart.
- Mixed-scale adjacent layouts whose native pixel rectangles overlap after logical-origin normalization are rejected rather than composited incorrectly.
- Composite width is padded with zero-filled black columns to a multiple of four for strict VNC viewer compatibility.
- The CLI process does not survive reboot unless a supervised service is configured.

## License

GPL-2.0. See [COPYING](COPYING).
