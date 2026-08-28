# ROUND2 — Implementation-critic audit of `/tmp/curtain-clean2.md`

**Scope of this review.** I read only the plan and four macOS SDK headers (`SCStream.h`, `SCShareableContent.h`, `CGEvent.h`, `CarbonEventsCore.h`, `NSWindow.h`) under `xcrun --show-sdk-path`. I did **not** read any repository source, git history, or other review files, per instruction. Anything that depends on current repo contents is marked **unverified** rather than asserted.

**Memories applied:** VNC password is effectively 8 bytes (DES truncation) — used to confirm Task 1 step 2 is correct rather than a bug; auth/behaviour must be verified with the reference libvncclient (`/tmp/refclient`), not vncdotool — applied to the verification section; release tooling lives in `packaging/` — applied to the "no signing task" note. The `disable-library-validation` entitlement memory turned out **not** to apply: this feature bundles no new dylibs (Carbon/HIToolbox and ScreenCaptureKit are system frameworks), so the existing entitlement set remains sufficient. I note it only so a later reviewer does not re-open it.

**Headline judgement.** This is an unusually good plan in its *analysis*. The five "facts" are real, correctly sourced in three of five cases, and each one actually changes a design decision instead of decorating it. Task 1 is executable today with no open questions. Tasks 2–4 contain at least four places where an engineer would have to **stop and make a design decision the plan never makes**, and two places where the plan is **self-contradictory**. That is what moves this from GO to CONDITIONAL.

---

## 1. Errors

### E1 (P0) — Task 3 step 4: the "two independent input paths" are mutually exclusive, not independent
> "Two independent input paths into the policy. The tap, and the curtain window itself as key window with a view implementing `keyDown:`."

An active tap at `kCGSessionEventTap` that returns `NULL` deletes the event from the stream. `CGEvent.h:263-267` ("An active filter may pass an event through unmodified, modify an event, or discard an event") — a discarded local keystroke never reaches *any* application, including our own curtain window. So:

- While the tap works, path 2 receives **nothing**. It is not a second path; it is dead code.
- Path 2 only becomes live if the tap is absent or disabled — i.e. exactly the state where the curtain must fail open anyway.

The stated invariant ("the curtain may never be in a state where zero paths reach the policy") is therefore **not measurable by any method the plan gives**, and the acceptance criterion "the policy always has at least one live input path" cannot be evaluated. The plan needs one decision it never makes: either the tap forwards password keystrokes to the policy *and* path 2 exists only as a fallback for tap-failure (then say so, and define how "tap failed" is detected), or path 2 is dropped.

### E2 (P0) — Task 3 step 4 contradicts Task 2 step 1, and breaks remote typing
Task 2 step 1: order the curtain with `orderFrontRegardless` "so we never steal focus or activate the app."
Task 3 step 4: make "the curtain window itself as key window."

These cannot both hold: a window cannot be key without the app taking keyboard focus. Worse, this collides with the plan's own fact 2. Remote events are passed through the tap unmodified (by design, step 1) and are then routed by WindowServer to the **focused** window. If the curtain window is key, the remote viewer's keystrokes land in the curtain view, not in the app the remote user is working in — the feature's primary function breaks in exactly the way fact 2 was written to prevent. Secondary, smaller: a borderless `NSWindow` returns `NO` from `canBecomeKeyWindow` by default, so this step also requires an unstated subclass override.

### E3 (P0) — Task 3 step 7: the watchdog tears the curtain down during normal idle use
> "A watchdog on its own queue: the callback pings it; no ping for N seconds while curtained tears the window down from that queue."

The tap callback fires only when there is local input. The normal, intended state of curtain mode is **nobody touching the local keyboard or mouse**. As specified, the watchdog will observe no ping and lift the curtain after N seconds, every session. The watchdog must measure callback *latency* (entry timestamp vs. exit timestamp, or a heartbeat posted from the lifecycle queue that the callback must acknowledge), not callback *absence*. `N` is also never given a value or a derivation, though `CGEvent.h:322-325` and fact 5 give the ~1 s WindowServer budget as the natural anchor.

### E4 (P1) — Fact 3's citation does not say what the plan claims
The plan asserts: "keyboard events are withheld from session taps (`CarbonEventsCore.h:2977-2982`)."
The actual text at `CarbonEventsCore.h:2977-2980` is: *"When secure event input is enabled, keyboard input will only go to the application with keyboard focus, and will not be echoed to other applications that might be using **the event monitor target** to watch keyboard input."* Lines 2981-2982 are about `EditText`/`EditUnicodeText` controls and are irrelevant. This is the Carbon event-monitor target, **not** `kCGSessionEventTap`. The behavioural claim is true in practice, but the plan's own standard ("each fact killed an earlier assumption", header-cited) is not met here: this is the one fact with no valid citation. It should cite `IsSecureEventInputEnabled` (`CarbonEventsCore.h:3044-3064`) for the API and mark the tap-suppression behaviour as **empirically established, not documented** — which also tells the implementer it must be re-verified on each macOS release.

### E5 (P1) — Tasks 2 and 3 add new source files but never touch the build system
Task 1 correctly lists `CMakeLists.txt`. Task 2 adds `src/MacVNCCurtainWindow.h/.m` and Task 3 adds `src/MacVNCCurtainInput.h/.m` — neither task lists `CMakeLists.txt` in **Files**. Task 3 also introduces `IsSecureEventInputEnabled()`, which requires linking Carbon/HIToolbox (`CarbonEventsCore.h:3063-3064`, `AVAILABLE_MAC_OS_X_VERSION_10_3_AND_LATER`), a new framework dependency with no assigned step. An engineer following the Files lists literally produces code that does not compile into the target.

### E6 (P1) — Task 5 (the off-by-default switch) comes *after* Task 4 wires raise-on-connect
Task 4 step 1 raises the curtain "on the transition to connected." `MacVNCKeyCurtain`, default off, is only created in Task 5. Between the two tasks the build unconditionally blacks the local screen and suppresses local input on every client connection, with the typed password as the only way out — on a developer's own machine, repeatedly. This violates the plan's own stated ordering principle ("Build in the order that keeps the escape hatch working at every step"). Either move the defaults key to Task 1/2, or state explicitly in Task 4 that the raise path is gated behind a hardcoded `NO` until Task 5.

### E7 (P2) — Two verification standards for the same evidence class
Task 2 step 2 rightly forbids "looks black" as evidence for the remote side and demands a content signature that changes across ≥3 samples over ≥2 s. The **local** side of the same acceptance criterion is "enter full-screen Safari, raise the curtain, confirm black locally" — pure eyeballing, and specifically weak because step 2 deliberately makes the curtain *not fully opaque* (see E9). If alpha is 0.99 the local screen legitimately still contains 1% of the desktop. "Confirm black" has no threshold, no instrument, and no pass/fail line.

### E8 (P2) — CGEvent.h:255-258 citation is off by one line
The tap-location ordering text runs `CGEvent.h:256-259`. The substance (HID → session → annotated → application) is correct and does support "`kCGHIDEventTap` is upstream of `kCGSessionEventTap`". Cosmetic; noted only because the plan's other citations are precise (`SCStream.h:487-492` and `CGEvent.h:347-352` are both **exactly** right, and `NSWindow.h:186-189` is right).

---

## 2. What is MISSING

### M1 (P0) — Accessibility (TCC) permission and tap-creation failure are never handled
`CGEvent.h:272-279` is explicit: a tap at `kCGSessionEventTap` "may only receive key up and down events if access for assistive devices is enabled ... **If the tap is not permitted to monitor these events when the tap is created, then the appropriate bits in the mask are cleared. If that results in an empty mask, then NULL is returned.**"

Two failure modes follow, and the plan addresses neither:
- `CGEventTapCreate` returns `NULL` → no suppression at all.
- **Silent partial success**: the key bits are cleared but pointer bits survive, so the tap is created and looks healthy, yet never sees a keystroke. The result is a black screen with a live local keyboard **and** a dead escape hatch — the precise "worst mix" the plan names in fact 3, reached by a completely different route.

Task 3 step 5 handles `kCGEventTapDisabledByTimeout` / `...ByUserInput`; there is no step for "the tap was never able to see keys." Required additions: check trust before arming, refuse to raise on `NULL`, and verify post-creation that the key bits actually survived in the mask rather than assuming they did.

### M2 (P0) — How a `CGEvent` becomes a password character is never decided, and the obvious answer violates step 3
Task 1 consumes "typed characters." Task 3 step 3 forbids the callback from doing anything that can block: "no allocation that can wait, no lock ... no I/O." But turning a keycode into a character requires either `UCKeyTranslate` (which needs a `TISInputSourceRef` / layout data lookup — allocation and a Text Input Services call, arguably outside the "few fields" budget) or `CGEventKeyboardGetUnicodeString` (safe, no allocation, but a different behaviour for dead keys and modifiers). The plan never chooses. Also undecided: shift/caps handling, dead keys, non-ASCII passwords, and whether the buffer stores bytes or code points — which directly interacts with Task 1 step 2's "8 effective bytes."

### M3 (P1) — No local feedback, so the escape hatch is typing blind into a black screen with a throttle
The curtain shows nothing. The plan never decides whether typing produces any indication (dots, a hint line, a wrong-password flash, a "type the VNC password" string). Combined with the escalating throttle and no stated backspace handling (Task 1 step 1 defines only accumulate / Return / Escape — **backspace is missing**), the owner has no way to distinguish "my keystrokes are not reaching the policy" from "I mistyped" from "I am throttled." For a feature whose entire justification is "the person at the keyboard must always have a working way back in," this is a functional gap, not a cosmetic one. It also interacts with E7: a hint line is content, and content must be inside the excluded window so the remote party does not see it.

### M4 (P1) — Where the secret comes from is never assigned to a task
Task 1 step 5 correctly makes the policy take the secret at each comparison. No task owns the other half: which component reads the server's current password, in what encoding, and whether it is the plaintext, the obfuscated `.vncpasswd` form, or a keychain item. "The comparison matches what VNC authentication actually accepts" is only measurable once that is fixed. **Unverified** — this may be trivially available in the existing code, but the plan does not say so, and the acceptance criterion depends on it.

### M5 (P1) — `tests/vnc_probe` is required by Task 2's verification but produced by no task
Task 1's `tests/mutate.sh` is referenced the same way; from prior context that script exists. `tests/vnc_probe` appears only in Task 2's Verify line and in the final checklist, and is in no **Files** list. Either it already exists (then say so) or Task 2 silently contains "write a VNC frame-sampling probe" — a non-trivial sub-project whose absence blocks the plan's single strongest acceptance criterion. **Unverified.**

### M6 (P1) — No timeout on the async raise sequence
Task 2 step 4's ordering is create → resolve `SCWindow`s → `updateContentFilter:` → show. Both middle steps are asynchronous completion-handler APIs (`SCShareableContent.h:142-146`, `SCStream.h:487-492`). The plan defines behaviour for *failure* ("tear the window down and report the reason") but not for a completion handler that never fires, and gives no deadline. Given that the surrounding design is otherwise obsessive about not leaving a half-raised state, this omission stands out.

### M7 (P2) — Residual exposure window for secure input is not stated, though the analogous one for hot-plug is
Task 2 step 5 admirably states the hot-plug exposure window in plain words. Task 3 step 6's 1 Hz poll has the same shape: for up to ~1 s after secure input turns on, local keys are unsuppressed **and** characters typed toward the escape hatch land in the focused app, which fact 3 says is visible in the remote stream. The plan should state this residual second in the same plain language, and the README (Task 5 step 3) should carry it.

### M8 (P2) — No acceptance criterion for the enumerated pointer mask
Task 3 step 2 requires explicit enumeration of moves, drags, all buttons, scroll, gestures, flags-changed. Task 3's acceptance says only "local keystrokes and clicks reach no application." Scroll, gestures and flags-changed are never tested. Smallest fix: add "scroll and a trackpad gesture reach no application" to the checklist.

### M9 (P2) — No release/packaging step
Nothing in Tasks 1–5 touches `packaging/`. That is probably correct — no new bundled dylib means the existing hardened-runtime signing and `com.apple.security.cs.disable-library-validation` entitlement remain valid and untouched. Worth one explicit sentence in the plan so a future engineer does not "helpfully" regenerate the signing config. (applied from memory: entitlement is mandatory and release tooling lives in `packaging/`, not `build/`)

---

## 3. Doubtful assumptions

### D1 — "Evaluate `setOpaque:NO` with an alpha just under 1" is an open design question wearing a step's clothing
Task 2 step 2 is the only step in the plan phrased as an experiment with no decided outcome and **no plan B**. If sub-1.0 alpha does not stop downstream apps from being marked occluded, the engineer is stranded mid-task: the remaining candidates (a 1-pixel gap, per-window sub-rect coverage, forcing `NSWindowOcclusionStateVisible` by other means, or accepting stale remote frames) are all substantial redesigns of Task 2. `NSWindow.h:186` is actually *encouraging* here — "Windows that are completely transparent may also still count as visible" — but that sentence is about the transparent window itself, not about what it occludes, so it is not the proof the plan implies. This is the single largest execution risk in the plan.

### D2 — `CanJoinAllSpaces | FullScreenAuxiliary` is a slightly incoherent pair
`FullScreenAuxiliary` is intended for windows accompanying a `FullScreenPrimary` window **of the same application**; the curtain has no full-screen primary. In practice `NSScreenSaverWindowLevel` + `CanJoinAllSpaces` is what makes a window ride over other apps' full-screen spaces. The pairing is probably harmless, but the plan presents the four flags as a settled recipe when at least one is speculative. The acceptance test does cover this, so it is a risk to schedule, not to correctness.

### D3 — Resolving our own not-yet-shown window in `SCShareableContent`
The raise ordering resolves `SCWindow`s *before* showing the windows. `SCShareableContent` offers on-screen-only filtering (`SCShareableContent.h:156-162`); a window that has never been ordered front may not appear in the list at all, which would make the resolve step fail permanently rather than transiently. The plan does not say which of the four `getShareableContent...` variants to call, nor what to do when a curtain window is missing from the returned list (retry? how many times? fail open?). The `SCWindow.windowID` ↔ `NSWindow.windowNumber` identity itself is sound: `SCShareableContent.h:54-56` types it as a `CGWindowID`.

### D4 — Switching `MacVNCInput.m` to a private event source is treated as a pure addition
`kCGEventSourceStatePrivate` (Task 3 step 1) does not inherit the combined system modifier state. Redirecting existing remote-input injection through a new private source is a **behaviour change to a working feature**, most likely to show up in sticky or dropped modifier flags rather than in gross failure — and the acceptance criterion "remote keyboard and mouse still work" is coarse enough to pass while shift-, option- or command-chords misbehave. Suggest a narrower tagging alternative (keep the existing source, tag via `CGEventSetIntegerValueField(event, kCGEventSourceUserData, magic)` on each posted event) or an explicit modifier-chord test. **Unverified** — I could not read `MacVNCInput.m`.

### D5 — Assumes a display-based `SCContentFilter` and one stream
`initWithDisplay:excludingWindows:` (`SCStream.h:149-154`) is per-display, and its discussion notes the desktop background and dock are included. If the existing capturer builds its filter differently — e.g. `initWithDisplay:excludingApplications:exceptingWindows:` to keep the server's own UI out of the stream — then swapping in `excludingWindows:` silently drops that exclusion. Multi-display capture raises the same question: one filter per stream, and the plan's "one window per `NSScreen`" does not say how many streams exist. **Unverified against the repo.**

### D6 — Assumes ScreenCaptureKit is unconditionally available
`updateContentFilter:completionHandler:` and the whole exclusion mechanism are macOS 12.3+. If the project retains any pre-12.3 capture path, curtain mode has no exclusion mechanism there and Task 2 needs a "feature unavailable" branch. Not mentioned. **Unverified.**

---

## What is genuinely good (stated plainly, not as filler)

- **Fact 2 (our own injected input hits our own tap) is the thing nearly every implementation of this feature gets wrong**, and the plan not only catches it but demands enumeration of every injection path including the non-event cursor warp. Citation `CGEvent.h:347-352` is exact.
- **Fact 1's citation is exact** (`SCStream.h:487-492`), and "swap the filter, never restart the stream" is the right call for the right reason.
- **Task 1 is executable as written with zero open decisions**, has a real oracle (`ctest -R curtain_policy`), and its mutation list is specific enough to be checkable. The 8-byte comparison insight is correct and matters: libvncserver's DES-based auth truncates at 8 characters, so a full-string comparison really would refuse a password the server itself accepts. Pinning it with a >8-character test is exactly right.
- **The "content signature must CHANGE across ≥3 samples over ≥2 s" criterion** is the best acceptance criterion in the document: it is the one that distinguishes success from the plausible-looking failure, and it is instrument-based rather than eyeball-based.
- **Fail-open discipline** — refuse to arm without a secret, refuse to raise under secure input, lift when re-enable does not stick, nothing that survives the process, `kill -9` self-heals — is consistently applied, and the threat framing ("the remote party is who raises it") is honest.
- **Non-goals are honest**, and the requirement that the UI never claim the Mac is locked is the correct product decision.

**Verification note:** the checklist's "remote keyboard and mouse still work" and any auth-adjacent check should be exercised with the reference libvncclient at `/tmp/refclient`. vncdotool has previously reported a false AUTH OK on this project and must not be the instrument of record. (applied from memory: verify with reference libvncclient, not vncdotool)

---

## 4. VERDICT

**CONDITIONAL — do not start Task 3 as written. Tasks 1 and 2 may start now, Task 2 with D1 escalated to a decision before coding.**

An engineer can execute **Task 1** end to end with no further decisions. **Task 2** stalls at step 2 (D1) unless someone pre-decides the fallback for the occlusion problem, and at step 4 (D3) unless someone picks a `getShareableContent` variant and a missing-window policy. **Task 3 cannot be executed as written at all**: E1 and E2 are mutually contradictory instructions, E3 as specified lifts the curtain during idle, M1 leaves the most likely real-world failure unhandled, and M2 is an unmade decision that collides with the task's own no-blocking rule. **Task 4** is fine in substance but is scheduled one task too early relative to the off-switch (E6). **Task 5** is fine.

**Blocking conditions to clear before Task 3 begins:**
1. Resolve E1/E2 — decide whether the curtain window ever becomes key, and restate the "at least one live path" invariant as something observable.
2. Restate the watchdog (E3) as latency- or heartbeat-based, and give `N` a value.
3. Add M1: accessibility-trust precondition, `NULL`-tap refusal, and post-creation verification that key bits survived the mask.
4. Add M2: name the keycode→character API and the modifier/backspace policy.
5. Add `CMakeLists.txt` (and Carbon linkage) to Tasks 2 and 3 (E5), and gate Task 4's raise path until Task 5 lands (E6).
6. Decide D1's fallback before Task 2 step 2, so the task cannot strand.

**Maturity: 7/10.** The reasoning quality is 9/10 — it is fact-driven, correctly cited three times out of five, and it anticipates the two failure modes (stale remote frames, self-tapped injected input) that would otherwise be discovered late and expensively. The executability is about 5/10: roughly one step in six requires a decision the plan does not make, two steps contradict each other, one watchdog rule is inverted, and two of five tasks would not compile from their own Files lists. Fixing all of it is an afternoon of editing, not a redesign — the architecture underneath is sound.