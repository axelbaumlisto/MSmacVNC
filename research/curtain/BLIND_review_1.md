# BLIND review 1 — API audit of `/tmp/curtain-clean.md` (curtain mode plan)

Reviewer role: senior macOS platform engineer. Scope: verify every macOS API claim in the plan
against the real SDK headers and Apple documentation. **No project file was read or modified**
(only `/tmp/curtain-clean.md`, SDK headers, and public documentation).

Environment used for header citations:
`SDK = /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`
(Xcode 26.6 / 17F113, host macOS 26.5.2). Header paths below are relative to that SDK.

Legend: **[H]** = verified in SDK header, **[A]** = verified in Apple documentation,
**[3P]** = third-party corroboration only, **[?]** = could not verify.

---

## 0. What the plan gets right (not padding — these are real)

- **Ordering of work is correct and safety-driven.** Policy → window → input suppression is the
  only order in which a half-finished implementation cannot trap the local user. Good.
- **`SCContentFilter initWithDisplay:excludingWindows:` exists and does what the plan says** —
  `System/Library/Frameworks/ScreenCaptureKit.framework/Headers/SCStream.h:151`:
  "This method will create a SCContentFilter that captures the SCDisplay, excluding the passed in
  excluded SCWindow(s). The desktop background and dock will be included with this content
  filter." **[H]** So "black locally, real desktop remotely" is a sound mechanism.
- **`kCGEventTapOptionDefault` really is an active tap that can discard events** —
  `CoreGraphics.framework/Versions/A/Headers/CGEvent.h:257–262`: "Taps may be passive event
  listeners, or active filters. An active filter may pass an event through unmodified, modify an
  event, or discard an event." Constant at `CGEventTypes.h:418`. **[H]**
- **`kCGEventTapDisabledByTimeout` is real and must be handled by re-enabling** —
  `CGEventTypes.h:130`; `CGEvent.h:324–326`: "If a tap becomes unresponsive or a user requests taps
  be disabled, an appropriate `kCGEventTapDisabled...` event is passed to the registered
  CGEventTapCallBack function. An event tap may be re-enabled by calling this function
  [`CGEventTapEnable`]." **[H]** The plan noticed this; many implementations do not.
- **A tap dies with the process** — `CGEvent.h:281`: "Releasing the CFMachPortRef will release the
  tap." Process death releases the port. **[H]** The `kill -9` acceptance test is the right test.
- **Off by default, honest UI wording, log every raise/lift with a reason, lift on
  `applicationWillTerminate`, refuse to raise with no client connected** — all correct instincts for
  a feature whose worst failure is locking the owner out.
- **"Apple's curtain requires Remote Management" and "does not work at the login window" are
  correct.** Edovia (Screens) documents both: "Curtain Mode requires **Remote Management** to be
  enabled on the remote Mac. It does not work with Screen Sharing" and "Curtain Mode Does Not Work
  at the Login Window — macOS does not allow Curtain Mode to activate while the Login Window is
  visible." https://support.edovia.com/en/screens-5/features/curtain-mode **[3P]**

---

## 1. Errors

### E1 (BLOCKER) — "the exclusion list is fixed at filter creation, so the capture stream restarts on toggle" is false

`SCStream.h:487–492`:

```objc
/*! @abstract updateContentFilter:completionHandler: */
- (void)updateContentFilter:(SCContentFilter *)contentFilter
          completionHandler:(nullable void (^)(NSError *_Nullable error))completionHandler;
```

Available since macOS 12.3 (the same version as `SCStream` itself). **[H]** You swap the filter on a
running stream; you do not restart it. Restarting the stream on every curtain toggle is a
self-inflicted risk: a stop/start round-trip drops frames, re-enters the TCC/`SCShareableContent`
path, and on failure leaves the curtain up with a dead stream — the exact "black locally, nothing
remotely" state the plan says it wants to avoid.

**Fix:** build the new `SCContentFilter` and call `-updateContentFilter:completionHandler:`; only
raise/lift the window after the completion handler reports success (see F4 for the ordering).

### E2 (BLOCKER) — remote-injected input *will* hit your own session tap; this is documented, not something to "verify empirically"

Plan, Task 3 step 2: "the VNC input path posts to `kCGHIDEventTap`; verify empirically that injected
events are not fed back into our own tap".

`CGEvent.h:347–352` (doc comment for `CGEventPost`):

> "Post an event into the event stream at a specified location. This function posts the specified
> event immediately before any event taps instantiated for that location, **and the event passes
> through any such taps**."

**[H]** `kCGHIDEventTap` is *upstream* of `kCGSessionEventTap` (`CGEvent.h:255–258`: taps may be
placed "at the point where HIDSystem events enter the server, at the point where HIDSystem **and
remote control events** enter a session, ..."). An event posted at the HID location therefore
traverses the HID tap point and then the session tap point. Your Task 3 step 1 ("return NULL to
swallow them") will swallow the remote viewer's own keystrokes and clicks the instant the curtain
goes up. That is not a corner case to check later — it is the default behaviour, and it breaks the
product's primary function (remote control) exactly while curtain mode is on.

**Fix (specific):** tag your injected events and pass them through unmodified.
- Create one `CGEventSourceRef` with `kCGEventSourceStatePrivate` (`CGEventTypes.h:481`; the header
  at `CGEventSource.h:44` explicitly recommends private state for programs that synthesize events)
  and call `CGEventSourceSetUserData(source, MACVNC_MAGIC)` (`CGEventSource.h:170`).
- In the tap callback read `CGEventGetIntegerValueField(event, kCGEventSourceUserData)`
  (`kCGEventSourceUserData = 42`, `CGEventTypes.h:356`) and `return event` when it equals the magic.
  Belt and braces: also compare `kCGEventSourceStateID` (`= 45`, `CGEventTypes.h:368`) and
  `kCGEventSourceUnixProcessID` (`= 41`, `CGEventTypes.h:352`) against `getpid()`.
- Do **not** rely on posting to `kCGAnnotatedSessionEventTap` as the workaround unless you re-test
  the whole input path: it changes routing (events are annotated for a specific application) and
  historically behaves differently for mouse warping/global shortcuts.

Also note `CGEvent.h:270–271`: "Taps may only be placed at `kCGHIDEventTap` by a process running as
the root user. NULL is returned for other users." **[H]** That restricts *tapping* at HID, not
*posting* — the plan's session-level tap choice is correct — but it means the "just tap at HID and
compare" alternative is not available to you.

### E3 (BLOCKER) — `NSScreenSaverWindowLevel` alone does not cover full-screen apps or other Spaces

`NSWindow.h:201` → `NSScreenSaverWindowLevel = kCGScreenSaverWindowLevel`; `CGWindowLevel.h:79` →
`((CGWindowLevel)1000)`. **[H]** Level governs z-order *within a Space*. A window is only shown on
the active Space unless `collectionBehavior` includes `NSWindowCollectionBehaviorCanJoinAllSpaces`
(`NSWindow.h:130`), and it is only shown over a full-screen (`FullScreenPrimary`) app's Space if it
also has `NSWindowCollectionBehaviorFullScreenAuxiliary` (`NSWindow.h:143`). The plan never mentions
`collectionBehavior`. As written, a local user sitting in full-screen Safari/Keynote/QuickTime — or
on a different Space — sees the whole session. That directly fails Task 2's acceptance ("every
physical display shows the curtain").

**Fix:** `window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorStationary |
NSWindowCollectionBehaviorIgnoresCycle;` set **before** ordering front, and use
`orderFrontRegardless` (not `makeKeyAndOrderFront:` — you do not want to activate the app or steal
focus). Add an explicit acceptance test: enter full-screen Safari, raise the curtain, confirm black.

Also be aware that levels above yours exist and are used by the system: `kCGAssistiveTechHighWindowLevel = 1500`
and `kCGCursorWindowLevel = kCGMaximumWindowLevel - 1` (`CGWindowLevel.h:80–81`), and
`CGShieldingWindowLevel()` (`CGDirectDisplay.h:377`). Assistive-technology panels (VoiceOver) and the
cursor draw above the curtain. The cursor is harmless; VoiceOver is a documented leak you should
name in the README.

### E4 (MAJOR) — "a crash self-heals" is true only for *termination*, not for a *hang*

The plan's central safety argument is: "an event tap dies with the process and the window disappears
with it, so a crash self-heals". Correct for `kill -9`/SIGSEGV **[H]** (`CGEvent.h:281`). It is
false for the far more likely failure: a deadlock, priority inversion or long blocking call **inside
the tap callback**. Then WindowServer disables the tap after its ~1 s callback budget and delivers
`kCGEventTapDisabledByTimeout` (`CGEventTypes.h:130`) **[H]**, restoring local input — while the
window server keeps compositing the hung app's last committed black surface. Result: black screen,
live input, no visible feedback, and the "type the password" escape hatch is dead because the
callback that would parse it is the thing that is stuck.

**Fix, three parts:**
1. Hard rule, written into Task 3: the tap callback allocates nothing that can block, takes no lock
   shared with the VNC/lifecycle queues, does no I/O, no `os_log` with string formatting of
   keystrokes, no `SCShareableContent`, and **never sleeps**. It only reads a few event fields,
   appends to a fixed-size buffer, and signals a semaphore/dispatch source.
2. The Task 1 "growing wait before the next attempt" must be implemented as a *deadline comparison
   against a monotonic clock* (`clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)`), never as a sleep in
   the callback. The obvious implementation of the plan's own step 2 is a sleep, and a sleep is what
   causes E4. Add a mutation test for it.
3. A watchdog: a separate high-priority thread (or a `dispatch_source_t` on a dedicated queue) that
   the callback pings; if no ping for N seconds while the curtain is up, tear the window down from
   that thread. Document the last-resort escape (`ssh` in, `killall`) in the README.

### E5 (MAJOR) — the characterisation of Apple's Curtain Mode is unsourced and probably wrong

The plan states, under "checked, not assumed": *Apple's documentation: the local screen "goes black
or displays a custom image" and the machine "stops accepting all keyboard and mouse input from the
local user"* and concludes "the same trick we would use, not a system lock".

I could not find that wording in any Apple documentation for curtain mode. **[?]** The ARD
administrator guide sections that describe curtain mode ("Disabling a Computer Screen" / "Hiding a
User's Screen While Controlling") contain no such sentence — they only say the screen is disabled
and the mode is toggled from the control window toolbar
(https://apple-remote-desktop.helpnox.com/en-us/apple-remote-desktop-administrator-s-guide/administering-client-computers/managing-computers/disabling-a-computer-screen/,
https://apple-remote-desktop.helpnox.com/en-us/apple-remote-desktop-administrator-s-guide/interacting-with-users/controlling/hiding-a-user-s-screen-while-controlling/). **[3P]**
The "black screen or custom image + message" wording belongs to ARD's *separate* "Lock Screen"
interact task, not curtain mode.

Worse for the argument: third-party documentation of the actual behaviour says the local display
shows a **locked** display, and that toggling it makes macOS "switch between displays"
(https://support.edovia.com/en/screens-5/features/curtain-mode) **[3P]**, and the field remedy for a
stuck curtain is `kill -9` of the **LockScreen** process
(https://apple.stackexchange.com/questions/65149/) **[3P]**. That is consistent with a root ARD
agent putting the console into a shielded/locked state — something you cannot reproduce with an
in-session `NSWindow`, and something that is *stronger* than what you are building.

**Consequence:** the plan may not cite Apple as precedent for "unlocked Mac behind a black window",
and the README must not imply parity with Apple's curtain. Either remove the quote or replace it
with a correctly attributed one. This matters because Task 5's whole premise is "honest words".

### E6 (MAJOR) — Secure Event Input silently defeats both the suppression and the escape hatch

Apple Technical Note TN2150, "Using Secure Event Input Fairly"
(https://developer.apple.com/library/archive/technotes/tn2150/_index.html) **[A]**:

> "The fix for this problem is to stop passing keyboard events to any intercept process whenever any
> process has enabled secure event input, whether that process is in the foreground or background."

An "intercept process" is explicitly defined there to include "Installation of an event tap as
defined in CoreGraphics/CGEvent.h". So whenever *any* process on the system has secure input on —
Terminal with "Secure Keyboard Entry", 1Password, a focused password field in many apps, the
loginwindow — your tap receives **no key events at all**. Two simultaneous failures while the
curtain is up:

1. Local keystrokes are **not suppressed**: they go straight to whatever app has focus, behind a
   black screen. The person at the keyboard can type into the remote user's session blind.
2. The password escape hatch stops working, silently.

**Fix:** poll `IsSecureEventInputEnabled()`
(`Carbon.framework/Frameworks/HIToolbox.framework/Headers/CarbonEventsCore.h:3044`) **[H]** —
before raising (refuse to raise, tell the user why) and periodically while raised (lift the curtain
and log the reason). Mouse events are unaffected, so "suppress the mouse only" is not a fallback:
without the keyboard you have neither containment nor an escape hatch.

### E7 (MAJOR) — `kCGEventTapDisabledByUserInput` is not handled

`CGEventTypes.h:131` defines `kCGEventTapDisabledByUserInput = 0xFFFFFFFF` alongside the timeout
constant, and `CGEvent.h:324` covers both ("If a tap becomes unresponsive **or a user requests taps
be disabled**"). **[H]** The plan handles only the timeout case. Both out-of-band types must be
handled identically (re-enable + log), and if re-enable fails, the curtain must lift.

### E8 (MAJOR) — an opaque full-screen curtain will freeze the remote picture (occlusion)

`NSWindow.h:186–189, 638` define `NSWindowOcclusionState`: "If set, at least part of the window is
visible. **If not set, the entire window is occluded.**" **[H]** Apple's Energy Efficiency Guide
tells apps to stop drawing when they lose `.visible`
(https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/WorkWhenVisible.html)
**[A]**, and well-behaved apps (Safari, media players, most Electron/Chromium apps, anything driving
a `CVDisplayLink`) do exactly that. A black, opaque, full-screen window on every display makes every
other window fully occluded. ScreenCaptureKit re-composites the display *without* your excluded
window — but it cannot invent frames that the occluded apps never drew. The remote viewer would get
a desktop that is technically "not black" and technically stale.

This defeats Task 2's acceptance criterion as written, and the criterion cannot detect it: "fetch a
frame and its content signature shows the desktop, not black" passes on a frozen desktop.

**Fix:**
- Do not present a fully opaque occluder. Empirically evaluate `setOpaque:NO` with
  `alphaValue = 0.999` and an opaque black backing colour (visually identical, defeats the occlusion
  heuristic in current AppKit — **[3P]/unverified**, must be measured, not assumed).
- Strengthen the acceptance test: with the curtain up, run something animated (a video, `while true;
  do date; done` in a Terminal) and require the remote frame signature to **change** across ≥2 s and
  ≥3 samples. "Not black" is not enough.
- Log `NSApplicationDidChangeOcclusionStateNotification` (`NSApplication.h:675`) while curtained so
  the failure is visible in the trail.

### E9 (MINOR, but will bite) — "state machine over typed characters" skips the hard part

A tap callback receives a `CGEventRef`, not characters. You need
`CGEventKeyboardGetUnicodeString` (`CGEvent.h:191`) **[H]** or `UCKeyTranslate`, plus decisions
about: dead keys, non-Latin layouts (a Russian layout produces no ASCII at all — if the VNC password
is ASCII the local user physically cannot type it without switching layout, and layout switching is
a keystroke you are swallowing), Caps Lock, autorepeat (`kCGKeyboardEventAutorepeat`,
`CGEventTypes.h:~178`), and `kCGEventFlagsChanged` (which must also be swallowed, or modifier state
leaks to the app underneath). None of this is in Task 1 or Task 3.

**Fix:** specify explicitly: swallow `keyDown|keyUp|flagsChanged`; feed only `keyDown` with
`autorepeat == 0` to the policy; obtain characters via `CGEventKeyboardGetUnicodeString`; document
the input-source caveat, or accept a keycode-based (layout-independent) password comparison.

### E10 (MINOR) — the event mask "keyboard and mouse" is incomplete

Missing at least: `kCGEventScrollWheel`, `kCGEventOtherMouseDown/Up/Dragged`,
`kCGEventTabletPointer`/`kCGEventTabletProximity` (all in `CGEventTypes.h:104–125`) **[H]**, and
system-defined events `NX_SYSDEFINED = 14`
(`IOKit.framework/Headers/hidsystem/IOLLEvent.h:113`) **[H]** which carry media/volume/brightness
keys and some special-key presses. Without `NX_SYSDEFINED` the local person can change volume,
brightness, and trigger media keys behind the curtain. Multi-touch gestures are also not fully
maskable through a CGEventTap — name that as a known gap rather than discovering it in QA.

---

## 2. What is MISSING

**M1 — No fail-closed path when the tap cannot be created.** `CGEvent.h:272–279`: if the process is
not trusted for assistive access, the key bits are cleared from the mask and "If that results in an
empty mask, then NULL is returned." **[H]** The plan never says what happens then. It must be: do
not raise the curtain at all. A black screen with fully live local input is strictly worse than no
curtain. Same for `SCShareableContent` failure, `updateContentFilter` failure, and any screen with
no matching `SCDisplay`. Add these as Task 2/3 acceptance criteria.

**M2 — Display hot-plug has no named API.** Use
`NSApplicationDidChangeScreenParametersNotification` (`NSApplication.h:647`) **[H]** and/or
`CGDisplayRegisterReconfigurationCallback` (`CGDisplayConfiguration.h:235`, flags incl.
`kCGDisplayAddFlag` at `:216`) **[H]**. Note the notification fires *after* the change; there is a
visible window during which a newly attached display shows the desktop unprotected. Also handle the
inverse: the captured display being unplugged while curtained (stream dies → must lift).

**M3 — `NSWindowSharingNone` is not considered, and it is the more robust primitive.**
`NSWindow.h:520–522`: "If you set your window sharing type to `NSWindowSharingNone`, so that the
content cannot be captured, your window will also not be able to participate in a number of system
services, so this setting should be used with caution." **[H]** Setting `sharingType = NSWindowSharingNone`
keeps the curtain out of *every* capture path with no `SCShareableContent` round-trip, no filter
rebuild, no window-creation race, and it keeps working when a display is hot-plugged. Use it
*together with* filter exclusion (belt and braces), not instead of evaluating it. Caveat worth
testing: third-party research claims AppKit can reset `sharingType` across some window operations
and recommends `orderFrontRegardless` (https://github.com/privateai0/macos-window-privacy-research)
**[3P, unverified]** — verify on your target OS.

**M4 — Toggle ordering and the visible race.** `getShareableContentWithCompletionHandler:`
(`SCShareableContent.h:146`) is asynchronous and not fast. If you order the window front and *then*
fetch content and rebuild the filter, the remote viewer sees a black frame for that interval; on
lift, the local user sees the desktop before the tap is torn down. Specify the exact order:
raise = set `sharingType` none → set collectionBehavior → `orderFrontRegardless` → fetch content →
`updateContentFilter:` → **only then** enable the tap;
lift = disable/release tap → `updateContentFilter:` back → `orderOut:`. Add an assertion that the
tap is never enabled while the window is not yet on screen.

**M5 — `SCWindow.windowID` ↔ `NSWindow.windowNumber` is asserted as fact but is not documented.**
`SCShareableContent.h:56` says `@property (readonly) CGWindowID windowID;` **[H]**;
`NSWindow.h:339` says `@property (readonly) NSInteger windowNumber;` with no statement that it is a
`CGWindowID` **[H]**. They *are* the same namespace in practice (this is the standard trick), but
the plan states it as documented. Additionally, `windowNumber` is only meaningful once the window
has a window device — read it after ordering front, and assert `> 0`.

**M6 — Which password, and its truncation.** Task 5 says "the VNC password lifts it" without
specifying the comparison. libvncserver's VNC auth is DES-based and the password is effectively
truncated to 8 characters (applied from memory: macVNC — VNC password effectively 8 chars, DES
truncates). If the stored setting is longer, the local user will type what they configured and the
comparison must agree with whatever the server actually accepts, or the escape hatch fails for a
subtle reason nobody will diagnose under a black screen. Specify: compare against the same truncated
string the server authenticates with; use a constant-time compare; and **never log the buffer**
(Task 4 step 3 says "log every raise and lift" — make it explicit that keystrokes are never logged).

**M7 — Dead/half-open client connections.** "Raise only while `vncConnectedClients > 0`" is only as
good as the disconnect detection. A half-open TCP connection can hold the count above zero for
minutes; during that time the owner stares at a black screen and the documented remedy ("it lifts
when the client disconnects") has already happened from the client's point of view. Require a
keepalive/idle timeout that lifts the curtain.

**M8 — Fast user switching, display sleep, screen lock, screen saver.** Not mentioned. At minimum:
on session deactivation (`NSWorkspaceSessionDidResignActiveNotification`) and on screen lock, drop
the curtain state and release the tap; decide what happens if the screen saver (same window level,
undefined z-order) starts while curtained.

**M9 — Window geometry.** Use `NSScreen.frame` (not `visibleFrame`), `NSWindowStyleMaskBorderless`,
`ignoresMouseEvents = NO`, `hidesOnDeactivate = NO`, `canBecomeKeyWindow` handling if you draw your
own field, and re-position on `NSApplicationDidChangeScreenParametersNotification`. Also decide the
behaviour with a notch/menu-bar and with mirrored displays (mirrored screens can share one
`CGDirectDisplayID`; `NSScreen` may or may not enumerate both).

**M10 — Packaging/signing is untouched but must not regress.** Adding source files changes the build
but must not change the release signing path: this bundle empirically requires the hardened-runtime
entitlement `com.apple.security.cs.disable-library-validation`, even with all bundled dylibs rebuilt
and signed by the same Developer ID; without it VNC password auth fails
(applied from memory: macVNC entitlement is mandatory; verify with the reference libvncclient at
/tmp/refclient, not vncdotool, which gives a false AUTH OK). Add to Task 5's verification: after
adding the curtain sources, re-run the packaging script and re-verify auth with the reference client
— because the curtain's escape hatch is that same password.

**M11 — No "panic" documentation.** The README section (Task 5 step 3) should state the recovery
procedure for the case where the app hangs: `ssh` in and kill the process, or power-cycle. Without
it, E4's residual risk has no user-facing mitigation.

---

## 3. Doubtful assumptions

**D1 — "Accessibility is already granted (we inject events through it), so no new permission
dialog."** Probably right, and the header supports it: `CGEvent.h:272–276` — taps at
`kCGHIDEventTap`, `kCGSessionEventTap`, `kCGAnnotatedSessionEventTap` "may only receive key up and
down events if access for assistive devices is enabled ... or the caller is enabled for assistive
device access, as by `AXMakeProcessTrusted`" **[H]**. The modern TCC split is
`kTCCServiceListenEvent` (Input Monitoring) for `kCGEventTapOptionListenOnly` vs
`kTCCServicePostEvent` (Accessibility) for `kCGEventTapOptionDefault` — corroborated only by
third-party write-ups
(https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-input-monitoring-screen-capture-accessibility.html)
**[3P]**, not by Apple documentation I could find. Do not assume: call
`CGPreflightPostEventAccess()` and `CGPreflightListenEventAccess()` (`CGEvent.h:399–408`) **[H]**
before raising, and treat a NULL from `CGEventTapCreate` as the authoritative answer (M1).

**D2 — "the local display shows black while the remote stream keeps showing the desktop."** True for
the composited stream (E-section 0), but conditional on E3 (Spaces/full-screen) and E8 (occlusion
staleness). As stated it is an over-claim.

**D3 — "Covering the login window ... The desktop is not rendered there, so neither the curtain nor
the capture apply."** Right conclusion, wrong reason. The login window *is* rendered — by
`loginwindow`, in a different session context; the real reason is that your app is not running in
that context and cannot draw or tap there. Fix the wording, since Task 5 is about honesty.

**D4 — "a crash must not leave a black screen ... the plan must not introduce anything that survives
the process."** Sound principle; incompletely applied. See E4 (hang, not crash). Also note that
`CGDisplayCapture`/shield-window APIs (`CGDirectDisplay.h:358–377`) would violate this principle —
good that the plan does not use them; state that explicitly so a future contributor does not "fix"
the full-screen coverage problem (E3) with `CGCaptureAllDisplays`.

**D5 — Task 3 acceptance "the remote viewer's injected input is unaffected" contradicts Task 3 step
2** ("verify empirically ... and if they are, tag and skip them"). One is an acceptance criterion,
the other admits the mechanism is unknown. Per E2 the answer is known in advance; make tagging a
requirement, not a contingency.

**D6 — Task 2's verification method.** "`tests/vnc_probe` fetches a frame and its content signature
shows the desktop, not black" is not sufficient (E8) and is also fragile: a mostly-dark desktop
wallpaper can produce a near-black signature. Use a known-changing on-screen source and assert
frame-to-frame delta.

**D7 — "one borderless window per `NSScreen`".** With mirrored displays and with
`NSScreen.screens` changing under you mid-raise, per-`NSScreen` enumeration can transiently miss a
display. Pair it with a post-raise assertion that the union of curtain frames covers the union of
all `NSScreen.frame`s, and re-assert on every screen-parameters notification.

---

## 4. VERDICT

**CONDITIONAL GO.** The architecture is the right one and the two load-bearing APIs
(`SCContentFilter initWithDisplay:excludingWindows:`, active `CGEventTap` at `kCGSessionEventTap`)
are real and behave as the plan hopes. But three of the plan's stated facts are wrong in ways that
change the design (E1 filter update, E2 injected-event feedback, E3 full-screen/Spaces coverage),
one of its central safety arguments is only half true (E4 hang vs crash), one documented OS
behaviour defeats both the containment and the escape hatch and is not mentioned at all (E6 secure
event input), and one physics-of-AppKit effect silently invalidates the main acceptance test (E8
occlusion). The Apple-precedent paragraph (E5) is not sourced and should not survive into the
README.

**Conditions to clear before implementation starts:**
1. Task 3 rewritten around source-tagged pass-through (E2) — not "verify empirically".
2. Task 2 rewritten to use `-updateContentFilter:` (E1), `collectionBehavior` with
   `CanJoinAllSpaces | FullScreenAuxiliary | Stationary | IgnoresCycle` (E3), and to evaluate
   `sharingType = NSWindowSharingNone` (M3).
3. A secure-event-input gate added to Tasks 3 and 4 (E6).
4. A non-blocking-callback rule + watchdog + monotonic-clock throttle added to Tasks 1 and 3 (E4).
5. Fail-closed behaviour specified for every construction failure (M1).
6. Acceptance test for Task 2 upgraded to "remote frame *changes*", plus a full-screen-app test
   (E8, E3).
7. The Apple curtain-mode quote removed or correctly attributed (E5).

**Maturity: 5/10.** Well-structured, honest about the human failure mode, correctly sequenced, with
real tests planned — but the API-level homework is roughly half done, and the half that is missing
(E2, E3, E6, E8) is exactly the half that determines whether the feature works or traps someone.
