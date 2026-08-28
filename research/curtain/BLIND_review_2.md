I read only `/tmp/curtain-clean.md` plus macOS SDK headers. No web-search tool was available in this session, so every external claim below is verified against SDK headers with file:line citations rather than URLs; where I could not verify, I say so explicitly. Two stored memories applied: the VNC password is DES-truncated to 8 effective characters, and hardened/notarized builds behave differently from dev builds — both turn out to be directly load-bearing for this feature.

---

# BLIND review — Curtain mode plan (`/tmp/curtain-clean.md`)

Reviewer role: safety and failure-mode critic. Scope: can this design leave a human being in front of a black screen with dead input and no way back?

Verification basis: `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk` (referred to below as `$SDK`). No web search tool was exposed to this session; claims I could not verify from headers are listed in §3 as unverified rather than asserted as errors.

---

## 0. What is genuinely good (say it plainly)

These are not filler; they are the parts I tried to break and could not.

- **Task ordering is correct and safety-driven.** Policy → window → input suppression is exactly the right order, because the escape hatch exists before the trap does. Most implementations of this feature do the opposite.
- **`SCWindow.windowID` ↔ `NSWindow.windowNumber` is a correct API claim.** `$SDK/.../ScreenCaptureKit.framework/Headers/SCShareableContent.h:54-56` declares `@property (readonly) CGWindowID windowID;`, and `NSWindow.windowNumber` is the same CGWindowID namespace. The identification mechanism will work.
- **`-[SCContentFilter initWithDisplay:excludingWindows:]` is real and does what the plan needs.** `$SDK/.../SCStream.h:149-154`: "captures the SCDisplay, excluding the passed in excluded SCWindow(s). The desktop background and dock will be included." Excluding a window removes it from the *capture*, not from the *local display* — which is precisely the local-black/remote-live asymmetry the feature requires. Also `includeMenuBar` defaults to YES for excluding filters (`SCStream.h:122`), so the remote viewer keeps the menu bar. Correct.
- **`CGEventTapCreate` with `kCGEventTapOptionDefault` is an active tap that can swallow events.** `$SDK/.../CGEventTypes.h:417-419` (`kCGEventTapOptionDefault = 0`, vs `kCGEventTapOptionListenOnly`), `CGEvent.h:296-300`. Correct.
- **"A crash self-heals" is true, for actual crashes.** A `CFMachPort` event tap is owned by the process and torn down by the WindowServer when the process dies; the `NSWindow` dies with the process. `kill -9` genuinely restores both screen and input. This is the single best design decision in the plan and it is correctly reasoned. (It is *not* true for hangs — see F7.)
- **"Raise only while `vncConnectedClients > 0`" is the right gate**, and off-by-default with an honest UI string is the right product posture.
- **The non-goals section is honest.** Refusing to claim the Mac is locked is correct and rare.
- **Recognising `kCGEventTapDisabledByTimeout` at all** puts this plan ahead of most; the framing "black screen with live input is the worst mix" is the right instinct, even though the mitigation is incomplete (F10, F13).

---

## 1. Errors

Concrete, evidence-backed defects in the plan as written.

### F1 — P0 — Secure Event Input silently destroys *both* halves at once
**Location:** Task 3 step 1; the whole escape-hatch premise.

When any process enables secure event input (`EnableSecureEventInput`), keyboard events are withheld from session-level event taps. The API exists and is queryable: `$SDK/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/Headers/CarbonEventsCore.h:3044-3064` — `IsSecureEventInputEnabled()`, "Indicates whether secure event input is currently enabled."

Triggers that are routine, not exotic: any focused password field in Safari/Chrome, the Keychain prompt, `sudo` in Terminal with *Secure Keyboard Entry* on, 1Password/Bitwarden unlock, the loginwindow, FileVault prompts.

Failure mode, both halves inverted at once:
- the tap receives no key events → **local keyboard is NOT suppressed** (the person types into the frontmost app, blind, on a machine that looks off);
- the tap receives no key events → **the password escape hatch is dead**.

The plan has zero mitigation and does not mention secure input anywhere.

**Smallest fix:** call `IsSecureEventInputEnabled()` before raising (refuse to raise if true) *and* poll it on a timer while curtained (e.g. 1 Hz); if it flips to true, lift the curtain immediately and log the reason. Silent suppression failure must never be a state the curtain survives.

### F2 — P0 — No fallback path for password entry when the tap is dead or partial
**Location:** Task 1 ("state machine over typed characters") + Task 3 step 1 (tap feeds the policy).

The escape hatch has exactly one input path: the event tap. Every way the tap can fail (F1, F8, F9, F10, F13, TCC revocation, `CGEventTapCreate` returning NULL per `CGEvent.h:269-279`) is simultaneously a way the escape hatch fails. The plan explicitly rejects an `NSTextField` ("drawn by us (not an `NSTextField` that could take focus away)"), which is defensible for focus reasons, but it removes the only independent second path — the window's own `keyDown:` delivery.

**Smallest fix:** two independent paths into the same pure policy. (a) the tap; (b) the curtain window as key window with a custom `NSView` implementing `keyDown:` (`canBecomeKeyWindow` overridden to YES on a borderless window). Path (b) works whenever AppKit delivers events at all, including when the tap is disabled by timeout. Add an invariant test: *the curtain may never be in a state where zero input paths reach the policy.*

### F3 — P0 — Uncapped growing throttle is itself a lockout mechanism
**Location:** Task 1 step 2, "after N failures require a growing wait before the next attempt is even considered"; Task 1 step 4 mutation "no throttle".

"Growing" with no stated ceiling and no stated reset. A cat on the keyboard, a stuck key, or a user mashing Return produces dozens of "failures" in seconds; an exponential backoff reaches hours. The owner is then locked out **by the safeguard**, with a black screen, for a duration nobody chose. The plan mutation-tests the *absence* of throttling but not the *excess* of it.

Amplifier: without filtering `kCGKeyboardEventAutorepeat` (`$SDK/.../CGEventTypes.h:176-178`: "non-zero when this is an autorepeat of a key-down"), a held Return generates a failure per repeat.

**Smallest fix:** hard cap the delay (30 s is plenty against a physically present attacker), count only non-autorepeat key-downs, require a non-empty buffer before a Return counts as an attempt, and decay the failure counter over time. Add mutation tests for *uncapped delay* and *autorepeat counted as attempt*.

### F4 — P0 — Empty or unset VNC password ⇒ curtain with no escape hatch at all
**Location:** Task 5 step 2, "the VNC password lifts it".

The plan never states what happens when the configured VNC password is empty, or when the server is running in a no-auth / alternative-auth mode. If the password is empty, either every Return lifts the curtain (no protection at all) or nothing lifts it (**total lockout, black screen, dead input, no key sequence exists that helps**).

**Smallest fix:** make it a hard precondition — refuse to raise the curtain unless a non-empty unlock secret is configured, and disable/grey the preference with an explanation when it is not. Add a test: `curtain_policy` with an empty configured password must return "refuse to arm", never "accept anything".

### F5 — P0 — DES 8-character truncation mismatch between VNC auth and the curtain policy
**Location:** Task 1 step 1 ("compare against the configured password"), Task 5 step 2 ("the VNC password lifts it").

(applied from memory: VNC password is effectively 8 characters — DES truncates.) The RFB VNC authentication key is a DES key built from the first 8 bytes of the password; anything beyond is discarded. So if the owner configured `correcthorsebattery`:

- their VNC client authenticates with the effective secret `correcth`;
- if `MacVNCCurtainPolicy` compares against the **full stored string**, the owner must type all 19 characters while the plan's UI told them "the VNC password";
- if the owner types the 8 characters they know actually work, the curtain rejects them, the throttle (F3) starts growing, and they are locked out by a definition mismatch.

The inverse is worse: if the policy truncates to 8 and the UI says nothing, the effective local unlock secret is 8 characters, which the plan never discloses.

**Smallest fix:** define the unlock secret as exactly the bytes the server authenticates with (i.e. apply the same 8-byte truncation), state it in the README and the preferences help text, and add a policy test with a >8-character configured password asserting the documented behaviour. Verify end-to-end against the reference `libvncclient` build, not vncdotool (applied from memory: vncdotool reports false AUTH OK).

### F6 — P0 — "The curtain lifts when the remote session ends" is not true for a half-open TCP connection
**Location:** Task 4 step 1 and acceptance; Verification bullet "client disconnect, server stop and app quit all lift it".

`vncConnectedClients > 0` is the only lift trigger for the remote side. If the viewer's machine loses power, its Wi-Fi drops, or a NAT/firewall silently drops state, no FIN and no RST arrive. libvncserver will not notice until a write fails, and with default `SO_KEEPALIVE` off (or default on at 2 hours) the client count can stay at 1 **indefinitely**. The stated failure mode — "the curtain must lift by itself when the remote session ends" — does not hold in the most common way a remote session actually ends.

The plan's own verification only tests a *clean* disconnect ("disconnect the client, confirm the curtain is gone"), which passes while the real failure goes untested.

**Smallest fix:** three layers, all cheap — (a) enable `SO_KEEPALIVE` with aggressive `TCP_KEEPALIVE`/`TCP_KEEPINTVL`/`TCP_KEEPCNT` on curtained sessions; (b) an application-level liveness requirement (no `FramebufferUpdateRequest` from the client for N seconds ⇒ lift); (c) an absolute maximum curtain duration after which the curtain lifts unconditionally and logs why. Add a test that pulls the network cable (or `pfctl`-drops the peer) rather than closing the client.

### F7 — P0 — The plan conflates *crash* with *hang*; hangs do not self-heal
**Location:** Context, "a crash must not leave a black screen with dead input — an event tap dies with the process and the window disappears with it, so a crash self-heals".

True for `SIGKILL`/`SIGSEGV`. **False** for: main-thread deadlock, beachball, `SIGSTOP` (debugger attach, `kill -STOP`, some sandbox/EDR agents), or a blocked serial lifecycle queue. In all of those, the process is alive, so the window stays and the tap stays installed.

Resulting steady state: the tap stops responding, the system eventually delivers `kCGEventTapDisabledByTimeout` and stops consulting it, so **input returns while the screen stays black forever**, and the callback that was supposed to re-enable or lift never runs because the run loop is wedged. Nothing in the plan recovers from this. Task 4's lift paths all run on "the serial lifecycle queue that already exists" — the very thing that may be blocked.

**Smallest fix:** an independent watchdog on its own dedicated thread (not the main run loop, not the lifecycle queue) that (a) receives a heartbeat from the main thread, (b) tears the curtain windows down and disables the tap if the heartbeat stops for N seconds, and (c) enforces the absolute maximum curtain duration from F6. Add the corresponding verification: `kill -STOP` the app while curtained and confirm recovery; the current checklist only tests `kill -9`, which is the case that already works.

### F8 — P1 — `CGEventTapCreate` can succeed with a silently reduced mask
**Location:** Task 3 step 1; Task 3 step 4 ("failure paths").

`$SDK/.../CoreGraphics.framework/Headers/CGEvent.h:272-279`:

> Taps placed at `kCGHIDEventTap`, `kCGSessionEventTap`, `kCGAnnotatedSessionEventTap`, or on a specific process may only receive key up and down events if access for assistive devices is enabled … **If the tap is not permitted to monitor these events when the tap is created, then the appropriate bits in the mask are cleared.** If that results in an empty mask, then NULL is returned.

So a keyboard+mouse tap can come back **non-NULL with the keyboard bits removed**. Result: mouse suppressed, keyboard live, password escape hatch dead — the curtain looks armed and is not. The plan checks only for creation failure, never for capability.

**Smallest fix:** after creating the tap, prove the keyboard path works before the curtain becomes irreversible — e.g. arm a short grace period during which the curtain lifts itself unless at least one `kCGEventKeyDown` or `kCGEventFlagsChanged` has been observed; and preflight with `CGPreflightListenEventAccess()` (see F9).

### F9 — P1 — "Accessibility is already granted … so no new permission dialog" is an unverified assumption
**Location:** Context, second bullet under "What macOS does and does not allow (checked, not assumed)".

Since macOS 10.15, CoreGraphics exposes *two separate* preflight/request pairs for two distinct TCC services:

- `$SDK/.../CGEvent.h:398-402` — `CGPreflightListenEventAccess()` / `CGRequestListenEventAccess()` ("event listening access");
- `$SDK/.../CGEvent.h:404-408` — `CGPreflightPostEventAccess()` / `CGRequestPostEventAccess()` ("event synthesizing access").

The plan's justification is about *synthesizing* ("we inject events through it") and is being used to claim *listening* is already permitted. Those are separate grants in the SDK's own API surface. The header quoted in F8 says listening is gated on assistive-device access, which the Accessibility grant does satisfy — so the claim may well be right in practice — but the plan asserts it as "checked, not assumed" without stating how it was checked, and the SDK's separate API pair is direct evidence that it deserves an explicit check.

**Smallest fix:** call `CGPreflightListenEventAccess()` at arm time and refuse to raise if false; do not silently `CGRequestListenEventAccess()` mid-session (it can prompt while the screen is black). Downgrade the "checked, not assumed" wording until an A/B on a **notarized, hardened build** confirms it — see F24.

### F10 — P1 — Only one of the two tap-disable reasons is handled
**Location:** Task 3 step 3, "Re-enable on `kCGEventTapDisabledByTimeout`".

`$SDK/.../CGEventTypes.h:128-131`:
```
/* Out of band event types. These are delivered to the event tap callback
   to notify it of unusual conditions that disable the event tap. */
kCGEventTapDisabledByTimeout = 0xFFFFFFFE,
kCGEventTapDisabledByUserInput = 0xFFFFFFFF
```
`kCGEventTapDisabledByUserInput` is not mentioned. Missing it leaves exactly the state the plan itself names as "the worst mix": black screen, live input, no log line, no recovery.

**Smallest fix:** handle both out-of-band types identically (log with the distinguishing reason, `CGEventTapEnable(tap, true)`), and add a bounded re-enable counter — if the tap is disabled more than K times in a window, lift the curtain rather than fighting the system forever.

### F11 — P1 — Default `collectionBehavior` at screensaver level is `Transient`, which is *hidden by Exposé*
**Location:** Task 2 step 1, "One borderless window per `NSScreen` at `NSScreenSaverWindowLevel`".

`$SDK/.../AppKit.framework/Headers/NSWindow.h:104-108`:

> You may specify at most one of `NSWindowCollectionBehaviorManaged`, `NSWindowCollectionBehaviorTransient`, or `NSWindowCollectionBehaviorStationary`. **If neither is specified, the window gets the default behavior determined by its window level.**
> … `NSWindowCollectionBehaviorTransient` **Floats in spaces, hidden by exposé. Default behavior if `windowLevel != NSNormalWindowLevel`.**
> … `NSWindowCollectionBehaviorStationary` Unaffected by exposé.

So with the plan as written, invoking Mission Control / Exposé **hides the curtain** and reveals the live desktop to the person standing there. Additionally, `NSWindowCollectionBehaviorFullScreenAuxiliary` (`NSWindow.h:118`, `NSWindow.h:141`) is required for the curtain to be shown alongside a full-screen window; without it, an app already in full screen on any display is not covered.

Whether Mission Control can be triggered at all depends on the event mask (F12) and on whether session taps see the hotkey before the WindowServer — which I could not verify from headers.

**Smallest fix:** set `collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle | NSWindowCollectionBehaviorFullScreenAuxiliary` explicitly, and add a verification step: with the curtain up, trigger Mission Control and enter a full-screen app; the desktop must not appear.

### F12 — P1 — The event mask is under-specified and the named classes are insufficient
**Location:** Task 3 step 1, "Active tap at `kCGSessionEventTap` for keyboard and mouse."

Classes that exist and are not covered by a naive keyDown/keyUp/mouseDown/mouseUp/mouseMoved mask (`$SDK/.../CGEventTypes.h:116-127`):
- `kCGEventFlagsChanged` (`:118`) — without it, modifiers still reach apps *and* you cannot show a Caps Lock indicator, which is a top cause of "the password doesn't work" panic;
- `kCGEventScrollWheel` (`:121`) — local scrolling still reaches apps;
- `kCGEventTabletPointer` / `kCGEventTabletProximity` (`:122-123`);
- other-mouse-button down/up/dragged;
- `NX_SYSDEFINED` (type 14) system-defined events — media/volume/brightness/Fn keys.

**Smallest fix:** enumerate the mask explicitly in the plan, add flagsChanged and scrollWheel at minimum, and state in the README which classes are deliberately *not* suppressed (consistent with the honest non-goals section).

### F13 — P1 — Throttling and UI work inside the tap callback will cause the timeout the plan fears
**Location:** Task 1 step 2 ("require a growing wait before the next attempt"), Task 3 step 1 (callback feeds the policy), Task 3 step 3.

Two concrete traps the plan does not forbid:
1. If the "growing wait" is implemented as a sleep/block inside the callback, the tap exceeds its timeout and the system disables it (`kCGEventTapDisabledByTimeout`) — the throttle *causes* the failure it was meant to prevent.
2. `CGEvent.h:290-292`: "The event tap callback runs from the CFRunLoop to which the tap CFMachPort is added as a source." If that run loop is the **main** run loop, then any main-thread stall (an SCK callback, a modal, an autolayout hitch, the filter rebuild in Task 2 step 3) directly stalls input for the whole machine, and a `dispatch_sync` to the main queue from the callback deadlocks outright.

**Smallest fix:** state as a hard constraint that the throttle is a non-blocking timestamp comparison; run the tap's run loop on a dedicated thread that does nothing else; all UI updates from the callback are `dispatch_async` only, never `dispatch_sync`. Add a mutation test for "throttle implemented as a blocking wait".

### F14 — P1 — Screen lock / screensaver / display sleep are not addressed at all
**Location:** absent from the whole plan.

Interactions, none covered:
- **Idle screensaver + "require password"**: the Lock Screen appears over the curtain. During the lock screen the curtain password does nothing (secure input, F1). The person sees black, types the curtain password, nothing happens. After they unlock with their *account* password, they land back on the black curtain with input suppressed again. Functionally indistinguishable from a lockout.
- **Display sleep with input suppressed**: display wake is driven below the session tap so a keypress should still wake the display — but the plan does not state this was tested, and if it is wrong the machine is unrecoverable without a power button.
- **Sleep/wake**: after `NSWorkspaceDidWakeNotification` (`$SDK/.../NSWorkspace.h:323`) and `NSWorkspaceScreensDidWakeNotification` (`:326`), the tap may need re-enabling and the curtain windows may need re-ordering above whatever the WindowServer restored.

**Smallest fix:** hold an `IOPMAssertion` (`kIOPMAssertionTypePreventUserIdleDisplaySleep` / `...PreventUserIdleSystemSleep`) for the duration of the curtain so the lock/screensaver path cannot be entered accidentally; subscribe to `com.apple.screenIsLocked` (distributed notification) and lift the curtain on lock; re-verify the tap on `NSWorkspaceDidWakeNotification`.

### F15 — P1 — Fast user switching is not addressed
**Location:** absent.

`$SDK/.../NSWorkspace.h:328-330` provides `NSWorkspaceSessionDidResignActiveNotification` / `NSWorkspaceSessionDidBecomeActiveNotification`. Neither is mentioned. Open questions the plan must answer before shipping: does the curtain window persist correctly across a switch-away/switch-back; does `SCStream` keep delivering frames to the remote viewer while our session is inactive (if not, the remote viewer sees a frozen screen and the curtain stays up on a machine they can no longer see); does the session tap affect the other user (it should not, but this must be verified, not assumed).

**Smallest fix:** on `SessionDidResignActive`, lift the curtain (the local screen is no longer showing our session, so the curtain serves no purpose and only creates risk); re-raise on `SessionDidBecomeActive` only if a client is still connected.

### F16 — P1 — The injected-event feedback problem is stated as a contingency; it is the expected case, and one common injection path cannot be tagged
**Location:** Task 3 step 2, "verify empirically that injected events are not fed back into our own tap, **and if they are**, tag and skip them."

`kCGHIDEventTap` is upstream of `kCGSessionEventTap` — events posted at the HID tap traverse session taps by construction. The near-certain outcome is that the remote viewer's own input is swallowed by our tap, i.e. **curtain mode disables remote control**, which defeats the entire feature. Writing this as "if they are" leaves the acceptance criteria satisfiable without the tag.

The tagging mechanism exists: `$SDK/.../CGEventTypes.h:354-356`, `kCGEventSourceUserData = 42` ("the event source user-supplied data, up to 64 bits").

The gap the plan does not see: **if any part of the VNC input path uses `CGWarpMouseCursorPosition` rather than a posted `CGEvent`**, the resulting motion event carries no source and cannot be tagged — remote pointer movement dies while curtained, with no fix available at the tap. This must be checked against the existing input path before Task 3 starts.

**Smallest fix:** make the tag mandatory in the acceptance criteria, not conditional; set it via `CGEventSourceSetUserData` on the shared injection source; audit the existing input path for `CGWarpMouseCursorPosition` and convert it to a posted event if present.

### F17 — P1 — "The exclusion list is fixed at filter creation, so the capture stream restarts on toggle" is wrong, and the restart is a live risk
**Location:** Task 2 step 3.

`$SDK/.../SCStream.h:488-492`:
```
@param contentFilter the requested content filter to be updated
@discussion this method will update the content filter for a content stream.
- (void)updateContentFilter:(SCContentFilter *)contentFilter completionHandler:(...)
```
The filter can be swapped on a running stream. The plan's stated restart is therefore unnecessary — and it is not free: a `stopCapture`/`startCapture` cycle can fail (permissions, transient `SCError`, display reconfiguration mid-restart), and the failure lands exactly at the moment the curtain goes up. Result: black local screen, and a remote viewer with **no video** — i.e. nobody can see the machine, remotely or locally.

**Smallest fix:** use `updateContentFilter:completionHandler:`; treat a non-nil error in the completion handler as a mandatory curtain-lift.

### F18 — P1 — The raise sequence has no stated ordering or failure policy, and the filter rebuild is asynchronous
**Location:** Task 2 steps 2-3.

`getShareableContentWithCompletionHandler:` (`SCShareableContent.h:142-146`) is asynchronous and can return an error; `updateContentFilter:` is asynchronous and can return an error. The plan does not say what happens if the curtain windows are already on screen when either step fails or never completes. Two distinct bad outcomes, both reachable:
- windows up, exclusion not yet applied ⇒ **the remote viewer sees the black curtain** and loses their session view at the same instant the local user loses theirs;
- windows up, exclusion permanently failed ⇒ same, forever.

Related timing hazard: with `onScreenWindowsOnly:YES` (`SCShareableContent.h:156-162`), a curtain window that has just been ordered in may not yet be present in the returned `windows` array, so a single-shot lookup can silently miss it.

**Smallest fix:** define the sequence as *confirm exclusion first, then reveal the curtain*: create the windows off-screen or fully transparent, resolve+apply the filter, verify each `windowNumber` is present in the applied exclusion set (with bounded retry for the enumeration race), and only then make them opaque. Any failure or timeout ⇒ tear down and never suppress input.

### F19 — P1 — Display hot-plug handling names no mechanism and has an unavoidable exposure window
**Location:** Task 2 step 4, "a screen added while curtained must be covered too."

The hooks exist but are unnamed: `NSApplicationDidChangeScreenParametersNotification` (`$SDK/.../AppKit.framework/Headers/NSApplication.h:647`) and `CGDisplayRegisterReconfigurationCallback`. Neither is in the plan. Also unaddressed:
- a display **removed** while curtained — its window must be torn down, and its curtain must not migrate onto a surviving display;
- resolution/arrangement changes — window frames must be recomputed, or a curtain sized for the old resolution leaves an uncovered strip showing the live desktop;
- the exposure window between hot-plug and window creation, during which the new display shows the real desktop;
- AirPlay/Sidecar displays, which appear as `NSScreen` and will be curtained — possibly surprising, and worth stating.

**Smallest fix:** name the notification, handle add/remove/reconfigure symmetrically, and state the accepted exposure window in the README rather than implying it is zero.

### F20 — P1 — The unlock secret can be changed or removed while the curtain is up
**Location:** Task 1 step 1 ("the configured password"), Task 5.

If the policy captures the password at arm time, a remote-side change desynchronises it. If it reads it live and the password is set to empty (remotely, or by another process writing the defaults), **the escape hatch disappears while the curtain is up** — the exact F4 lockout, reached from a running state where the F4 precondition check has already passed.

**Smallest fix:** observe the defaults key; on any change to the unlock secret while curtained, lift the curtain and log the reason. Add a `test_defaults` case for it.

### F21 — P1 — No stated policy on what the local user *sees*, which determines whether they can tell a failure from a wrong password
**Location:** Task 2 step 1, "a short message and a password field drawn by us".

If the field gives no feedback, a user whose tap is dead (F1/F8/F10) types the correct password repeatedly and concludes the machine is bricked. If it gives feedback, they can distinguish "wrong password" from "nothing is reaching the software". At a physical keyboard, feedback costs essentially nothing in oracle terms — the attacker is already standing there — and buys the single most important recovery signal.

Also unspecified: whether the prompt appears on **every** curtain window. With three monitors and the prompt only on the main one, a user looking at the wrong display sees an unexplained black screen.

**Smallest fix:** dots-as-typed, an explicit "incorrect — try again in Ns" countdown, a Caps Lock indicator (requires F12's `kCGEventFlagsChanged`), a one-line "this Mac is being accessed remotely; type the VNC password to reveal the screen", and the prompt mirrored on every display.

### F22 — P2 — Comparison is not specified as constant-time
**Location:** Task 1 steps 1 and 4 (mutation "comparison inverted").

The mutation list tests inversion but not timing. With F3's throttle in place the practical exploitability is low, so this is report-only — but `timingsafe_bcmp` costs one line versus `strcmp`, and `strcmp`'s early exit is a genuine byte-at-a-time oracle if the throttle is ever weakened or bypassed.

### F23 — P2 — Non-ASCII / non-US keyboard layouts
**Location:** Task 1 step 1, "state machine over typed characters".

If the implementation reads `kCGKeyboardEventKeycode` instead of `CGEventKeyboardGetUnicodeString`, the escape hatch breaks for every non-US layout. And if the active layout at raise time cannot produce the password's characters (Cyrillic layout active, Latin password), the user cannot type it at all — a full lockout with no software fault.

**Smallest fix:** use `CGEventKeyboardGetUnicodeString`; consider accepting the password on *either* the current layout or the ASCII/US interpretation of the keycodes, and add a policy test with a keycode stream from a non-US layout.

---

## 2. What is MISSING

Gaps where the plan says nothing at all, ordered by how badly they end.

**M1 — A watchdog / dead-man's switch.** The single largest structural omission. Everything in Task 4 lifts the curtain *from code paths that a hang disables*. There is no independent timer that lifts the curtain regardless of what the rest of the app is doing. This is the one addition that would convert several P0s into survivable events. (See F7.)

**M2 — An absolute maximum curtain duration.** No upper bound is stated anywhere. Combined with F6, a curtain can outlive the session that justified it by hours or days.

**M3 — A documented recovery runbook.** The plan's own framing ("this is the trail that explains a black screen to a confused owner") stops at log lines. A confused owner facing a black screen cannot read logs — they cannot see the screen. The README needs, in order: (1) type the VNC password; (2) SSH in from another machine and `killall macvnc`; (3) hold the power button. Note that the Force Quit panel is at modal-panel level and the curtain is at screensaver level (`$SDK/.../CGWindowLevel.h:33,36`), so **Cmd-Opt-Esc will be invisible under the curtain** — the obvious user reflex does not work, and this must be documented.

**M4 — Handling of `kCGEventTapDisabledByUserInput`.** (F10.)

**M5 — Secure-input detection.** (F1.)

**M6 — Screen lock, screensaver, display sleep, sleep/wake.** (F14.)

**M7 — Fast user switching.** (F15.)

**M8 — Network-death detection for the remote session.** (F6.)

**M9 — A threat-model line for the *availability* direction.** The plan's non-goals cover "we do not stop a determined person with physical access". It does not cover the inverse: **anyone who obtains the VNC password can black out the physical console**. With an effective 8-character DES-truncated secret (applied from memory), that is a low bar for a denial-of-access primitive against the machine's owner. At minimum this belongs in the README security notes next to the existing ones; consider requiring an explicit local confirmation, or a distinct curtain password, rather than reusing the remote credential.

**M10 — Whether the unlock secret should be the VNC password at all.** Reusing it means the person at the keyboard learns the remote-access credential by watching, and the remote operator knows the local unlock. A separate `MacVNCKeyCurtainPassword` (defaulting to the VNC password for convenience) removes the coupling for one extra defaults key.

**M11 — Verification coverage for every failure mode above.** The current checklist tests the happy paths plus `kill -9`. Missing: multi-monitor (Task 2's acceptance mentions "every physical display" but the Verification list does not), display hot-plug and hot-unplug, sleep/wake, screen lock, fast user switching, secure input active at raise time, `CGEventTapCreate` returning NULL or a reduced mask, network death (not clean disconnect), `kill -STOP`, empty password, password changed while curtained, Mission Control / full-screen app, non-US keyboard layout, and throttle-cap behaviour.

**M12 — Statement of platform preconditions.** `SCContentFilter` is `API_AVAILABLE(macos(12.3))` (`SCStream.h:100`); `updateContentFilter:` and `includeMenuBar` have their own floors (`SCStream.h:124` is macOS 14.2). More importantly: this design requires the process to be a GUI application inside the user's Aqua session. If macVNC can be deployed as a root LaunchDaemon in the system context, `NSWindow` will not appear and `kCGSessionEventTap` will not attach to the console session — the curtain would silently do nothing while the preference claims it is on. The plan should state the deployment mode as a precondition and refuse to arm outside it.

**M13 — TCC-grant fragility across signing.** (applied from memory: this project's hardened/notarized builds behave differently from dev builds, and signing details are load-bearing.) Accessibility / Input Monitoring / Screen Recording grants are keyed to the code signature's designated requirement. A re-signed or re-notarized build can lose them. The failure is silent and asymmetric: Screen Recording may survive while Input Monitoring does not, producing a curtain that hides the screen but suppresses nothing and accepts no password (F1/F8 territory). The plan has no "verify on the shipped artefact" step. Adding one is cheap and, given this project's history, warranted.

**M14 — Pointer motion is not actually suppressed.** The mouse cursor is drawn above screensaver level (`kCGCursorWindowLevelKey`, `$SDK/.../CGWindowLevel.h:42`, versus `kCGScreenSaverWindowLevelKey` at `:36`), and the WindowServer moves the cursor before the session tap sees the event. So with the curtain up the local person still sees a cursor gliding over the black, and their own hand still moves it — and that motion appears in the remote stream, confusing the remote operator. Cosmetic, but it belongs in the honest-limits list. Note that the "fix" (`CGAssociateMouseAndMouseCursorPosition(false)` or `CGDisplayHideCursor`) is itself a lockout hazard if the process hangs, so I would document rather than fix.

**M15 — Side channels.** Notification sounds, Siri, the volume/brightness HUD, and external displays' own OSD are unaffected. One README line.

---

## 3. Doubtful assumptions

Claims the plan asserts (several under the heading "checked, not assumed") that I could not confirm from the SDK and that carry real consequences if wrong. I am listing these as *unverified*, not as errors.

| # | Assumption (location) | Why it is doubtful | Consequence if wrong |
|---|---|---|---|
| D1 | "Accessibility is already granted … so no new permission dialog" (Context) | The SDK exposes `CGPreflightListenEventAccess` and `CGPreflightPostEventAccess` as *separate* gates (`CGEvent.h:398-408`). Listening and posting are distinct TCC services. | Tap created with keyboard bits cleared (F8) or not at all; curtain arms with no suppression and no escape hatch. |
| D2 | Excluded windows are excluded reliably at `NSScreenSaverWindowLevel` | The header (`SCStream.h:149-154`) does not qualify exclusion by window level, but screensaver-level exclusion is not the documented use case. | The black curtain appears in the remote stream; remote operator loses the session at the same moment the local user does. |
| D3 | Injected events are *not* fed back into our tap (Task 3 step 2 hedges on this) | HID tap is upstream of session tap by construction; the hedge is almost certainly the real case. | Remote control dead while curtained — feature is pointless. Must be resolved before Task 3, not during. |
| D4 | Display wake on keypress still works with local input suppressed | Wake is handled below session taps, so it *should* work — but the plan neither states nor tests it. | Display never wakes; the only recovery is the power button. |
| D5 | A blank window covers everything the local person can summon | `kCGAssistiveTechHighWindowLevelKey` and `kCGMaximumWindowLevelKey` sit past screensaver in the level enum (`CGWindowLevel.h:36-43`); VoiceOver panels, Zoom, and the screenshot UI can draw above. | Partial content leak. Low severity, but the UI must not over-promise. |
| D6 | Apple's Curtain Mode requires Remote Management and does not work at the login window (Context) | Consistent with my understanding of Apple's documentation, but **I had no web-search tool in this session and could not fetch the source URL**. It is context only — nothing in the design depends on it. | None technically; only the framing. If the README repeats it, cite the Apple doc URL. |
| D7 | The remote viewer wants the curtain (Task 5 implies a local preference that auto-arms on every connection) | The plan never states who decides. A preference means *every* successful VNC auth blacks out the console with no local consent. | Surprise blackouts; see M9. Consider making the curtain a per-session action rather than a standing preference. |
| D8 | "no window of ours appears in the remote stream" (Task 2 acceptance) is fully verified by a content signature | A signature that distinguishes "desktop" from "black" does not prove the *password field* is excluded — a small non-black overlay passes a whole-frame signature. | The remote viewer can watch the local user type the password. Tighten the acceptance to check the curtain's exact rect. |

---

## 4. VERDICT

### **CONDITIONAL — do not start Task 3 until the P0 list is resolved in the plan.**

Not NO-GO: the architecture is sound, the API foundations are real and correctly identified (verified against `SCStream.h`, `SCShareableContent.h`, `CGEvent.h`, `CGEventTypes.h`), the task ordering deliberately builds the escape hatch first, and the crash-self-heal reasoning is correct. This is a thoughtful plan by someone who understood the stakes.

Not GO: for a feature whose worst case is *a person locked out of their own computer*, the plan has **one** recovery mechanism (the password), that mechanism has **one** input path (the tap), and that path has at least five independent ways to fail silently — none of which the plan addresses. The stated invariant "a crash self-heals" is true but is doing more work than it can bear, because the realistic bad states are hangs and half-open sockets, not crashes.

**Conditions to clear before Task 3 begins (the input-suppression task — the one that can trap someone):**

1. **F7/M1** — add an independent watchdog thread that lifts the curtain on heartbeat loss, plus an absolute maximum duration (M2). This is the highest-value single addition in this review.
2. **F1** — `IsSecureEventInputEnabled()` gate at arm time and polled while curtained; lift on transition to true.
3. **F2** — a second, tap-independent input path into the policy.
4. **F3** — cap the throttle, ignore autorepeat, decay the failure count. Add both mutation tests.
5. **F4/F5/F20** — define the unlock secret exactly (including the 8-byte DES truncation), refuse to arm when it is empty, lift when it changes. Verify with the reference `libvncclient`, not vncdotool.
6. **F6** — network-death detection; test by dropping the network, not by closing the client.
7. **F8/F9** — verify the tap actually received the keyboard bits before the curtain becomes irreversible.
8. **F16/D3** — resolve the injected-event question *before* Task 3, and audit the existing input path for `CGWarpMouseCursorPosition`.

**Should be fixed before release (not blocking the start of implementation):** F10, F11, F12, F13, F14, F15, F17, F18, F19, F21, M3, M9, M12, M13, and the verification gaps in M11.

**Maturity: 6 / 10.**
Breakdown: API research 8/10 (accurate and header-checkable, one avoidable error in F17 and one over-confident claim in F9); architecture and sequencing 8/10; failure-mode coverage 4/10 (crash yes; hang, secure input, network death, lock, sleep, FUS, and hot-plug all absent); escape-hatch design 3/10 (single path, uncapped throttle, undefined secret, no empty-password guard, no truncation semantics); verification plan 4/10 (happy paths and `kill -9` only; the most dangerous component is covered by "manual on-device check plus a log line").

The gap between 6 and 9 is roughly one additional plan section — "Task 0: the deadman" — plus tightening the escape-hatch definition. The bones are good; the safety net has holes exactly where the plan's own risk statement says it must not.

---

## Review

- **Correct:** task ordering (escape hatch first); `SCWindow.windowID`↔`NSWindow.windowNumber` (`SCShareableContent.h:54-56`); `initWithDisplay:excludingWindows:` semantics (`SCStream.h:149-154`); active-tap suppression via `kCGEventTapOptionDefault` (`CGEventTypes.h:417-419`); crash self-heal reasoning; off-by-default with honest non-goals; `vncConnectedClients > 0` gate.
- **Fixed:** nothing — review-only task, no project file modified.
- **Findings:** 7×P0 (F1–F7), 14×P1 (F8–F21), 2×P2 (F22–F23), 15 missing items (M1–M15), 8 doubtful assumptions (D1–D8). All cited to `/tmp/curtain-clean.md` sections and `$SDK` header file:line.
- **Merge verdict:** CONDITIONAL — GO for Tasks 1–2 once F4/F5 are settled; BLOCK on Task 3 until the eight P0 conditions are in the plan.