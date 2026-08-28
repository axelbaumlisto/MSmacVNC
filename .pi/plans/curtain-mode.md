# Curtain mode: black locally, live remotely, with a way back in

## Context

The ask: while a remote viewer is working, someone standing at the Mac must not
see the screen or be able to type - but that person must be able to enter a
password to lift the curtain, because both may legitimately be present at once.

### What macOS does and does not allow

- **A separate session, RDP-style, is not possible.** macOS has one console
  session; there is no public way to give a remote user a second desktop for the
  same account. Not a goal here.
- **Apple's own Curtain Mode is a curtain, not a system lock**, and it requires
  Remote Management. We copy the behaviour, not the claim of a "lock".
- **We do not need Remote Management**: we own the capture, so the curtain is a
  window we exclude from our own stream, plus an event tap that swallows local
  input.

### Facts that shape the design (each one killed an earlier assumption)

1. **The content filter is swapped, not restarted.**
   `-[SCStream updateContentFilter:completionHandler:]` (SCStream.h:487-492)
   replaces the filter on a RUNNING stream.

2. **Exclude by APPLICATION, not by window.**
   `-[SCContentFilter initWithDisplay:excludingApplications:exceptingWindows:]`
   (SCStream.h:174-180) is order-independent: it needs no `SCShareableContent`
   round trip on the raise path, survives window recreation, and makes display
   hot-plug a pure window-creation problem. Excluding by `windowID` requires the
   window to be ON SCREEN to be enumerable, which forces showing the curtain
   before the filter is updated - i.e. showing the remote party black first.
   Cost: our Preferences window is excluded from the stream too.

3. **Our own injected input WILL hit our own tap.** `CGEventPost` passes events
   through taps at that location (CGEvent.h:347-352) and `kCGHIDEventTap` is
   upstream of `kCGSessionEventTap`. A naive "swallow everything" tap breaks
   remote control the moment the curtain rises.

4. **A tap can be created and still be deaf.** CGEvent.h:272-279: without
   Accessibility trust the keyboard bits are *silently cleared from the mask*;
   `CGEventTapCreate` returns non-NULL if pointer bits survive. Result: black
   screen, mouse dead, **keyboard fully live into invisible applications**, and
   the escape hatch never sees a key. This is the most likely route to the worst
   state, because "the tap was created" is the obvious success check. Re-signing
   or updating the app resets TCC, so this is a field condition, not a lab one.

5. **Secure Event Input inverts both halves.** While any process holds it
   (Terminal's Secure Keyboard Entry, a focused password field, a keychain
   prompt), keyboard events are withheld from session taps
   (CarbonEventsCore.h:2977-2984): local keys are NOT suppressed, and the owner
   typing the unlock password types it into the focused app - **which the remote
   party is watching**. `IsSecureEventInputEnabled()` is documented as NOT
   thread safe (CarbonEventsCore.h:3055-3056).

6. **An opaque full-screen curtain freezes the remote picture.** It makes every
   other window occluded (`NSWindowOcclusionState`, NSWindow.h:186-189) and
   well-behaved apps stop drawing; ScreenCaptureKit cannot invent frames nobody
   drew. A "not black" acceptance test passes on a frozen desktop.

7. **A crash self-heals; a HANG does not.** An event tap dies with the process.
   But a blocked callback makes WindowServer disable the tap after ~1 s
   (`kCGEventTapDisabledByTimeout`), restoring local input while the black
   window stays composited - and `NSWindow` teardown is main-thread only, so a
   watchdog cannot rescue a wedged main thread by tearing down the window.
   **Input fails open by itself; the SCREEN fails open only via process exit.**

8. **Window level alone does not cover Spaces or full-screen apps**, and
   `NSScreenSaverWindowLevel` is the *same* level as the screensaver, where
   z-order is unspecified. Above it sit assistive-technology panels and the
   cursor.

### The failure that matters most

The curtain is raised by the REMOTE party, so whoever holds the VNC password can
blind the person standing at the machine. Every decision below follows from
that, and from fact 7: the only mechanisms that fail open from OUTSIDE the
failing component are WindowServer's tap timeout (restores input) and process
death (restores both).

### Non-goals

- Blocking someone with physical access. Behind the curtain the Mac is unlocked.
- Covering the login window, the screensaver, or another user's session.
- Hiding from assistive technology or the cursor layer.
- Blocking system-defined keys (media, brightness, volume) - the tap mask does
  not cover them, so the UI must not say "all local input is blocked".

## Approach

Policy first, then the window, then the tap - the only order in which a
half-finished implementation cannot trap the local user. A controller with
injected seams comes before the tap so the dangerous state transitions are
testable without a device.

## Tasks

### Task 1: The unlock policy, pure and tested
**Files:** `src/MacVNCCurtainPolicy.h` (new), `src/MacVNCCurtainPolicy.c` (new),
`tests/test_curtain_policy.c` (new), `CMakeLists.txt`
**Acceptance:** the password lifts the curtain; wrong attempts are throttled
within a CAP; the buffer is bounded; the comparison matches what VNC
authentication accepts; no decision needs a window or a tap.
**Verify:** `ctest -R curtain_policy` plus `tests/mutate.sh`
**Steps:**
1. State machine over typed characters: accumulate, compare on Return, reset on
   Escape, clear the buffer on every outcome.
2. Compare the same **8 effective bytes** VNC authentication uses (DES
   truncation), constant-time. A full-string comparison would refuse a password
   the server itself accepts; pin it with a >8 character test.
3. **Cap the throttle** and express it as a deadline against a monotonic clock -
   never a sleep, because a sleep in the tap callback causes fact 7.
4. **Refuse to arm without a usable secret** (empty or unset password means a
   curtain with no way out).
5. The secret is read at each comparison, and **any change to it lifts the
   curtain** (Task 4) - the benign case is the owner changing it, the
   adversarial case is the remote party changing it to lock the local user out.
6. **Decide the keycode-to-character rule here**, not in the tap:
   `CGEventKeyboardGetUnicodeString` (no allocation, callback-safe) rather than
   `UCKeyTranslate`; define shift/caps, dead keys, non-ASCII, and whether the
   buffer holds bytes or code points, consistently with step 2.
7. Mutation-test: no throttle, uncapped throttle, unbounded buffer, comparison
   inverted, full-string instead of 8-byte comparison, arming with an empty
   secret, buffer not cleared after success.

### Task 2: The curtain window, excluded from capture, without freezing the stream
**Files:** `src/MacVNCCurtainWindow.h/.m` (new), `src/MacVNCCaptureSession.m`,
`src/ScreenCapturer.m`, `CMakeLists.txt`
**Depends:** Task 1
**Acceptance:** every physical display shows the curtain - including in a
full-screen app and on another Space - while the remote stream keeps showing a
desktop that **changes over time**.
**Verify:** curtain up, play a video locally, sample `tests/vnc_probe` ≥3 times
over ≥2 s and require the content signature to CHANGE. Separately: full-screen
Safari, curtain up, confirm black locally.
**Steps:**
1. One borderless window per `NSScreen` at `NSScreenSaverWindowLevel`, with
   `collectionBehavior` = `CanJoinAllSpaces | FullScreenAuxiliary | Stationary |
   IgnoresCycle`, shown with `orderFrontRegardless`.
2. **Exclude by application** (fact 2): build the filter with
   `initWithDisplay:excludingApplications:exceptingWindows:` naming our own
   `SCRunningApplication`. No `SCShareableContent` round trip on the raise path,
   no ordering trap, no per-window resolution.
3. **Do not present a fully opaque occluder** (fact 6). Evaluate `setOpaque:NO`
   with alpha just under 1 over a real occlusion-honouring app (Safari playing
   video), and state the luminance criterion for "looks black" rather than
   eyeballing it.
4. Swap the filter with `updateContentFilter:completionHandler:`; raise the
   windows only after it reports success, with a TIMEOUT - if the handler never
   fires, treat it as failure and do not raise. Lift is the exact reverse.
5. Display hot-plug (`NSApplicationDidChangeScreenParametersNotification`):
   create and show a window on the new screen. With application-level exclusion
   there is no filter round trip, so the exposure window is one window creation.

### Task 3: The controller - state transitions, testable without a device
**Files:** `src/MacVNCCurtainController.h/.m` (new),
`tests/test_curtain_controller.m` (new), `CMakeLists.txt`
**Depends:** Task 2
**Acceptance:** every raise/lift rule below is exercised by a unit test with
injected clock, tap, window and stream seams - no device, no tap, no window.
**Verify:** `ctest -R curtain_controller` plus `tests/mutate.sh`
**Steps:**
1. One place owns the answer to "should the curtain be up", with protocols for
   the tap, the window set, the stream and the clock so tests can fail each one.
2. Raise **edge-triggered** on the transition to a first authenticated client -
   never level-triggered, or the escape hatch is a no-op (lift, re-evaluate,
   re-raise). Define "connected" as authenticated and receiving updates.
3. **A local lift latches down for the rest of the app run.** Latching only
   until the next connection lets an attacker re-blind the user by reconnecting
   in a loop.
4. Lift on every one of: last client gone, server stop, app terminate, stream
   stopped or errored (`SCStreamDelegate stream:didStopWithError:`), secret
   changed or cleared, preference switched off, secure input turning on,
   screensaver/display sleep/session resign (fast user switching).
5. **A live stream plus an authenticated client is a continuously enforced
   invariant, not a raise-time precondition** (fact 7's lesson applied to the
   stream: it can die after the raise, leaving black locally and nothing
   remotely).
6. Raised state NEVER persists: the preference is stored, the state is not, and
   nothing raises at launch.
7. Mutation-test: level-triggered raise, latch reset on reconnect, each lift
   trigger removed one at a time.

### Task 4: Input suppression, with the escape hatch wired first
**Files:** `src/MacVNCCurtainInput.h/.m` (new), `src/MacVNCCurtainWindow.m`,
`src/MacVNCInput.m`, `CMakeLists.txt`
**Depends:** Task 3
**Acceptance:** local keystrokes and clicks reach no application; the remote
viewer's keyboard AND mouse still work; typing the password locally lifts the
curtain; a tap that cannot see keys refuses to raise instead of half-working.
**Verify:** on-device with a remote client typing and moving the mouse, plus the
three adversarial checks in Verification
**Steps:**
1. **Precondition, before anything is shown:** `AXIsProcessTrustedWithOptions`
   with the prompt suppressed must be true, `CGEventTapCreate` must return
   non-NULL, AND the effective mask must still contain the keyboard bits
   (fact 4). Any of the three failing means refuse to raise and log why.
2. **Tag our own injected events**: one `CGEventSourceRef` with
   `kCGEventSourceStatePrivate` and a magic in `CGEventSourceSetUserData`; the
   callback returns tagged events unmodified. Replace untaggable injection
   (`CGWarpMouseCursorPosition`) with a tagged `kCGEventMouseMoved` event, or
   the remote cursor freezes while clicks still land.
3. **The tap runs on its own thread with its own run loop** - never the main run
   loop, where a wedge kills the callback and the AppKit path at once (fact 7).
4. The callback does nothing that can block: no waiting allocation, no lock
   shared with the VNC or lifecycle queues, no I/O, no keystroke logging, no
   sleep. It reads a few fields, appends to a fixed buffer, stamps an entry/exit
   timestamp and signals.
5. **Focus policy, stated once** (this is the contradiction an earlier draft
   contained): the curtain window is NOT key while the tap is healthy - the tap
   is the only path, and making the window key would send the remote party's
   keystrokes into it. The window becomes key ONLY while the tap path is known
   unavailable (secure input on, or tap disabled), and its `keyDown:` must also
   ignore self-injected events by checking the same source tag.
6. Handle **both** disable reasons (`...ByTimeout`, `...ByUserInput`): re-enable
   and log; if re-enabling does not stick, lift.
7. **Secure input** (fact 5): poll `IsSecureEventInputEnabled()` on the tap's own
   thread (it is not thread safe, and the lifecycle queue is the wrong caller),
   fast enough that the check-then-act window is small; treat "keyboard events
   stopped while pointer events continue" as a corroborating signal; on
   transition to true, hand focus to the curtain window (step 5) and lift.
8. **Watchdog measures latency, not silence**: a callback that is IN FLIGHT too
   long, plus a main-thread heartbeat that must be acknowledged. An idle user
   produces no events at all, so "no callbacks for N seconds" would lift the
   curtain in the feature's normal state. Its action is process-level
   (`abort()`), because that is the only thing that restores the SCREEN from
   outside a wedged main thread.
9. Tear down on the tap's own thread (`CGEventTapEnable(false)`, invalidate the
   run-loop source, then release) - cross-thread invalidation is a
   use-after-free hazard.

### Task 5: The switch, and honest words around it
**Files:** `src/MacVNCPreferences.m`, `src/MacVNCDefaultsKeys.h/.m`,
`tests/test_defaults.m`, `README.md`
**Depends:** Task 4
**Acceptance:** off by default; switching it off while curtained lifts
immediately; the help text claims only what is true.
**Steps:**
1. `MacVNCKeyCurtain`, default off, registered with the others.
2. Preferences row plus help text: while a viewer is connected the local screen
   is hidden and local keyboard and pointer input are blocked; the VNC password
   lifts it; the Mac itself stays unlocked.
3. README limits, named plainly: assistive-technology overlays and the cursor
   draw above the curtain; media/brightness keys are not blocked; secure input
   lifts it; a silently dropped connection can hold it up until the connection
   is reaped; **the remote party is who raises it**, so anyone with the VNC
   password can blind the local user - which is why it is off by default.
4. The last resort is **hardware**: power button, lid, force restart. Do NOT
   promise that Ctrl-Cmd-Q or the menu reach the Lock Screen - the tap swallows
   them. Also document ssh + `killall`, noting it needs a second machine.
5. One line for VoiceOver users: with input swallowed they get no feedback.

## Verification

- [ ] `ctest` green, every new assertion mutation-tested
- [ ] analyzer clean, `leaks` reports 0
- [ ] curtain up: remote frame signature CHANGES across ≥3 samples over ≥2 s
      with a video playing locally (not merely "not black")
- [ ] curtain covers a full-screen app and another Space
- [ ] remote keyboard AND mouse still work with the curtain up
- [ ] password typed locally lifts it; wrong attempts throttle within the cap;
      after a local lift it does not re-raise, even on reconnect
- [ ] Accessibility trust revoked → raise is REFUSED (not a keyboard-live
      curtain); re-granted → raise works
- [ ] Secure Keyboard Entry enabled in Terminal while curtained → lifts
- [ ] display disconnected / system slept and woken while curtained → lifts
      rather than persisting over a dead stream
- [ ] `kill -9` leaves neither a black screen nor suppressed input; `kill -STOP`
      is exercised and its outcome recorded in the README
- [ ] refuses to raise with an empty VNC password
- [ ] preference switched off while curtained lifts it
- [ ] the UI never claims the Mac is locked
