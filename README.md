# MSMacVNC

A native macOS VNC server based on [LibVNC/macVNC](https://github.com/LibVNC/macVNC) and [LibVNCServer](https://github.com/LibVNC/libvncserver).

This branch adds a single composite RFB desktop for all active displays, on-demand ScreenCaptureKit lifecycle, efficient tile updates, modern macOS input fixes, and network binding suitable for a private overlay such as Tailscale.

## Features

- Native Apple Silicon build.
- Screen capture through ScreenCaptureKit.
- One RFB desktop containing either one display or all active displays.
- Correct placement for displays with negative and vertically offset macOS coordinates.
- Black framebuffer gaps where no physical display exists.
- Per-display capture streams feeding one serialized composite framebuffer.
- 64×64 dirty-tile updates through LibVNCServer.
- Capture starts only after the first authenticated framebuffer request and stops after the last authenticated client disconnects.
- Near-zero idle CPU while the listener remains available.
- Mouse mapping across accepted composite display layouts.
- Correct legacy X11 Cyrillic and RFB Unicode keyboard input, including `ё`/`Ё`.
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

The server reads the existing app preferences and supports environment overrides:

| Variable | Meaning | Example |
|---|---|---|
| `MACVNC_LISTEN` | IPv4 address to bind. IPv6 is disabled when set. | Tailscale address |
| `MACVNC_PORT` | RFB port. | `5903` |
| `MACVNC_DISPLAY` | `-2`: all active displays; `-1`: primary; `0+`: enumerated display index. | `-2` |
| `MACVNC_PASSWORD_FILE` | UTF-8 file containing the VNC password. | `~/.config/macvnc/password` |

The configured password path is fail-closed: it must be a non-empty regular UTF-8 file owned by the current UID and inaccessible to group/others. Symlinks and special files are rejected.

```bash
chmod 600 ~/.config/macvnc/password
```

## Run from the build tree

```bash
MACVNC_LISTEN="<private-overlay-ip>" \
MACVNC_PORT=5903 \
MACVNC_DISPLAY=-2 \
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

Black-box tests cover:

- idle → first client → second client → last disconnect → idle lifecycle;
- pre-auth and authenticated rapid churn;
- fail-closed password-file configuration, including missing/empty/exposed/FIFO/symlink paths;
- composite RFB dimensions;
- real pixels from both displays;
- black inter-display gaps.

See [docs/TESTING.md](docs/TESTING.md).

## Architecture

The implementation separates layout, pixel composition, capture lifecycle, input mapping, and RFB orchestration. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Known limitations

- Display topology is read at server startup. Hot-plugging, mirroring, or rearranging displays requires a restart.
- Mixed-scale adjacent layouts whose native pixel rectangles overlap after logical-origin normalization are rejected rather than composited incorrectly.
- Composite width is padded with zero-filled black columns to a multiple of four for strict VNC viewer compatibility.
- The first automated framebuffer request can race asynchronous ScreenCaptureKit startup. Interactive clients normally hide this with authentication time; automated clients should wait for capture readiness before the first full request.
- The CLI process does not survive reboot unless a supervised service is configured.

## License

GPL-2.0. See [COPYING](COPYING).
