# Curtain mode: black locally, live remotely, with a way back in

## Context

The ask: while a remote viewer is working, someone standing at the Mac must not
see the screen or be able to type - but that person must be able to enter a
password to lift the curtain, because both may legitimately be present at once.

### What macOS does and does not allow (checked, not assumed)

- **A separate session, RDP-style, is not possible.** macOS has one console
  session; there is no public way to give a remote user a second desktop for the
  same account. Not a goal here - the user does not need it.
- **Apple's own Curtain Mode is the same trick we would use, not a system
  lock.** Apple's documentation: the local screen "goes black or displays a
  custom image" and the machine "stops accepting all keyboard and mouse input
  from the local user". The Mac stays unlocked. It also requires **Remote
  Management** to be enabled and does not work at the login window; that is why
  third-party viewers can only offer it by driving Apple's agent.
- **We do not need Remote Management.** We own the capture, so we can build the
  same behaviour from two public pieces:
  - `-[SCContentFilter initWithDisplay:excludingWindows:]` - we already call it
    with an empty array. Passing our own curtain windows there means the local
    display shows black while the remote stream keeps showing the desktop.
    `SCWindow.windowID` matches `NSWindow.windowNumber`, which is how we find
    ours in `SCShareableContent`.
  - `CGEventTapCreate` with `kCGEventTapOptionDefault` - an ACTIVE tap, which
    can swallow local keyboard and mouse events by returning NULL. Accessibility
    is already granted (we inject events through it), so no new permission
    dialog.

### The failure that matters most

Curtain mode locks the owner out of their own Mac if anything goes wrong. Every
decision below is driven by that:

- the person at the keyboard must always have a way back in (the password);
- the curtain must lift by itself when the remote session ends;
- a crash must not leave a black screen with dead input - an event tap dies with
  the process and the window disappears with it, so a crash self-heals, and the
  plan must not introduce anything that survives the process;
- the tap can be disabled by the system (`kCGEventTapDisabledByTimeout`), which
  must re-enable rather than silently leave input suppressed while the screen
  stays black.

### Non-goals

- Blocking a determined person with physical access. The Mac is unlocked behind
  the curtain; power button, closing the lid or the system's own lock still get
  them to the real Lock Screen. This is privacy from onlookers, exactly like
  Apple's, and the UI must not promise more.
- Covering the login window. The desktop is not rendered there, so neither the
  curtain nor the capture apply.

## Approach

Build it in the order that keeps the escape hatch working at every step: the
pure policy first, then the visible curtain, then input suppression last -
because that is the piece that can trap someone.

## Tasks

### Task 1: The unlock policy, pure and tested
**Files:** `src/MacVNCCurtainPolicy.h` (new), `src/MacVNCCurtainPolicy.c` (new),
`tests/test_curtain_policy.c` (new), `CMakeLists.txt`
**Acceptance:** typing the password lifts the curtain; wrong attempts are
throttled with a growing delay; the buffer never grows without bound; policy
decisions are testable with no window and no event tap.
**Verify:** `ctest -R curtain_policy` plus `tests/mutate.sh`
**Steps:**
1. State machine over typed characters: accumulate, compare against the
   configured password on Return, reset on Escape.
2. Throttle: after N failures require a growing wait before the next attempt is
   even considered, so the curtain is not a password oracle at keyboard speed.
3. Bound the buffer (a stuck key must not allocate), and clear it on success,
   failure and lift.
4. Mutation-test: no throttle, unbounded buffer, comparison inverted, buffer not
   cleared after success.

### Task 2: The curtain window, excluded from capture
**Files:** `src/MacVNCCurtainWindow.h/.m` (new), `src/MacVNCCaptureSession.m`,
`src/ScreenCapturer.m`
**Depends:** Task 1
**Acceptance:** with the curtain up, a VNC client still receives the real
desktop while every physical display shows the curtain; no window of ours
appears in the remote stream.
**Verify:** curtain on, then `tests/vnc_probe` fetches a frame and its content
signature shows the desktop, not black
**Steps:**
1. One borderless window per `NSScreen` at `NSScreenSaverWindowLevel`, black,
   with a short message and a password field drawn by us (not an `NSTextField`
   that could take focus away).
2. Collect their `windowNumber`s, resolve the matching `SCWindow`s from
   `SCShareableContent`, and pass them to `initWithDisplay:excludingWindows:`.
3. Rebuild the filter when the curtain toggles - the exclusion list is fixed at
   filter creation, so the capture stream restarts on toggle.
4. Handle display hot-plug: a screen added while curtained must be covered too.

### Task 3: Input suppression, with the escape hatch wired first
**Files:** `src/MacVNCCurtainInput.h/.m` (new), `src/MacVNCCurtainWindow.m`
**Depends:** Task 2
**Acceptance:** with the curtain up, local keystrokes and clicks do not reach
any application; typing the password still lifts the curtain; the remote
viewer's injected input is unaffected.
**Verify:** manual on-device check plus a log line per suppressed event class
**Steps:**
1. Active tap at `kCGSessionEventTap` for keyboard and mouse. Feed key events to
   the Task 1 policy, then return NULL to swallow them.
2. Do NOT swallow our own injected events: the VNC input path posts to
   `kCGHIDEventTap`; verify empirically that injected events are not fed back
   into our own tap, and if they are, tag and skip them.
3. Re-enable on `kCGEventTapDisabledByTimeout` and log it - a silently disabled
   tap means a black screen with live input, which is the worst mix.
4. Release the tap on every exit path, including the failure paths of Task 2.

### Task 4: Lifecycle - never leave someone in the dark
**Files:** `src/mac.m`, `src/AppDelegate.m`
**Depends:** Task 3
**Acceptance:** the curtain lifts automatically when the last client
disconnects, when the server stops, and when the app terminates; it cannot be
raised with no client connected.
**Verify:** connect, curtain, disconnect the client, confirm the curtain is gone
**Steps:**
1. Raise only while `vncConnectedClients > 0`; drop it in the same place the
   capture gate already reacts to the client count.
2. Lift in `applicationWillTerminate` and on server stop, on the serial
   lifecycle queue that already exists.
3. Log every raise and lift with the reason - this is the trail that explains a
   black screen to a confused owner.

### Task 5: The switch, and honest words around it
**Files:** `src/MacVNCPreferences.m`, `src/MacVNCDefaultsKeys.h/.m`,
`tests/test_defaults.m`, `README.md`
**Depends:** Task 4
**Acceptance:** off by default; the setting explains what it does and does not
protect against; the password that lifts it is named explicitly.
**Steps:**
1. `MacVNCKeyCurtain`, default off, registered with the others so the
   completeness test covers it.
2. Preferences row plus one line of help: the local screen is hidden and local
   input is blocked while a viewer is connected; the VNC password lifts it; the
   Mac itself stays unlocked.
3. README section including the limits, next to the existing security notes.

## Verification

- [ ] `ctest` green, every new assertion mutation-tested
- [ ] analyzer clean, `leaks` reports 0
- [ ] curtain up: remote frame shows the desktop (content signature), local
      screens show the curtain
- [ ] password typed locally lifts it; wrong attempts throttle
- [ ] client disconnect, server stop and app quit all lift it
- [ ] `kill -9` of the app leaves neither a black screen nor suppressed input
- [ ] the UI never claims the Mac is locked
