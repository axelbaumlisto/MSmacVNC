# macVNC 0.3.78

## You can now require encryption

macVNC has always offered encrypted connections (VeNCrypt/TLS) alongside the
classic VNC login — but the **viewer** picks which to use, and in practice every
viewer picks the unencrypted one. Reordering does not fix it: LibVNCServer
builds its list of security types head-first and adds its own classic handler on
the first connection, i.e. after ours, so plain is always listed first. Refusing
it is the only reliable lever, and that is now a setting.

**Preferences → Encryption**

| Setting | Effect |
|---|---|
| **Allow unencrypted connections (default)** | Both paths accepted; the viewer decides. |
| Require encryption (TLS) | Viewers that will not use TLS are refused. |

The default stays compatible on purpose: shipping "required" would lock out
every viewer without TLS support on an upgrade, which is a worse failure than an
unencrypted session on a network you already trust. If macVNC is only reachable
over a VPN such as Tailscale, the transport is already encrypted and this is a
second layer.

A refused viewer sees what looks like a wrong password — a probe learns nothing
about the policy — while the log says exactly what happened, because locking
yourself out is the other way this can go wrong.

Measured cost, same 57.5 MB frame: **0.13 s of server CPU unencrypted versus
0.35 s with TLS**, about 3x. Worth knowing before requiring it.

# macVNC 0.3.77

## The remote screen is now three times faster, for half the CPU

Measured against the version from before this work, alternating runs on the
same machine and the same workload:

| | before | after |
|---|---|---|
| frames delivered to a viewer | 7.8 /s | 28.7 /s |
| average gap between frames | 129 ms | 35 ms |
| p99 gap | 174 ms | 57 ms |
| worst gap | 183 ms | 89 ms |
| server CPU per 15 s | 4.32 s | 2.23 s |

The earlier release made compositing four times cheaper without making the
screen feel faster. Measuring what a viewer actually experiences showed why:
compositing was 3 ms of a 140 ms budget, and the other 137 ms were two
deliberate delays stacked on top of each other. Captures ran at 12 frames per
second, and each update was then held for another 84 ms - a value derived from
the capture rate itself.

Both are now settings, with defaults chosen from measurement:

- the hold is a fixed 10 ms coalescing window, just long enough to let one
  captured frame's tiles travel together. It is never zero: at zero, updates
  stop batching and the worst case explodes to over two seconds.
- captures default to 30 per second. 60 was measured and delivers no more
  frames with worse worst-cases, because the limit is encode and transfer.

## Frame rate and image quality in Preferences

Two new popups. Both defaults are the measured best, and every alternative is
one click away.

**Frame rate** - Battery saver 8, Balanced 15, **Smooth 30 (default)**,
Maximum 60. It is shared by every viewer, because there is one screen capture
per display no matter how many people are connected.

**Image quality** - Follow the viewer, Maximum (lossless), then 7 down to 0,
with **5** as the default. This is honestly a bandwidth control: across the
whole JPEG range the frame rate and CPU barely move while bandwidth spans
1.9 to 5.1 MB/s.

Two things are deliberately NOT offered, because measurement showed them to be
traps rather than choices:

- **Quality levels 8 and 9.** Each sends MORE data than lossless while looking
  worse than lossless - level 9 costs 2.45x the bytes for a picture that is
  still lossy. If you want the best possible image, "Maximum - lossless" is
  both better and cheaper.
- **The compression level.** Levels 1 through 9 produce byte-identical output;
  only level 0 differs, by being 4.3x larger for the same pixels.

macVNC applies your chosen level on top of what the viewer asks for, since most
viewers send their own and a setting that only applied to silent viewers would
do nothing. "Follow the viewer's own setting" is there for the opposite choice.

## Fixes

- A stored frame rate or image quality that cannot be read falls back to the
  default and says so in the log, instead of preventing the server from
  starting: a mistyped setting must not make the Mac unreachable.

# macVNC 0.3.75

## The remote screen paints roughly six times cheaper

Measured with a client attached and two displays streaming, before and after,
in the same conditions:

| | before | after |
|---|---|---|
| composite, average | 44.22 ms | 3.01 ms |
| composite, worst | 536 ms | 14.8 ms |
| app CPU while streaming | ~29% | ~5% |

Two separate causes, both measured before anything was changed.

- **The pixel loops worked one byte at a time.** Comparing and copying went
  three loads and three stores per pixel, because the fourth byte is alpha and
  VNC's 24-bit depth ignores it. They now work on whole pixels with alpha
  masked out. A full-frame sweep dropped from 10.05 ms to 3.30 ms.
- **macOS was already telling us what changed, and we ignored it.**
  ScreenCaptureKit reports the rectangles it repainted; the server re-scanned
  all 29.5 MB of every frame to rediscover them. It now reads that metadata:
  588 of 600 live frames composited from a hint.

  The hint is never trusted blindly, because being wrong about it would leave
  part of your screen stale: every hinted tile is still compared before being
  copied, rectangles are clamped into the frame, anything unexpected means
  "scan everything", and each display is swept in full every five seconds
  regardless. Audited live under load - 500 hinted frames, 61 225 tiles - with
  zero tiles missed.

A NEON implementation was tried and rejected: at ~25 GB/s the loop is limited
by memory bandwidth, not arithmetic, so wider registers bought nothing worth
the architecture-specific code.

## The placeholder checkerboard on connect is gone

A viewer shows its own "no data" pattern when it is let in before any pixels
exist. The server holds authentication back until every display has produced a
frame - the budget for that was 3 seconds, set when captures were always warm.
Cold starts measure 1.3-2.1 s, and once power assertions became per-session the
panel could be asleep, so waking it ate the rest of the margin.

The budget is now 8 seconds, and it is a ceiling rather than a delay: a warm
reconnect still costs 0.00 s. A capture FAILURE now ends the wait immediately
instead of burning the whole budget on a frame that is never coming.

## Fixes

- Every encrypted (TLS) connection leaked a small block of memory that
  LibVNCServer allocates and never frees. Certificate paths are also copied
  once per process instead of once per connection.
- Two viewers connecting at once no longer starve each other's first paint.

# macVNC 0.3.66

## Six adversarial review rounds applied to the whole codebase

- **The machine's sleep settings are never touched again.** Earlier versions saved the
  global Energy Saver timers and wrote zeros over them to keep the Mac awake; a crash,
  a force-quit, or the app's own Restart could leave the Mac on "never sleep" forever.
  The server now holds ordinary per-process power assertions (system sleep + display
  sleep), created when the first viewer authenticates and released when the last one
  disconnects - an idle listener costs nothing, and the kernel cleans up on any exit.
- **A stalled viewer can no longer freeze the screen for others.** The compositor takes
  each client's send lock with a bounded trylock and re-submits declined frames, so one
  congested or hostile connection cannot block everybody's updates.
- **A user's Start request can no longer be silently swallowed** by an in-flight stop:
  all server lifecycle work runs on one serial queue.
- **Multi-display permission failure shows one alert, not N.** Capture-failure
  notifications are stamped with the server run and latched; duplicates from the same
  run and stale ones from a previous run are ignored.
- **The first frame after authentication is guaranteed bounded, not black.**
- **Preferences round-trips preserve every entry byte-identically**, and auto-added
  CIDRs are tracked separately from hand-typed ones (no more disappearing user entries).
- **Significant internal decomposition** (compositor, capture session, power management,
  allowlist planning, permission UI, relauncher, status text, input context) with the
  architecture documented in `src/ARCHITECTURE.md` and mechanically guarded: a test
  fails if the document drifts from the source, if the server core regains a
  ScreenCaptureKit dependency, or if any test would run with assertions compiled out.
- **29 automated tests**, each new assertion mutation-checked (verified to fail against
  a deliberately broken implementation).

## Validation

- Release build: passed. clang static analyzer: 0 warnings on all touched files.
- CTest: 29/29 passed. Reference libvncclient: AUTH_OK, composite 5552x2715,
  wrong password rejected. Leaks: 0.
- Power assertions verified live: idle listener holds none, an authenticated session
  holds system-sleep and display-sleep, disconnect releases both, kill -9 drops both.

# macVNC 0.3.23

## Regression fixes in the 0.3.19–0.3.22 changes (found by review of the new code itself)

- **Frames are no longer dropped when a client is busy.** 0.3.21 replaced the blocking
  per-client send lock with a trylock to fix a real freeze, but simply discarded the frame
  on contention. Since ScreenCaptureKit only delivers frames when content changes, the last
  frame of a change burst could be lost permanently — leaving viewers on a stale screen with
  no further updates. The capture handler now reports whether the frame was composited, and
  a declined frame is re-submitted and retried shortly instead of dropped.
- **Preferences no longer deletes hand-typed allowlist entries.** The “manual entries”
  computation subtracted every visible interface preset, so a user-typed CIDR that happened
  to match another interface’s preset vanished on an unrelated save — a possible remote
  lockout. Only entries this app actually auto-added (tracked in `autoAllowedClients`) are
  subtracted now.
- **Selecting a point-to-point (VPN) interface no longer produces an allowlist that admits
  nobody.** Such an interface’s “network” is the host’s own /32; it is no longer auto-added,
  and saving a policy with no allowed clients is refused with an explanation.
- **The 8-byte password warning now measures bytes, not characters.** DES truncates bytes,
  so a short non-ASCII password (accents, emoji) could still be silently cut.
- **A `/0` allowlist is now labelled “allow all”.** The status line inferred the label from
  the access mode, which stayed `allowlist` for a confirmed `0.0.0.0/0` — exactly the kind of
  false restriction claim 0.3.22 set out to remove. It now reflects the effective policy.
- **A stale capture failure can no longer kill a freshly restarted server.** With one capturer
  per display, several failure notifications could queue behind a modal and fire after the
  user had already recovered. Notifications now carry a server generation and stale ones are
  ignored; the non-permission path also no longer clears a latch it did not set.

## Validation

- Release build: passed. clang static analyzer: 0 warnings.
- CTest: 17/17 passed. Reference libvncclient: AUTH_OK, composite 5552x2715.
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.24

## Fixes the “grant permission → restart → hang” loop

0.3.23 was withdrawn: after replacing the bundle, macOS re-asks for Screen Recording, and
the app could then get stuck in an inescapable permission loop. Root causes, all fixed:

- **The capture-failure latch outlived its run.** One `-3801` denial set a process-global
  “Screen Recording missing” flag that nothing cleared, so even after the user granted the
  permission the check still answered “not granted”, the gate kept demanding a restart, and
  the restart re-latched on its own first failure. The latch now describes only the previous
  attempt and is cleared at the start of every start attempt.
- **Stopping the server could wedge the main thread forever.** `stopCaptureAndWait` waited on
  in-flight ScreenCaptureKit work with no timeout, and that work can stay pending behind the
  system permission prompt — freezing the menu bar, including the buttons needed to recover.
  The wait is now bounded (5 s) and shutdown continues regardless.
- **The capture-failure handler no longer stops the server on the main thread**; it hops to a
  background queue and returns to the main queue only for the UI.
- Frame retry on client contention is now a bounded in-place retry (~120 ms) instead of the
  mailbox re-submit used in 0.3.23, which broke the drain’s scheduling accounting.

## Validation

- Release build passed; clang static analyzer: 0 warnings; CTest 17/17.
- After a capture denial the process stays responsive and terminates in ~1 s (previously it
  could hang indefinitely).
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.22

## Truthful status & real start failures

- **The menu bar and “Copy VNC Address” now report what the RUNNING server actually applied**, not the saved preferences. Previously they read `NSUserDefaults`, so after changing settings without restarting — or when launching with `MACVNC_LISTEN` / `MACVNC_ALLOWED_CLIENTS` overrides as the README documents — macVNC could display `Running • 127.0.0.1:5903 • allowlist` while actually listening on a tailnet address, and copy a useless `vnc://127.0.0.1` URL. Claiming a network restriction that is not in effect is security-relevant. New `vncServerCopyActiveBindAddress()` / `vncServerActiveAccessMode()` expose the live values.
- **A failed bind is no longer reported as “Running”.** `rfbInitServer()` does not return bind errors, so a port collision (macOS Screen Sharing on 5900, or a second macVNC instance) left the app claiming to run on a port served by someone else — with a different auth and allowlist policy. The listen socket is now verified, and the user gets an explicit “port already in use” alert. Verified by holding the port and confirming the refusal.
- **The allowlist no longer accumulates every network the Mac has ever joined.** Auto-generated interface CIDRs became indistinguishable from hand-typed entries once that network disappeared, so they were re-persisted forever. Auto-added entries are now recorded separately (`autoAllowedClients`) and stale ones are dropped on the next save.

## Validation

- Release build: passed. clang static analyzer: 0 warnings.
- CTest: 17/17 passed.
- Bind-collision behaviour verified end-to-end; reference libvncclient auth: AUTH_OK, composite 5552x2715.
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.21

## Critical: release tooling is now version-controlled

- `make_release.sh` and `entitlements.plist` lived in `build/`, which `.gitignore` excluded — they were **never committed**. A routine `rm -rf build` (or a fresh clone) destroyed the signing recipe irrecoverably, including the two hard-won invariants it encodes (realpath dylib bundling; the `disable-library-validation` entitlement required for VNC DES auth). Moved to a tracked `packaging/` directory.

## Reliability / availability fixes

- **One stalled client no longer freezes every client.** The compositor took each client's `sendMutex` with a blocking lock while holding the compositor lock; since LibVNCServer holds that mutex for the entire encode+socket write, a single viewer that stopped reading (suspended laptop, dead link, or a hostile peer stalling TCP) froze the screen for all co-viewers indefinitely, and could also wedge capture teardown. Locking is now non-blocking: a busy client simply causes that frame to be skipped and retried. `maxClientWait` is also bounded so a dead client gets dropped.
- **A capture error is no longer permanently misdiagnosed as “no Screen Recording permission”.** Any ScreenCaptureKit failure (e.g. a display being unplugged) latched a process-global “permission missing” flag that nothing could clear, killing the session with a false diagnosis and no recovery. The failure handler now receives the error class and only latches on a genuine TCC denial (`SCStreamErrorUserDeclined` / `MissingEntitlements`); other failures clear the latch and report a recoverable error.
- **The permissions gate is no longer a dead end.** Choosing “Preferences” on the permission panel previously left the app with no way to ever start the server again. That branch now returns to the gate, and a permanent **Start Server** menu item was added (it also clears a stale capture-failure latch).

## Validation

- Release build: passed. clang static analyzer: 0 warnings.
- CTest: 17/17 passed.
- A/B verified that the non-blocking compositor change does not affect frame delivery (frame capture in a shell-launched build is limited by TCC, not by this change; the GUI-launched instance streams normally).
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.20

## Security fixes (found by an adversarial security review)

- **CGNAT interface no longer silently widens the allowlist.** Selecting an interface that
  merely *has* a CGNAT (100.64.0.0/10) address — e.g. a carrier/campus LAN — previously
  replaced its real subnet with the whole `100.64.0.0/10` range (~4.2M addresses) and
  labelled it "Tailscale clients". The broad tailnet preset now applies only to an actual
  point-to-point tailnet interface (`utunN`, /32); a CGNAT address on a normal broadcast
  interface keeps its true subnet and is labelled honestly. Added the missing regression
  test for that case.
- **"Allow all" confirmation is now semantic, not a substring match.** Any `/0` prefix
  (e.g. `10.0.0.0/0`) matches every IPv4 client but previously bypassed the warning, which
  only looked for the literal `0.0.0.0/0`. The gate now parses the list and uses
  `macVNCNetworkAccessContainsAllowAll()` (which existed but was unused).
- **The 8-character VNC password limit is now surfaced.** RFB's DES auth derives its key
  from only the first 8 characters, so a longer password added no entropy and rotating only
  its tail did not change the credential — silently. Preferences now warns explicitly on
  save (with a tooltip on the field).

## Other fixes

- Fixed a latent teardown self-deadlock: `ScreenCapturer -dealloc` could run on its own
  sample-handler queue (when GCD dropped the last block-captured reference there) and
  `dispatch_sync` to that same serial queue. It now detects that case via a queue-specific
  key and skips the redundant drain.

## Validation

- Release build: passed. clang static analyzer: 0 warnings.
- CTest: 17/17 passed, including the new CGNAT-on-broadcast-interface regression test.
- Reference libvncclient auth: AUTH_OK, composite 5552x2715.
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.19

## Highlights

- Fixed a real startup crash found by an adversarial review: `keyboardInit` dereferenced `kTISPropertyUnicodeKeyLayoutData` without a NULL check. That property is NULL for input sources without uchr data (e.g. CJK/handwriting IMEs), so a user whose active input source was such an IME crashed on launch before the listener opened. Now guarded — startup fails cleanly with a clear message instead of crashing.
- Fixed latent UB in the same loop: `UCKeyTranslate` may set `realLength = 0` and leave `chars[0]` unwritten; the code now skips those keycodes instead of reading an uninitialized `UniChar` (which could inject a bogus char→keycode mapping).

## Validation

- Release build: passed.
- clang static analyzer: 0 warnings across changed Objective-C modules.
- CTest: 17/17 passed (lsof-based `client_allowlist` skipped on this host; listener + auth verified directly: AUTH_OK, composite 5552x2715).
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.18

## Highlights

- Closed the last two cosmetic review nits (codebase now converged/clean):
  - `MacVNCPowerMgmt undim()` consumes its 1s throttle window only after confirming the module is initialised, so an uninitialised/failed call no longer blocks the next nudge.
  - `MacVNCPreferences` form layout uses a named grid (row/column constants) instead of scattered magic `NSMakeRect` numbers.

## Validation

- Release build: passed.
- clang static analyzer: 0 warnings across changed Objective-C modules.
- CTest: 17/17 passed (lsof-based `client_allowlist` skipped on this host; listener + auth verified directly: AUTH_OK, composite 5552x2715).
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.17

## Highlights

- Final polish from a convergence-confirming blind review:
  - **UX fix:** an empty/unset password now yields an explicit configuration error in `MacVNCStartupConfig` (surfaced as a dialog) instead of failing silently to “Not running”. Added a unit-test case.
  - **Logging accuracy:** `clientGone` now reports the authoritative connected-client count under the lock for un-counted (never-authenticated) clients.
  - **DRY:** `MacVNCPowerMgmt` dim/sleep save+restore collapsed from four near-identical functions into two key-parameterized helpers.

## Validation

- Release build: passed.
- clang static analyzer: 0 warnings across changed Objective-C modules.
- CTest: 17/17 passed (lsof-based `client_allowlist` skipped on this host; listener + auth verified directly: AUTH_OK, composite 5552x2715).
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.16

## Highlights

- Closed the remaining clean-code refinements from an independent blind re-scoring pass:
  - **DIP:** replaced the mutable `extern preventDimming/preventSleep` globals in `MacVNCPowerMgmt.h` with an explicit `macVNCSetPowerPolicy()` setter (config, not ambient state).
  - **SRP/KISS:** extracted the Preferences form construction into `-buildFormForPort:...` so `-runModal` no longer mixes view building with model decode + persistence.
  - **DRY:** loopback address now flows from one source — new `MacVNCLoopbackIPv4` (derived from the `MACVNC_LOOPBACK_IPV4` C macro) used by AppDelegate defaults, Preferences, and NetworkInventory; Fn keysym/keycode named (`MACVNC_KEYSYM_FN`/`MACVNC_KEYCODE_FN`).
  - **KISS:** `macVNCReadSecurePasswordFile` uses a single `goto fail` cleanup instead of repeating close/free across five validation branches.
  - Fixed a stale header doc in `MacVNCStartupConfig.h` (removed the mention of a `passwordFileReader` seam the API never exposed).

## Validation

- Release build: passed.
- clang static analyzer: 0 warnings across changed Objective-C modules.
- CTest: 17/17 passed (lsof-based `client_allowlist` skipped on this host; listener + auth verified directly: AUTH_OK, composite 5552x2715).
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.15

## Highlights

- Completed the full SOLID/DRY/KISS scoring-review TOP-10 punch list:
  1. `MacVNCPowerMgmt` — fixed resource leak + mutex-init UB on `dimmingInit` intermediate error paths (single rollback via `releasePowerResources` + `pthread_mutex_destroy`).
  2. Wired the previously-dead `allowAllConfirmed` path: confirming the 0.0.0.0/0 warning now sets ALLOW_ALL_CONFIRMED so mode + status label reflect reality.
  3. Throttled `undim()` to at most once/second (was 3 IOKit syscalls under a lock on every keystroke/mouse-move).
  4. `MacVNCDisplayWake` now reuses one user-activity assertion ID and releases it (per Apple guidance) instead of leaking a fresh one per wake.
  5. Split the ~190-line `MacVNCPreferences -runModal` — extracted pure model helpers (`macVNCManualAllowedText`, selection/allowlist assembly) out of the view builder.
  6. Replaced magic listen-popup tags (1/2/1000) with named constants shared by build + save paths.
  7. Network-row dictionary keys are now shared `MacVNCRowKey*` constants (single source of truth for producer + consumer; no more typo-masking).
  8. `specialKeyMap` converted from fragile pair-stride `int[]` to a typed `{sym, code}` struct array.
  9. `main.m` autoreleases the app delegate (balances the one unbalanced MRC alloc).
  10. Added `src/ARCHITECTURE.md` documenting the pure-C-core ↔ ObjC-glue split, seams, and concurrency/lock model.

## Validation

- Release build: passed.
- clang static analyzer: 0 warnings across changed Objective-C modules.
- CTest: 17/17 passed (lsof-based `client_allowlist` skipped on this host; listener + auth verified directly: AUTH_OK, composite 5552x2715).
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.14

## Highlights

- Finished the optional areview punch-list (the “tails”):
  - **Login-item extracted:** new `MacVNCLoginItem` owns SMAppService / LaunchAgent start-at-login; AppDelegate just delegates.
  - **Startup config extracted:** new `MacVNCStartupConfig` is a pure, unit-tested builder that turns NSUserDefaults + environment into a `MacVNCServerConfig` (owns its backing storage). AppDelegate `startServer` shrank to a few lines; added `test_startup_config` (4 cases).
  - **Cross-language DRY:** shared `MacVNCListenModeNames.h` C macros are now the single source of truth for the listen-mode strings and loopback address, consumed by both `NetworkPolicyResolver` (C) and `MacVNCListenMode` (ObjC); `test_listen_mode` asserts they stay in sync.
  - AppDelegate.m: 494 → 378 lines.

## Validation

- Release build: passed.
- clang static analyzer: 0 warnings across changed Objective-C modules.
- CTest: 17/17 passed (lsof-based `client_allowlist` skipped on this host's unreliable lsof; listener + auth verified directly: AUTH_OK, composite 5552x2715).
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.13

## Highlights

- Second “ideal code” blind areview round (3 critics, 9/9/9, no blockers). Fixed every remaining item:
  - **IOKit resource leak:** `MacVNCPowerMgmt` now closes the `io_connect_t` and deallocates the mach port on shutdown, is idempotent across restarts, and destroys its mutex (no re-init UB).
  - **Encapsulation:** `rfbScreen` and `frameBufferOne` are now `static` (were external linkage but file-local).
  - **Robustness:** keyboard-layout name printed via a safe buffer (no `printf("%s", NULL)` from `CFStringGetCStringPtr`); `rfbScreen->thisHost` explicitly NUL-terminated.
  - **Consistency:** capture-failure flag is `_Atomic` (was `volatile BOOL`).
  - **Security:** the in-memory VNC password is now zeroized and freed on server stop (and on restart), not left resident for the process lifetime.

## Validation

- Release build: passed.
- clang static analyzer: 0 warnings across changed Objective-C modules.
- CTest: 16/16 passed (the lsof-based `client_allowlist` harness is unreliable on this host's network stack; server listener + auth verified directly: AUTH_OK, composite 5552x2715).
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.12

## Highlights

- Addressed every finding from a 3-critic “ideal code” blind areview (scores 8-9/10, no blockers) plus a memory-safety pass:
  - **Config struct:** `vncServerStart(const MacVNCServerConfig *)` replaces five ambient mutable globals (viewOnly/displayNumber/listenAddress/allowedClients/accessMode). AppDelegate now forwards the resolved policy as an immutable value object; the server keeps a private copy. Mirrors the clean `macVNCInputSetContext` seam.
  - **DRY:** single `macVNCReadinessNow()` clock in ReadinessPolicy (removed two identical `monotonicNanoseconds`); MacVNCPassword reuses `MacVNCKeyPassword`/`MacVNCBundleID` instead of re-hardcoding `@"rfbPassword"` and the bundle id.
  - **Contract fix:** mac.h no longer claims `password==NULL disables auth` (it is mandatory).
  - **Encapsulation:** ScreenCapturer private ivars moved out of the public header; `newClient`/`clientGone` made `static`.
  - **Memory safety:** fixed a real `_stream` leak in ScreenCapturer -dealloc; hardened the MACVNC_PASSWORD_FILE invalid-UTF-8 path (explicit free); PtrAddEvent now null-guards the injected context and writes cursorX/Y under the pointer mutex; permissions-panel observer removed symmetrically in runModal.

## Validation

- Release build: passed.
- clang static analyzer: 0 warnings across all Objective-C modules.
- CTest: 17/17 passed.
- Reference libvncclient auth: AUTH_OK, composite 5552x2715.
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.11

## Highlights

- Zero-exceptions clean-code pass — finished every deferred item:
  - Extracted all keyboard + pointer input from `mac.m` into a new `MacVNCInput` module (owns the CGEventSource, keymaps, input mutexes and state; screen/layout injected via `macVNCInputSetContext`). `mac.m` 1030 → 644 lines and no longer holds any input globals.
  - Removed the `#define kKey*` alias shim in `AppDelegate.m`; call sites now use the canonical `MacVNC*` defaults-key symbols directly.
  - Dropped the now-unused Carbon include from `mac.m`; refreshed its file header.
  - Added `test_input_context` unit test for the injectable input context.

## Validation

- Release build: passed.
- CTest: 17/17 passed.
- Reference libvncclient auth: AUTH_OK, composite 5552x2715 (both displays).
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.10

## Highlights

- Post-review cleanup (3-critic blind areview, all non-blocking findings addressed):
  - Fixed stale header docs in `MacVNCDisplayWake.h` / `MacVNCPowerMgmt.h` (they described a persistent NoDisplaySleep assertion that was removed; wake is now a one-shot user-activity nudge only).
  - Removed dead imports in `AppDelegate.m` (NetworkAccess/NetworkCIDR/NetworkInventory).
  - Removed orphaned IOPM includes in `mac.m`.
  - DRY: extracted `macVNCTrimmedNonEmptyLines()` helper in `MacVNCPreferences.m` (was duplicated twice).
- Confirmed by review: display wake takes only the caffeinate *principle* (wake-on-demand), not persistent screen holding. Intended: an idle passive/view-only client may let the display sleep.

## Validation

- Release build: passed.
- CTest: 16/16 passed.
- 3 independent code critics: 8/10, 7/10, 8/10, CONDITIONAL GO; no code defects, only the doc/cleanup items now fixed.

# macVNC 0.3.9

## Highlights

- DRY: removed scattered magic listen-mode strings ("localhost"/"all"/"custom"/"selected") and duplicated bind-host resolution.
- New `MacVNCListenMode` module is the single source of truth for mode constants and `macVNCBindHostForMode()`, with unit tests.

## Validation

- Release build: passed.
- CTest: 16/16 passed (added listen_mode).
- Reference libvncclient auth: AUTH_OK, composite 5552x2715.
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.8

## Highlights

- Removed the built-in "caffeinate" behavior: macVNC no longer holds a persistent NoDisplaySleep power assertion.
- Display wake is now KISS: on start and on client connect it only declares local user activity (a one-shot nudge that lights up a sleeping/dimmed screen), without forcing the display to stay awake indefinitely.

## Validation

- Release build: passed.
- CTest: 15/15 passed.
- Verified: no persistent NoDisplaySleep assertion is held by the process; UserIsActive nudge on connect.

# macVNC 0.3.7

## Highlights

- Further SOLID/DRY/KISS refactor (no behavior change): extracted the legacy IOPM screen dim/sleep control into `MacVNCPowerMgmt`.
- `mac.m` reduced from 1226 → 1030 lines; the remaining code is the cohesive server/capture/input core.

## Validation

- Release build: passed.
- CTest: 15/15 passed.
- Reference libvncclient auth: AUTH_OK, composite 5552x2715 (both displays).
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.6

## Highlights

- Multi-monitor: default capture is now all displays (`displayNumber = -2`), so a second monitor is no longer "lost" in the remote session (composited into one framebuffer).
- More SOLID/DRY/KISS refactor (no behavior change):
  - `MacVNCDefaultsKeys` — single source of truth for NSUserDefaults keys / bundle id / default port.
  - `MacVNCNetworkRows` — active-interface enumeration extracted from AppDelegate.
  - `MacVNCPreferences` — the entire Preferences window moved out of AppDelegate.
- `AppDelegate.m` reduced from 1169 → 500 lines; concerns now split across focused units.

## Validation

- Release build: passed.
- CTest: 15/15 passed.
- Reference libvncclient auth: AUTH_OK, composite 5552x2715 (both displays).
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.5

## Highlights

- Internal refactor for SOLID/DRY/KISS (no behavior change):
  - `MacVNCPassword` — single source of truth for password load/store/file read with one trim helper.
  - `MacVNCPermissionsPanel` — the startup permission chip panel moved out of AppDelegate.
  - `MacVNCDisplayWake` — display wake + NoDisplaySleep assertion extracted from mac.m.
- `AppDelegate.m` reduced from 1169 to ~800 lines; each concern now lives in its own unit.

## Validation

- Release build: passed.
- CTest: 15/15 passed.
- Reference libvncclient auth: AUTH_OK.
- NoDisplaySleep assertion held while running.
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.4

## Highlights

- macVNC now wakes the display automatically so a remote client never sees a blank/black screen when the Mac has dimmed or slept the display.
- On server start it nudges the display awake and retries if the active display count is 0 (previously it failed with "Unsupported active display count: 0").
- On each client connection it declares user activity to wake the screen.
- Holds a `NoDisplaySleep` power assertion for the lifetime of the session and releases it on stop.

## Validation

- Release build: passed.
- CTest: 15/15 passed.
- Verified: NoDisplaySleep + UserIsActive assertions held while running; frames delivered.

# macVNC 0.3.3

## Highlights

- Fixed the long-standing "password check failed" bug for the notarized standalone build.
- Root cause: the app was signed with hardened runtime but WITHOUT `com.apple.security.cs.disable-library-validation`, so the bundled Homebrew dylibs (libvncserver + OpenSSL) failed library validation and libvncserver's OpenSSL-backed VNC DES password check always failed.
- Release signing now uses `build/entitlements.plist` with `disable-library-validation`.
- Release packaging now bundles the REAL dylib targets (resolves symlinks) so a stale/mismatched OpenSSL can no longer be shipped.
- Password is stored in plaintext defaults and trimmed of surrounding whitespace/newlines.
- Note: VNC passwords are effectively 8 characters (DES); longer values are truncated.

## Validation

- Release build: passed.
- CTest: 15/15 passed.
- Reference libvncclient auth against the signed bundle: AUTH_OK.
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.1

## Highlights

- Password is now stored in plaintext `NSUserDefaults` (by request), not in the macOS Keychain.
- Fixes the case where a Keychain-stored password was unreadable by the app (`errSecInteractionNotAllowed -25308`), which made the server refuse to start with "A non-empty VNC password is required".
- Any legacy Keychain password is migrated back into defaults and removed from the Keychain.

## Validation

- Release build: passed.
- CTest: 15/15 passed.
- Developer ID Application signing / notarization / staple: passed.

# macVNC 0.3.0

## Highlights

- Do not block startup on `CGPreflightScreenCaptureAccess()` false-negatives; rely on the runtime capture handler instead.

# macVNC 0.2.9

## Highlights

- Permission chips now only open the relevant macOS Privacy & Security pane.
- Removed the extra macOS system permission request dialog that popped up when clicking a chip (no more `CGRequestScreenCaptureAccess`/Accessibility prompt from our UI).
- Behavior otherwise unchanged: single unified permission popup; no permissions → no VNC listener.

## Validation

- Release build: passed.
- CTest: 15/15 passed.
- Developer ID Application signing: passed.
- Notarization: accepted.
- Stapler validation: passed.
- Gatekeeper assessment: accepted as Notarized Developer ID.

# macVNC 0.2.8

## Highlights

- Unified permission handling into a single source of truth (`MacVNCPermissions`).
- One single double-chip permission popup is used everywhere:
  - at startup when permissions are missing;
  - when ScreenCaptureKit fails at runtime.
- Removed the old separate `OK` permission alerts from the server/capture path.
- Fixed a class of bugs where `CGPreflightScreenCaptureAccess()` returned a stale `true` after an update:
  - a runtime capture failure now marks Screen Recording as not effectively granted;
  - the unified popup shows `Restart required` and offers `Restart macVNC`.
- `Restart macVNC` now waits for the current process to exit before launching a new one, so it no longer leaves two macVNC processes running.
- Safety rule unchanged: no required permissions → no VNC listener.

## Validation

- Release build: passed.
- CTest: 15/15 passed.
- Developer ID Application signing: passed.
- Notarization: accepted.
- Stapler validation: passed.
- Gatekeeper assessment: accepted as Notarized Developer ID.
- Installed runtime gate: no listener without permissions; single process after relaunch.

# macVNC 0.2.7

- Fixed startup permission popup refresh behavior after granting permissions in System Settings.
- `Restart required` chip state and `Restart macVNC` action for permissions pending process restart.

# macVNC 0.2.6

- Added startup permission gate with two clickable permission chips.
- No `Start anyway`: no permissions → no VNC listener.
- Permission logic isolated in `MacVNCPermissions`.

# macVNC 0.2.5

- Password is stored in macOS Keychain instead of plaintext `NSUserDefaults`.
- Compact Preferences window; advanced allowed-clients format hint.

# macVNC 0.2.4

- Simplified Network Preferences; automatic client allow policy from selected interface.

# macVNC 0.2.3

- Selected interfaces show `Selected address` as read-only.

# macVNC 0.2.2

- Localhost default no longer shown as a manual custom CIDR when using a network preset.

# macVNC 0.2.1

- Clarified Network Preferences wording and tooltips.

# macVNC 0.2.0

- Added GUI-managed IPv4 network security settings and active network picker.
- Added explicit client allowlist and allow-all mode.
- Disabled IPv6 listener in v1 network policy.
- Bundled Homebrew dylib dependencies in the notarized standalone DMG.
