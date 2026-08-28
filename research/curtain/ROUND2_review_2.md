# ROUND 2 — Adversarial safety audit: curtain mode

**Scope:** `/tmp/curtain-clean2.md` (implementation plan) only. SDK headers consulted: `SCStream.h`, `SCShareableContent.h`, `CGEvent.h`, `CGEventTypes.h`, `CarbonEventsCore.h`, `NSWindow.h` under `MacOSX.sdk`. No repository file was read or modified. Assumption per instructions: **every mitigation in the plan is implemented exactly as written**; findings below are what still goes wrong.

**Memory applied:** the macVNC signing/entitlement rule (`com.apple.security.cs.disable-library-validation` is mandatory for this bundle) is relevant only indirectly here — it surfaces in §2 as a missing TCC re‑grant step after re‑signing. The VNC-password-is-8-bytes finding is already correctly encoded in Task 1.2, and I credit it. *(applied from memory: entitlement mandatory / VNC password effectively 8 chars)*

---

## 0. What is genuinely well handled

Stated plainly, because it is unusual:

- **Facts 1–6 are the right six facts.** The tap-swallows-our-own-injection trap (fact 2, grounded in `CGEvent.h:255-258`/`347-352`), secure input inverting *both* halves (fact 3, confirmed by `CarbonEventsCore.h:2977-2984` — "keyboard input will only go to the application with keyboard focus, and will not be echoed to other applications"), the opaque-occluder/stale-frame trap (fact 4), hang-vs-crash asymmetry (fact 5), and Spaces/`collectionBehavior` (fact 6) are the five things naive implementations get wrong. Finding all five before the first line of code is above average.
- **Build order and raise order are in the fail-open direction.** Policy → window → tap; and window-up-before-tap-armed means a tap failure leaves *black screen + live input*, not the reverse. Correct.
- **`updateContentFilter:` rather than stop/start** is verified real and correct: `SCStream.h:487-492`, macOS 12.3+, with an error-carrying completion handler.
- **The acceptance test that requires the remote frame signature to CHANGE across ≥3 samples over ≥2 s** is the best line in the document. "Not black" would have passed a frozen desktop.
- **Edge-triggered raise** (Task 4.1) and **refuse to arm with no secret** (Task 1.4) are correct and non-obvious.
- **Capped throttle expressed as a deadline against a monotonic clock, never a sleep** (Task 1.3) — correct, and correctly tied to fact 5.
- **8-byte DES-truncated comparison** (Task 1.2) matches this project's empirically established VNC semantics.
- **Off by default, and the README explicitly names the remote party as the one who raises it** (Task 5.3). Honest.

---

## 1. Failure sequences that still end badly

Ordered by (severity × likelihood). Locations are plan sections in `/tmp/curtain-clean2.md`.

### F1 — P0 — Untrusted tap silently loses the keyboard half: black screen, live keyboard, dead escape hatch
**Location:** Task 3.2, Task 3.8. **Evidence:** `CGEvent.h:272-279`:
> "Taps placed at `kCGHIDEventTap`, `kCGSessionEventTap` … may only receive key up and down events if access for assistive devices is enabled … **If the tap is not permitted to monitor these events when the tap is created, then the appropriate bits in the mask are cleared. If that results in an empty mask, then NULL is returned.**"

**Sequence:** app is re-signed / updated / TCC reset → Accessibility trust lost → curtain raised → windows shown → `CGEventTapCreate` with keyboard **and** pointer mask → keyboard bits are silently stripped, pointer bits survive → **non-NULL** tap returned → plan treats non-NULL as success → local screen black, mouse dead, **keyboard fully live into invisible applications**, and the tap escape path never sees a single key. The second escape path is itself broken (F2). Local user types blind into whatever has focus, remote party watches it.

This is the single most likely way to reach the worst state, because "tap created successfully" is exactly the check the plan implies.

**Smallest fix:** before raising, require `AXIsProcessTrustedWithOptions(@{kAXTrustedCheckOptionPrompt: @NO})`; refuse to raise if false. After creating the tap, verify the *effective* mask via `CGGetEventTapList` / `CGEventTapInformation.eventsOfInterest` and abort the raise if any requested bit is missing. (The `CGEventTapInformation` field name should be confirmed against `CGEventTypes.h` at implementation time — not verified in this pass.)

### F2 — P0 — The "two independent input paths" are one path, and the second one cannot fire as specified
**Location:** Task 2.1 vs Task 3.4 — direct internal contradiction.
Task 2.1: `orderFrontRegardless` "so we never steal focus or activate the app."
Task 3.4: "the curtain window itself as key window with a view implementing `keyDown:`."

A borderless `NSWindow` returns `NO` from `canBecomeKeyWindow` unless subclassed (`NSWindow.h:438` is read-only; the override point is a subclass), **and** a window cannot be key while its application is inactive. `orderFrontRegardless` explicitly does not activate. So as written, path 2 never receives a keystroke. The invariant the plan itself declares — "the curtain may never be in a state where zero paths reach the policy" — is violated in exactly the two cases the second path exists for: tap disabled by timeout, and secure input.

**Smallest fix:** decide and write down the focus policy (see F3). At minimum: subclass with `canBecomeKeyWindow = YES`, and state explicitly when the app activates.

### F3 — P0 — The obvious fix to F2 breaks remote control and is not covered by the event-source tagging
**Location:** Task 3.1 vs Task 3.4.
If the curtain window *is* made key, then keyboard events delivered to the frontmost application go to the curtain view — **including the remote viewer's injected keystrokes**, which are posted at `kCGHIDEventTap` and delivered normally to the key window. The magic `kCGEventSourceUserData` tag (Task 3.1) is read **only in the tap callback**; the AppKit `keyDown:` path has no such check. Result: the remote user types into a black window that interprets their keystrokes as failed unlock attempts, throttles, and drops them. Remote control is dead while the curtain is up — the product's primary function.

**Smallest fix:** in `keyDown:`, take `event.CGEvent`, read `kCGEventSourceUserData` / `kCGEventSourceUnixProcessID`, and ignore self-injected events. Better: make the curtain key **only** while the tap path is known-unavailable (secure input active, or tap disabled), and resign key otherwise. This is a design decision the plan currently leaves unmade, and it is load-bearing.

### F4 — P0 — Stream dies *after* the raise: "black locally, nothing remotely" — the state the doc says must never exist
**Location:** Task 2.3 (checks the completion handler at raise only). Nothing anywhere handles `SCStreamDelegate stream:didStopWithError:` while curtained.
**Sequence:** curtain up (filter swapped successfully, windows shown) → any of: display disconnect/reconfigure, wake from system sleep, resolution change, TCC screen-recording permission revoked while running, `replayd`/SCK daemon crash → stream stops asynchronously → curtain windows are still composited by WindowServer, the tap is still swallowing local input → **local user blind and mute, remote viewer sees nothing.** Only the password lifts it, and if the peer connection is also half-open (Task 4.3) nothing else will.

The plan's own framing ("Restarting the capture … on failure leave the curtain up with a dead stream — the exact state this feature must never produce") shows the authors understood the raise-time case and then did not generalise it to the running case.

**Smallest fix:** treat "a live stream + ≥1 authenticated client" as a **continuously enforced invariant**, not a raise-time precondition. Any stream stop or error while curtained lifts the curtain from the lifecycle queue and logs the reason.

### F5 — P0 — Main-thread wedge: both escape paths dead, and the watchdog as specified cannot rescue it
**Location:** Task 3.7 ("a watchdog … tears the window down from that queue"), Task 3.3. The plan never says **which run loop the tap source is attached to** (`CGEvent.h:290-292`: "The event tap callback runs from the CFRunLoop to which the tap CFMachPort is added as a source").
**Sequence:** tap source added to the main run loop (the default choice) → main thread blocks (SCK/TCC prompt, modal alert, a spin inside AppKit or the VNC server, a deadlock on a shared lock) → callback stops running → WindowServer disables the tap after ~1 s (`kCGEventTapDisabledByTimeout`, `CGEventTypes.h:130`) → local input restored (good) but `keyDown:` is also main-thread, so **both escape paths are dead** → the black window remains composited, because WindowServer composites it regardless of whether the app is alive.

Then the watchdog fires and tries to "tear the window down from that queue" — **`NSWindow` teardown is main-thread-only**. From a background queue it either does nothing useful, hops to the main queue and blocks forever, or is undefined behaviour. **The watchdog, as written, cannot fix the failure it exists for.**

**Smallest fix:** (a) run the tap on a dedicated thread with its own `CFRunLoop`, never the main run loop; (b) the watchdog's action must be **process-level** — `abort()`/`_exit()` — since the plan's own fact 5 establishes that process death self-heals both the window and the tap. Add a main-thread heartbeat as the thing the watchdog watches.

### F6 — P1 — Watchdog false positive: an idle user lifts the curtain
**Location:** Task 3.7 — "the callback pings it; no ping for N seconds while curtained tears the window down."
No local input means no callbacks means no pings. A user who walks away for N seconds triggers an automatic lift — the feature silently disables itself in the exact scenario it is for (nobody typing at the machine). Raise N to avoid that and the hang detection becomes useless.
**Smallest fix:** the watchdog must measure **callback in-flight duration** (timestamp stamped on entry, cleared on exit) plus an independent main-thread heartbeat timer. Event arrival is not a liveness signal.

### F7 — P1 — Secure-input check-then-act race discloses the VNC password to the remote viewer
**Location:** Task 3.6 — refuse to raise if enabled, poll at ~1 Hz thereafter.
The check and the raise are not atomic, and 1 Hz leaves up to a full second after any transition. Within that window (keychain prompt, password manager, a focused password field, Terminal Secure Keyboard Entry): keys bypass the session tap (`CarbonEventsCore.h:2977-2984`), the curtain does **not** suppress them, and the local owner typing what they think is the unlock password types it into a focused app **that the remote party is watching**. This is the disclosure the plan itself calls the worst outcome; the 1 Hz poll does not close it, only shortens it.
Also: `IsSecureEventInputEnabled()` is documented **"Mac OS X threading: Not thread safe"** (`CarbonEventsCore.h:3055-3056`), and the plan calls it from the lifecycle queue.
**Smallest fix:** poll on the tap's own thread at a much higher rate (the call is cheap), and additionally treat "keyboard events stopped arriving at the tap while pointer events continue" as a fast secure-input heuristic. Most importantly, the escape hatch must not depend on the tap at all (F2/F3), so that under secure input the characters land in *our* window — invisible to the remote stream — rather than in someone else's.

### F8 — P1 — Sleep / wake / screensaver / lock / fast user switching are unhandled transitions
**Location:** nothing in Tasks 2–4 mentions them.
- **Sleep→wake with "require password":** loginwindow enables secure input → Task 3.6 lifts the curtain. Because raising is edge-triggered on *connect* (Task 4.1), the curtain **never comes back** for that still-connected session. The remote party keeps working; the local screen is now fully visible. Privacy expectation silently broken, and neither Task 4 nor Task 5 says so.
- **Screensaver without a password:** the curtain sits at `NSScreenSaverWindowLevel` = `kCGScreenSaverWindowLevel` (`NSWindow.h:201`) — the **same level as the screensaver**. Z-order between two windows at the same level is not specified. If the screensaver wins, the local screen is no longer our curtain, and the remote stream shows the screensaver (we excluded only *our* windows), so the remote viewer loses the desktop. Meanwhile the tap swallows the keystroke that would dismiss it, so the local user is stuck at a screensaver they cannot dismiss without knowing the VNC password.
- **Fast user switching:** `NSWorkspaceSessionDidResignActiveNotification` / DidBecomeActive — the session tap and our windows go inactive and the tap may not survive the round trip. Not covered even as a non-goal transition.
**Smallest fix:** hold an `IOPMAssertion` (`kIOPMAssertionTypePreventUserIdleDisplaySleep`) while curtained; subscribe to screensaver-start, `NSWorkspaceScreensDidSleep/WillSleep`, and session-resign notifications, and lift on all of them; and decide+document whether the curtain re-raises after such a lift (recommended: it does not, and the log says why).

### F9 — P1 — The documented escape "the system's own lock still reaches the real Lock Screen" is only half true
**Location:** Non-goals, paragraph 1; README wording in Task 5.3.
An active session tap that returns NULL consumes keyboard-driven system actions, including Ctrl-Cmd-Q and menu-driven Lock Screen. What actually survives is **hardware only**: power button, lid close, Touch ID, force-restart. Telling a blinded owner that "the system's own lock still reaches the Lock Screen" invites them to try a path that has been swallowed.
**Smallest fix:** narrow the README sentence to the hardware paths, and verify Ctrl-Cmd-Q behaviour on device as an explicit checklist item.

### F10 — P1 — The remote party can invalidate the local escape hatch by changing the password
**Location:** Task 1.5 — "the policy takes the secret at each comparison rather than caching it at raise time."
The stated motivation is benign (the owner changes the password). Adversarially: the remote party who raised the curtain changes the VNC password → the local user's only way back in silently becomes a secret they do not know. Same for the password being cleared: Task 1.4 refuses to *arm* with an empty secret, but nothing lifts an already-raised curtain when the secret becomes empty.
**Smallest fix:** **lift the curtain on any change to the secret** (including clearing). That satisfies both the benign motivation and the adversarial one, and it is simpler than either caching policy.

### F11 — P1 — A local lift is only a temporary reprieve; reconnect re-blinds
**Location:** Task 4.1 — "a local lift latches 'down' until the next connection."
An attacker (or a flaky client) simply disconnects and reconnects to raise the curtain again. Loop it and the local user is permanently blinded, with the documented last resort being "ssh in and kill the app" (Task 5.4) — which a blinded local user cannot perform *on that machine*. The escape hatch is defeated by a trivially automatable action from the party the threat model names.
**Smallest fix:** after a **local** lift, latch down for the remainder of the app run (or until the user re-enables it in Preferences). Log it. A remote-initiated lift or a disconnect may reset the latch; a local unlock must not.

### F12 — P1 — Raise ordering is unsatisfiable as written, and the natural "fix" opens the exposure it was designed to close
**Location:** Task 2.4 — "create windows → resolve their `SCWindow`s → update the filter → only then show them."
`SCShareableContent` enumeration is on-screen-oriented (`SCShareableContent.h:156-162` exposes `onScreenWindowsOnly`; the plain `getShareableContentWithCompletionHandler:` is the on-screen variant). A window that has never been ordered in is not on screen, so its `SCWindow` may not be enumerable — resolution fails every time and the feature never raises, or the implementer "fixes" it by showing the window first, which means the remote viewer sees black for one or more frames, and if the filter update then fails (Task 2.3 tears the window down) the remote sees black while the teardown races.
**Smallest fix — recommended, and it also closes F13/2.5:** use `-[SCContentFilter initWithDisplay:excludingApplications:exceptingWindows:]` (`SCStream.h:174-180`) with our own `SCRunningApplication` in the exclusion list, instead of per-window IDs. It is order-independent, needs no `SCShareableContent` round trip on the raise path, survives window recreation, and makes display hot-plug (Task 2.5) a pure window-creation problem with **no** filter-update exposure window. Cost: our Preferences window is also excluded from the remote stream — state that in the README (arguably desirable anyway).

### F13 — P2 — Display hot-plug exposure window is real but understated
**Location:** Task 2.5 — "a screen attached while curtained has a brief exposure window before we react."
`NSApplicationDidChangeScreenParametersNotification` is delivered on the main thread. If the main thread is even briefly busy (F5), "brief" becomes unbounded, and the exposure is the *full desktop on a new monitor* — precisely the thing an attacker with the VNC password and physical proximity would arrange. Adopting F12's application-exclusion filter reduces this to "create and show a window", removing the async filter round trip from the critical path.

### F14 — P2 — Event mask is incomplete; "local input is blocked" is not literally true
**Location:** Task 3.2. The enumeration (keyboard, moves, drags, buttons, scroll, gestures, flags-changed) omits `NX_SYSDEFINED`-class events. Hardware media/brightness/volume keys and some special keys therefore pass through. Low harm, but the Preferences help text (Task 5.2) says local input is blocked. Either add the mask bits or soften the wording.

### F15 — P2 — Untaggable injection paths deserve a decision, not an open question
**Location:** Task 3.1 — "identify every injection path in `MacVNCInput.m` and state how each is handled."
Concretely: `CGWarpMouseCursorPosition` moves the cursor without a taggable event; any resulting mouse-moved event carries no user data and will be **swallowed by our own tap**, so the remote cursor appears frozen while clicks still land. `CGAssociateMouseAndMouseCursorPosition` has the same problem.
**Smallest fix:** make it a requirement, not an investigation — replace warp with `CGEventCreateMouseEvent(taggedSource, kCGEventMouseMoved, …)` + `CGEventPost`, so every injection path is taggable.

### F16 — P2 — Tap teardown is a cross-thread lifetime hazard
**Location:** Task 3.8. Invalidating the `CFMachPort` / removing the run-loop source from a thread other than the one running the callback is a use-after-free class of bug, and it will be tempting to do it from the lifecycle queue on the lift path.
**Smallest fix:** prescribe the order — `CGEventTapEnable(tap, false)` and `CFRunLoopSourceInvalidate` **on the tap's own thread**, then release.

### F17 — P2 — Turning the preference off while curtained is undefined
**Location:** Task 5.1 registers the key; nothing says the curtain lifts when it flips to off. It must, immediately.

---

## 2. What is MISSING

1. **Asynchronous stream-health handling** (`SCStreamDelegate`) while curtained — F4. Biggest single omission.
2. **Accessibility/TCC precondition and effective-mask verification** — F1.
3. **A stated focus policy for the curtain window.** The plan contains two mutually exclusive requirements (F2/F3) and never resolves them.
4. **Which run loop / thread the tap lives on.** Never stated; the default choice is the dangerous one — F5.
5. **A workable definition of watchdog liveness**, and a main-thread heartbeat — F5/F6.
6. **Power/lock/session transitions**: sleep, wake, screensaver, lock screen, fast user switching — F8.
7. **Secret-change and preference-off handling while curtained** — F10/F17.
8. **An honest statement of what "fail open" actually covers.** Only two mechanisms live outside the failing component: WindowServer's tap timeout (restores *input*, not the screen) and process death (restores both). Everything else in the plan — re-enable, lift-on-secure-input, watchdog teardown, lift-on-filter-failure — runs inside the code that just failed. The design should say: **input fails open; the screen fails open only via process exit** — and build the watchdog on `abort()` accordingly.
9. **Automated coverage above Task 1.** Only the pure policy is testable; the entire dangerous surface (raise/lift ordering, latch semantics, watchdog, secure-input transition, stream-death) is manual on-device checking with no fault injection. Missing: a headless `CurtainController` with injected clock / tap / window / stream protocols so those state transitions are unit-testable and mutation-testable. Without it, the first regression here is discovered by a blind user, not by CI.
10. **An explicit "curtain state never persists" invariant.** The plan says "must not introduce anything that survives the process", but Task 5 adds a persisted defaults key. Needed: the *key* persists, the *raised state* never does, and nothing raises at launch.
11. **TCC re-grant after re-signing.** This feature adds an Accessibility/Input-Monitoring dependency to a bundle that must be signed with hardened runtime plus `com.apple.security.cs.disable-library-validation` for VNC auth to work at all in release builds. Changing signing or bundle identity resets TCC grants; nothing in Task 5 or the verification list covers "after a signed/notarized update, the tap silently loses its keyboard bits" — which is F1's most likely trigger in the field. *(applied from memory: entitlement is mandatory for this bundle and re-signing changes TCC identity)*
12. **VoiceOver / assistive users.** The one layer that draws above the curtain is also the layer a blind local user depends on; with input swallowed they get no feedback at all. One README line.
13. **Constant-time password comparison** and a rate limit on the raise/lift logging. Minor, but the log is the audit trail.
14. **A dead-man's lift** (report-only): if the remote session shows no input for N minutes, lift. Cheapest insurance for an owner who does not know the password.

---

## 3. Doubtful assumptions

| # | Assumption | Why it is doubtful |
|---|---|---|
| A1 | `setOpaque:NO` + alpha just under 1 keeps other apps drawing (Task 2.2) | Undocumented. `NSWindow.h:186` defines occlusion only for the *queried* window and even says "windows that are completely transparent may also still count as visible" — it says nothing about how a translucent window affects **other** windows' occlusion state. This is empirical behaviour that Apple can change. The animated test is right, but it must run against a real occlusion-honouring app (Safari playing video), not a bespoke test window. |
| A2 | Alpha just under 1 looks black | No luminance criterion anywhere. A white full-screen window under a 0.98 curtain in a dark room is readable. The acceptance test says "confirm black locally" with no measurement. |
| A3 | An active session tap suppresses *all* local input | False for system-defined events (F14) and for hardware paths (F9). Preferences text and README overclaim. |
| A4 | 1 Hz `IsSecureEventInputEnabled()` polling is a sufficient guard | Check-then-act race, up to 1 s of password disclosure (F7); and the API is documented not thread safe (`CarbonEventsCore.h:3055-3056`) while the plan calls it off the main thread. |
| A5 | `SCWindow.windowID` == `NSWindow.windowNumber` so resolution is easy | The identity is fine; the *enumerability* is not (F12). |
| A6 | "`kill -9` leaves neither a black screen nor suppressed input" | True for SIGKILL only. Not true for SIGSTOP/suspension, and not true for the wedged-but-alive process, which is the realistic hang (F5). The checklist tests the easy case and skips the one fact 5 identified as the dangerous one. |
| A7 | "The curtain fails OPEN whenever its own preconditions stop holding" | Not achievable as designed — the detectors live inside the component that fails. See §2 item 8. |
| A8 | Client count is only wrong because of half-open TCP (Task 4.3) | Also: connected-but-unauthenticated clients, and multi-client transitions (does 1→2 count as "the transition to connected"? Task 4.1 is ambiguous, and the answer determines F11's severity). Define "connected" as *authenticated and receiving framebuffer updates*. |
| A9 | 8-byte comparison is the whole credential story | Correct for DES truncation, but the curtain must compare against the **same** secret the server authenticated with (password file vs. preference), and no constant-time comparison is specified. |

---

## 4. VERDICT

**CONDITIONAL — GO for Tasks 1 and 2 (with F12 adopted); NO-GO for Task 3 as written.**

Task 3 currently contains one unresolvable internal contradiction (F2/F3), one unimplementable mitigation (F5 watchdog), one silent-partial-failure mode with no detection (F1), and a watchdog that misfires on idle (F6). Implementing it exactly as written produces a feature that, in ordinary field conditions — a re-signed build, a display wake, or a busy main thread — leaves a person unable to see their screen with no working way back in.

**Maturity: 6 / 10.** The threat analysis is well above average and the six facts are correct and verified against the SDK. The gaps are concentrated in exactly the two places the task brief predicted: *state that survives a failure in the middle of a sequence* (stream death after raise, TCC-degraded tap, main-thread wedge) and *whether fail-open is reachable from inside the component that failed* (it mostly is not). Nothing here is unfixable; all of it is cheaper to fix now than after Task 3 exists.

**Conditions to clear before writing Task 3 code:** F1, F2/F3 (write down the focus policy), F4, F5, F6, F7, F10, F12. F8, F9, F11 before shipping.

**Commands a supervisor must run (none were run by me):** `ctest -R curtain_policy`, `tests/mutate.sh`, and the on-device checks in the plan's Verification section — plus three new ones: (a) revoke Accessibility trust, then attempt to raise, and confirm refusal rather than a keyboard-live curtain; (b) curtain up, then disconnect a display / sleep and wake, and confirm the curtain lifts rather than persisting over a dead stream; (c) curtain up, `kill -STOP` the app, and record what the local user sees and can do.

---