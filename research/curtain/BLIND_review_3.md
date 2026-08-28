I applied both macVNC memories: the entitlement/library-validation one turned out **not** to be directly in scope (the plan touches no signing/packaging), so I note only its second-order consequence; the "VNC password is effectively 8 chars, DES truncates" fact **is** directly load-bearing for the escape-hatch design and is cited inline below.

---

# BLIND security review — Curtain mode plan (`/tmp/curtain-clean.md`)

Reviewer role: security critic. Scope read: the plan only, plus macOS SDK headers under
`/Applications/Xcode.app/.../MacOSX.sdk`. No repository files, no git history, no other review.
Web search tool was not available in this run; every external claim below is instead backed by an
SDK header citation with file and line, or explicitly marked as "must be verified on device".

---

## 0. What is genuinely good (say it plainly)

These are not filler; they are the parts I tried to break and could not.

- **The API reading is correct.** `-[SCContentFilter initWithDisplay:excludingWindows:]` exists and
  its documented semantics are exactly what the plan assumes — the display is captured *with the
  excluded windows removed*, desktop and Dock included
  (`ScreenCaptureKit.framework/.../SCStream.h:149-154`). `SCWindow.windowID` is a `CGWindowID`
  (`SCShareableContent.h:54-56`), so matching it against `NSWindow.windowNumber` is sound.
- **The event-tap mechanics are correct.** `kCGEventTapOptionDefault` is the active/filtering option
  (`CGEventTypes.h:417-419`), and returning `NULL` from the callback deletes the event
  (`CGEventTypes.h:441-442`). Non-root processes may tap at `kCGSessionEventTap`
  (`CGEvent.h:269-271`), and key events require assistive-device access (`CGEvent.h:272-277`).
- **The crash-self-heals reasoning is correct.** "Releasing the `CFMachPortRef` will release the tap"
  (`CGEvent.h:284`); a tap is a Mach port owned by the process, so process death removes both tap and
  window. The `kill -9` acceptance check is the right check and I would keep it verbatim.
- **The build order is right.** Policy → window → input suppression puts the piece that can trap a
  human last, behind a tested escape hatch. That is a genuinely good sequencing decision.
- **The non-goals are unusually honest** for this class of feature: "the Mac stays unlocked", power
  button / lid / system lock still work, "this is privacy from onlookers", "the UI must not promise
  more". Most curtain-mode implementations lie about exactly this. Keep that tone.
- **Not requiring Remote Management is a real, correct advantage** and is stated without overclaiming.

The problems below are about the gap between this plan and a plan that survives contact with
`IsSecureEventInputEnabled`, Spaces, occlusion, and a hostile viewer.

---

## 1. Errors

### E1 — P0 — Remote injected input *will* be swallowed. This is not an open question.

Plan, Task 3 step 2: *"verify empirically that injected events are not fed back into our own tap,
and if they are, tag and skip them."*

The header settles it before any experiment:

> "Taps may be placed at the point where HIDSystem events enter the server, **at the point where
> HIDSystem and remote control events enter a session**, at the point where events have been
> annotated to flow to a specific application…" — `CoreGraphics.framework/.../CGEvent.h:256-260`

`kCGHIDEventTap = 0`, `kCGSessionEventTap = 1`, `kCGAnnotatedSessionEventTap = 2`
(`CGEventTypes.h:402-406`) — the session tap is strictly downstream of the HID tap. An event posted
with `CGEventPost(kCGHIDEventTap, …)` therefore traverses our session tap by construction. With an
active session tap returning `NULL` for all keyboard and mouse events, **the remote viewer's own
keystrokes and clicks die**, and the feature defeats itself: a black local screen plus a remote
session that cannot type.

This means Task 3's stated acceptance criterion ("the remote viewer's injected input is unaffected")
has no design behind it — only a hope plus a fallback sentence.

Smallest fix: make the tagging mandatory, not conditional. Stamp injected events from a dedicated
`CGEventSource` and pass them through on `kCGEventSourceUserData` (`CGEventTypes.h:354-356`) or
`kCGEventSourceStateID` (`CGEventTypes.h:366-368`); everything untagged is swallowed. Add a
non-manual test: curtain up → inject a key → assert it lands in a text field; inject a
locally-sourced event → assert it is dropped.

Related detail to specify: pointer *motion* done via `CGWarpMouseCursorPosition` generates no tappable
event, so motion may work while buttons die — a confusing half-broken state if E1 is left unfixed.

---

### E2 — P0 — Secure input mode silently produces the exact "worst mix" the plan names, and leaks the VNC password to the remote viewer.

`EnableSecureEventInput()` / `IsSecureEventInputEnabled()` —
`Carbon.framework/.../HIToolbox.framework/.../CarbonEventsCore.h:2971-3004` and `:3044-3064`:

> "When secure event input is enabled, keyboard input will only go to the application with keyboard
> focus, and **will not be echoed to other applications that might be using the event monitor target
> to watch keyboard input**." — `CarbonEventsCore.h:2977-2982`

Secure input is enabled by ordinary things: Terminal's "Secure Keyboard Entry", a focused password
field, keychain/authorization prompts, most password managers. While it is on:

1. our tap receives no key events, so **local keystrokes are not suppressed** — black screen, live
   keyboard, which the plan itself calls "the worst mix";
2. the local owner types the unlock password to escape; it is not intercepted, so it goes **into the
   focused application** — which is *visible in the remote stream*. The escape hatch becomes a
   plaintext disclosure of the VNC password to the very remote party the owner is reacting to.

Nothing in the plan mentions secure input.

Smallest fix: while curtained, watch `IsSecureEventInputEnabled()` (poll on the existing lifecycle
queue is sufficient). On transition to true, **lift the curtain** (fail open — consistent with the
plan's own top priority) or at absolute minimum stop accepting password characters and render a
visible on-curtain warning. Document it in the README limits.

---

### E3 — P1 — Only one of the two tap-disable reasons is handled, and re-enabling is not enough.

Plan handles `kCGEventTapDisabledByTimeout`. The enum has two:

```
kCGEventTapDisabledByTimeout   = 0xFFFFFFFE,
kCGEventTapDisabledByUserInput = 0xFFFFFFFF
```
— `CGEventTypes.h:128-132`

Two problems:

1. `ByUserInput` is unhandled → curtain stays up, input flows.
2. "Re-enable and log" is insufficient. During the disabled window, keystrokes reach the focused app
   — including a partially typed unlock password (same leak as E2). And the disable notification can
   itself be missed if the runloop is starved, which is precisely the condition that caused the
   timeout.

Smallest fix: handle both constants; add a periodic watchdog using `CGEventTapIsEnabled()`
(`CGEvent.h:330-333`); and gate the policy so password characters are only accepted when the tap is
confirmed enabled at that instant. Treat "tap not enabled for more than N ms while curtained" as a
lift condition, not a log line.

---

### E4 — P1 — `NSScreenSaverWindowLevel` is not the top level; the cursor and assistive/system overlays stay visible.

```
#define kCGScreenSaverWindowLevel       ((CGWindowLevel)1000)
#define kCGAssistiveTechHighWindowLevel ((CGWindowLevel)1500)
#define kCGCursorWindowLevel            ((CGWindowLevel)(kCGMaximumWindowLevel - 1))
```
— `CoreGraphics.framework/.../CGWindowLevel.h:79-81`

So at level 1000 the curtain is below the cursor and below assistive-technology overlays. Concretely:
**the remote user's mouse pointer remains visible on the local screen**, tracing menu selections and
password-field positions in front of the onlooker the feature exists to defeat. VoiceOver/Zoom
overlays, and possibly system HUDs (volume, brightness), Siri, and notification banners, may also
draw above it.

Smallest fix: use `CGShieldingWindowLevel()` — the documented level of the shield window
(`CGDirectDisplay.h:374-378`) — and hide the cursor while curtained. Then verify **on device**
against: notification banners, volume/brightness HUD, Siri, VoiceOver, the screen-recording privacy
indicator, and an active screen saver. Add each to the acceptance list; "black" should mean black.

---

### E5 — P1 — Spaces and full-screen apps: the curtain does not follow, so the desktop is exposed locally.

Task 2 step 1 creates "one borderless window per `NSScreen`" and never mentions
`collectionBehavior`. A default window lives on **one Space**. The remote viewer routinely switches
Spaces or enters a native full-screen app; the curtain does not follow, and the local display shows
real content. The local user cannot switch back (input is swallowed), so this state persists.

Smallest fix: `NSWindowCollectionBehaviorCanJoinAllSpaces | …Stationary | …FullScreenAuxiliary |
…IgnoresCycle`, and add "remote viewer enters a native full-screen app → local screens stay black" to
Task 2 acceptance. Full-screen Spaces are the hard case and must be tested explicitly, not assumed.

---

### E6 — P1 — Opaque full-screen curtain marks the desktop occluded; the remote stream goes stale.

An opaque window covering the whole screen above everything drives AppKit's occlusion machinery
(`NSWindowOcclusionState` / `NSApplicationDidChangeOcclusionState`). Well-behaved apps stop drawing,
pause animations, pause video, throttle WebKit timers. The remote viewer then sees a **frozen**
desktop — which breaks the headline promise ("live remotely") for exactly the content people watch.

The plan's own verification cannot catch this: *"its content signature shows the desktop, not black"*
passes on a single stale frame.

Smallest fix: `setOpaque:NO` with a black background at alpha just under 1.0 so underlying windows are
not considered occluded (the remote view is unaffected — those windows are excluded from the filter
anyway). Strengthen Task 2 acceptance to: with the curtain up and a video/animation playing, **two
frames taken seconds apart differ**.

---

### E7 — P1 — The plan never states who raises the curtain, and the honest answer is "the remote party".

Task 4 step 1: *"Raise only while `vncConnectedClients > 0`"*; Task 5 offers one boolean preference.
Read literally, a remote connection raises the curtain. The security consequence is not in the
document:

> Anyone holding the VNC password can, at will, blind the person sitting at the Mac, kill their
> keyboard and mouse, and operate the machine invisibly.

Today an attacker fighting the local owner for the mouse is instantly obvious and the owner can lock
or unplug. This feature removes that signal. And the "way back in" is the *same* VNC password the
attacker already used to connect — a single shared static secret that libvncserver's DES
authentication truncates to **8 effective characters**
*(applied from memory: macVNC's VNC password is effectively 8 chars — DES truncates)*.

This is the single most important thing missing from a plan whose entire framing is about honesty.

Smallest fixes (all absent):
- Threat model paragraph stating the above, and pref/README text saying, plainly: *"any viewer who
  knows the VNC password can hide your screen and block your keyboard."*
- The curtain message must name the connected client (address) and the time it was raised — Task 2
  says only "a short message".
- Seriously consider a **separate local unlock secret** from the remote auth secret, so the escape
  hatch is not knowledge every remote party already has. If you keep the VNC password, say so
  explicitly in the UI (Task 5 step 2 does name it — good — but does not draw the consequence).

---

### E8 — P0/P1 — Level-triggered raise makes the escape hatch a no-op (permanent lockout loop).

"Raise while `clients > 0`" is a *level* condition. The lift is an *event*. If the raise rule is
evaluated on a level basis — or re-evaluated on any later client-count change, reconnect, or second
client — then typing the password lifts the curtain and it immediately re-raises. The owner is
permanently locked out of an unlocked Mac except via the power button. That is the plan's own
stated number-one failure mode, reachable from its own wording.

Even with edge-triggering, nothing stops a hostile viewer from disconnecting and reconnecting in a
loop to re-blind the owner. There is no cooldown, no "local lift wins" latch.

Smallest fix: specify the raise as edge-triggered once per connection, **and** make a local
password lift sticky — curtain refused for the remainder of that connection (preferably until the
local user re-arms it). Add the test: connect → curtain → lift → assert it stays down while the same
client is still connected, and that local input works.

---

### E9 — P1 — "Lifts when the last client disconnects" depends on noticing the disconnect.

A half-open TCP connection (attacker's laptop lid closed, Wi-Fi dropped) keeps
`vncConnectedClients > 0` until a write fails or TCP keepalive expires — default macOS keepalive idle
is on the order of **two hours**. The owner is behind a black screen with dead input, and the only
recovery is the password (which does work) or the power button. The plan's promise "the curtain lifts
by itself when the remote session ends" is therefore not true for the failure mode most likely to
occur.

Smallest fix: enable aggressive TCP keepalive on client sockets, and/or a curtain watchdog (no
framebuffer-update request from any client within N seconds → lift), and/or a hard maximum curtain
duration. At minimum, document the dependency.

---

### E10 — P2 — The permission claim is asserted rather than checked, and is not future-proof.

Plan: *"Accessibility is already granted (we inject events through it), so no new permission dialog."*

The header text the plan is implicitly relying on (`CGEvent.h:272-277`) predates macOS 10.15, which
split listening from posting — which is exactly why these exist:

```
/* Checks whether the current process already has event listening access */
CG_EXTERN bool CGPreflightListenEventAccess(void) API_AVAILABLE(macos(10.15));
/* Requests event listening access if absent, potentially prompting */
CG_EXTERN bool CGRequestListenEventAccess(void)   API_AVAILABLE(macos(10.15));
```
— `CGEvent.h:397-402`

In practice an Accessibility grant usually covers tap listening, but the plan must not *depend* on
"usually", and the grant can be revoked at any moment — including while curtained, which lands you
back in E2's failure state. Note also that any signing-identity change can re-trigger TCC prompts
*(second-order consequence of the packaging/entitlement history in memory: this app already needs
hardened runtime + `disable-library-validation`; re-signing has previously changed runtime
behaviour, so a "permission is already there" assumption is exactly the kind that has bitten this
project before)*.

Smallest fix: call `CGPreflightListenEventAccess()` before every raise; if false, **do not raise**.
Never display a curtain you cannot back with a working tap.

---

### E11 — P2 — `updateContentFilter:` exists; the stream does not have to restart.

Plan, Task 2 step 3: *"the exclusion list is fixed at filter creation, so the capture stream restarts
on toggle."* The first half is right, the conclusion is wrong:

```
- (void)updateContentFilter:(SCContentFilter *)contentFilter
          completionHandler:(nullable void (^)(NSError *_Nullable error))completionHandler
```
— `SCStream.h:486-492` ("this method will update the content filter for a content stream")

Using it removes a restart window during which capture is stopped while the curtain is already up,
and avoids a visible remote glitch on every toggle.

Related, and better than enumerating window IDs: `initWithDisplay:excludingApplications:
exceptingWindows:` (`SCStream.h:174-180`) excluding **our own** `SCRunningApplication` covers every
window we ever create — including curtain windows added later on display hot-plug (Task 2 step 4) —
without the async `SCShareableContent` race the current design has. Trade-off: our preferences/status
windows also disappear from the remote view, which for this feature is probably what you want. Worth
an explicit decision in the plan.

---

### E12 — P2 — "Keyboard and mouse" is not all local input.

Task 3 step 1 taps "keyboard and mouse". Not covered, and each is a real local capability left alive
behind the curtain: `kCGEventScrollWheel`, `kCGEventFlagsChanged` (needed anyway for correct modifier
state), tablet events, and `NX_SYSDEFINED`-class events — media keys, volume, brightness, keyboard
backlight, Fn. Trackpad gestures (swipe between Spaces) combine with E5 to *reveal the desktop*.

Smallest fix: start from `kCGEventMaskForAllEvents` (`CGEventTypes.h:429-430`) and pass through only
what you must, rather than allow-listing two classes. And state in the README what a tap
fundamentally cannot block: power button, lid, Touch ID, and anything the system reserves.

---

## 2. What is MISSING

Ordered by how badly the absence hurts.

1. **A threat model section naming the remote adversary.** The document analyses "what if this goes
   wrong for the owner" thoroughly, and never analyses "what does this hand an attacker who already
   has the VNC password". See E7. For a feature whose whole selling point is honesty, this omission
   is the most serious gap in the document.
2. **A no-password / auth-disabled guard.** If macVNC is configured with no VNC password, there is
   **no escape hatch at all** and the curtain becomes an unrecoverable lockout. Nothing in Tasks 1–5
   forbids raising the curtain in that configuration. This must be a hard precondition with a test.
3. **Re-raise policy after a local lift.** See E8. Currently undefined, and the two plausible
   readings differ by "works" vs "owner loses their Mac".
4. **Secure-input handling.** See E2.
5. **Anything about the mouse cursor.** Never mentioned; it is the most visible thing on a "black"
   screen. See E4.
6. **Occlusion/liveness verification.** The remote-side acceptance test cannot distinguish live from
   frozen. See E6.
7. **Password-handling hygiene in Task 1.** No constant-time comparison; "clear the buffer" without
   specifying explicit zeroing (`memset_s`); no statement that the buffer must never be logged or
   land in a crash report. The throttle mitigates online guessing but not the timing channel or
   residue.
8. **Semantics of the 8-character DES truncation.** libvncserver authenticates against the truncated
   secret; the curtain policy compares "the configured password". Decide and document whether they
   match. A user with a 12-character password who must type all 12 locally while 8 suffices remotely
   is a confusing failure at the worst possible moment
   *(applied from memory: VNC password effectively 8 chars, DES truncates)*.
9. **View-only password interaction.** If a second, lower-privilege password exists: can a view-only
   client cause a raise? Does the view-only password lift the curtain? Unaddressed privilege question.
10. **Screen lock / fast user switching / display sleep while curtained.** What happens if the local
    person triggers the system Lock Screen (which the non-goals correctly say they can)? The curtain
    windows and the tap survive underneath; on unlock the user faces the curtain again and must type
    the VNC password after having just typed their account password. Fine, but it should be a listed,
    tested scenario, along with display sleep/wake (a classic `kCGEventTapDisabledByTimeout` trigger).
11. **The screen-recording privacy indicator.** macOS shows an indicator while SCK streams. Above the
    curtain, it is the one honest local signal; below it, the local user loses it. Decide, document,
    and explicitly reject any attempt to suppress it.
12. **Automatable verification for Task 3.** "Manual on-device check plus a log line" is the weakest
    verification in the plan attached to the most dangerous code. Add: synthetic local-source event is
    swallowed; tagged injected event passes; forced `CGEventTapEnable(tap,false)` triggers
    lift/re-enable within N ms; password characters refused while `CGEventTapIsEnabled()` is false;
    curtain refuses to raise with no password configured.
13. **A statement that logs contain event *classes*, never keycodes or characters.** The plan's
    wording is already correct ("per suppressed event class") — make it an explicit rule so it
    survives the first debugging session.
14. **Other capture paths.** Apple Screen Sharing, a Zoom/Teams share, or any second SCK client will
    show the real desktop while the local screen is black. Conversely `screencapture` over SSH shows
    the curtain, not the desktop. Both asymmetries are surprising and belong in the README limits.

---

## 3. Doubtful assumptions

| # | Assumption in the plan | Why it is doubtful | How to settle it |
|---|---|---|---|
| A1 | "verify empirically that injected events are not fed back into our own tap" | Header ordering makes feedback certain (`CGEvent.h:256-260`, `CGEventTypes.h:402-406`). Treating it as 50/50 risks shipping a design with no pass-through path. | Design the tagging in now; test asserts both directions. |
| A2 | "Accessibility is already granted … so no new permission dialog" | Listening vs posting were split in 10.15; `CGPreflightListenEventAccess` exists for this reason (`CGEvent.h:397-402`). Also revocable mid-session. | Runtime preflight, fail closed on raise. |
| A3 | `NSScreenSaverWindowLevel` hides everything | Cursor (`kCGCursorWindowLevel`) and assistive tech (1500) are above 1000 (`CGWindowLevel.h:79-81`). | Use `CGShieldingWindowLevel()` (`CGDirectDisplay.h:377`); enumerate overlays on device. |
| A4 | "the exclusion list is fixed at filter creation, so the capture stream restarts on toggle" | `updateContentFilter:completionHandler:` exists (`SCStream.h:492`). | Use it; drop the restart. |
| A5 | Excluding the curtain from capture ⇒ remote sees a *live* desktop | Exclusion fixes visibility, not occlusion-driven redraw suppression. | Two-frame liveness assertion with animated content (E6). |
| A6 | "the curtain lifts by itself when the remote session ends" | Depends on the server noticing; half-open TCP can hold it for hours (E9). | Keepalive + watchdog + documented caveat. |
| A7 | "a crash self-heals" | True for the tap and windows. Not addressed: a *hung* (not crashed) process keeps both alive with no runloop to process the password — worse than a crash, because the escape hatch is dead while the trap is live. | Watchdog thread independent of the main runloop, or a documented "if the app hangs, power button" line. Note `kCGEventTapDisabledByTimeout` partially rescues this by design — say so. |
| A8 | One boolean preference is a sufficient control surface | Conflates "allow curtain" with "raise now", leaves E7/E8 undefined. | Split arm/raise, or specify precisely which one the boolean is. |
| A9 | "typing the password lifts the curtain" is a self-contained local interaction | Only true while the tap is receiving keys; under secure input or a disabled tap the same keystrokes go to a remote-visible app (E2, E3). | Gate password acceptance on confirmed tap health. |
| A10 | Apple's phrasing "stops accepting all keyboard and mouse input" describes what a session tap achieves | A session tap is strictly weaker (secure input, system-reserved handling, non-tap input paths such as an SSH session or another accessibility client). | Say "most local keyboard and mouse input" and list exceptions. Do not inherit Apple's marketing sentence. |

**Is the wording honest enough?** Mostly yes on the *physical-access* axis — genuinely better than
typical. It is **not** honest yet on the *remote-adversary* axis (E7), and it slightly overclaims
input suppression by borrowing Apple's "all keyboard and mouse input" phrasing (A10). Two sentences
fix both, and they must be in the preference help text, not only the README.

---

## 4. VERDICT

**CONDITIONAL GO.** The concept is sound, the API research is better than average, and the safety
instincts are in the right place. But as written the plan contains two P0-class holes — remote input
being swallowed (E1) and a level-triggered raise that can nullify the escape hatch (E8) — plus two
silent-failure paths (E2 secure input, E3 tap-disable leak) that produce precisely the "black screen
with live input" state the document names as the worst outcome, and a missing remote-adversary threat
model (E7) in a plan whose whole thesis is honesty.

**Conditions to clear before implementation starts (P0/P1):**

1. E1 — injected-event tagging is a required design step with a test, not an empirical maybe.
2. E8 — specify edge-triggered raise + sticky "lifted for this connection".
3. E2/E3 — secure input and both tap-disable reasons handled; password acceptance gated on
   `CGEventTapIsEnabled()`; prefer lifting over logging.
4. E7 — add the remote-adversary threat model and put its consequence in the preference help text.
5. Missing item #2 — refuse to raise when no VNC password is configured.
6. E5 — `collectionBehavior` for Spaces/full-screen, with an explicit acceptance test.
7. E4/E6 — shielding window level, hidden cursor, non-opaque curtain, liveness assertion.

**Conditions before release (P2):** E10 preflight, E11 `updateContentFilter:` + app-level exclusion,
E12 event-mask coverage, missing items #7–#9 and #11–#14.

**Maturity: 6/10.** Solid research and unusually honest framing (+), correct on its central API
claims (+), right build order (+); but the highest-risk task is the least specified, the adversary
model is one-directional, and three of the plan's own stated invariants ("input suppressed",
"lifts by itself", "always a way back in") each have a concrete reachable counterexample above.

---

## Review

- **Correct:** SCK filter semantics (`SCStream.h:149-154`), `SCWindow.windowID` (`SCShareableContent.h:56`),
  active-tap swallow via `NULL` (`CGEventTypes.h:441-442`), non-root session tap + accessibility
  requirement (`CGEvent.h:269-277`), tap dies with process (`CGEvent.h:284`), task ordering, `kill -9`
  acceptance check, and the physical-access non-goals.
- **Fixed:** nothing — review-only run, no project file modified.
- **Findings:** E1 (P0), E2 (P0), E8 (P0/P1), E3–E7, E9 (P1), E10–E12 (P2), plus 14 missing items and
  10 doubtful assumptions, each with header citations above.
- **Merge verdict:** BLOCK for implementation as written; CONDITIONAL GO once E1, E2, E3, E7, E8 and
  the no-password guard are specified in the plan.

Note on conflicting instructions: the base agent prompt allows maintaining `progress.md`, but this
task is review-only/no-edit — no-edit wins, so no progress file was written. No blocking decision
required; no supervisor contact needed.