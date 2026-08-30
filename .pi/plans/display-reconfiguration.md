# The desk shape read at server start

## What was actually wrong

macVNC came up serving one monitor instead of two and stayed that way until it
was restarted by hand. The first diagnosis - "the layout is read once and never
re-read" - was right about the symptom and wrong about the cause.

`readAttachedDisplays()` (`src/mac.m:212`) does this:

```c
macVNCWakeDisplays();
for (int attempt = 0; attempt < 20; ++attempt) {
    CGGetActiveDisplayList(0, NULL, &reported);
    if (reported > 0)
        break;                 /* <-- stops at the FIRST non-zero answer */
    macVNCWakeDisplays();
    usleep(250000);
}
```

The comment above it already knows that "a dimmed or slept screen reports zero
active displays", but the loop has no idea **how many** displays to expect, so
it accepts the first partial answer. Restarting macVNC on a desk that was
asleep, the external panel woke first, `reported` became 1, and the built-in was
still on its way up. The server built a 3840x2160 canvas for a 5550x2715 desk.

## The measurement that changed the design

With both panels asleep:

```text
active=0 []
online=2 [3(3840x2160@0,0,спит=да) 1(1710x1112@-1710,1603,спит=да)]
```

`CGGetOnlineDisplayList` reports every attached display **with correct bounds
while it is asleep**. The desk's true shape is available at all times; only the
*active* list, which the code used, collapses during sleep.

That single fact removes the need for the whole subsystem the first version of
this plan proposed.

## Why the first plan was abandoned

It proposed a `CGDisplayRegisterReconfigurationCallback` watcher that would
restart the server whenever the layout changed. Two blind reviews rejected it,
and they were right on facts that the measurement above then confirmed:

- **Its founding premise contradicted our own data.** The plan claimed display
  sleep leaves the layout identical, so restarts would be rare. But a sleeping
  display leaves the *active* list, so the rule would have fired twice per
  screen-off cycle, dropping every viewer each time the local screen dimmed.
- **Re-resolving wakes the screen.** `readAttachedDisplays` calls
  `macVNCWakeDisplays()`, which is `IOPMAssertionDeclareUserActivity`. A
  reconfiguration-triggered re-resolve would light the panel at 3am, declare
  user activity, sleep, and fire again: a loop with the room lights in it.
- **Restart has no safe failure branch.** `vncServerStartWithResult`'s only
  error path is `goto FAILURE` -> `vncServerStopLocked()`, i.e. no listener.
  A pinned `displayNumber` that no longer resolves, mirroring turned on, or the
  bound address momentarily absent would each leave a remote user with no way
  back in.
- **The unplug case never reaches it anyway.** `reportCaptureFailure` already
  stops the server and shows a modal within milliseconds of a monitor going
  away, long before any settle window elapses.

A restart-on-reconfiguration feature is still defensible one day, but it needs
its own plan, an intent gate, a non-waking probe and a failure/backoff story.
Not this change.

## The change

Give the wait a **target** instead of a threshold, taken from the online list.

1. Read the online display list. Drop mirrored secondaries: the active list
   excludes them, the online list does not, and two displays reporting the same
   bounds make `macVNCBuildDisplayLayout` fail as overlapping.
2. Wake, then wait, bounded, until every expected display is also *active* -
   i.e. awake enough for ScreenCaptureKit to stream it.
3. On timeout, proceed with whatever is active and say so in the log, naming
   the displays that did not come up. A desk with a monitor switched off at the
   wall must still serve the rest.
4. Build the layout from the ACTIVE displays, exactly as today. Nothing
   downstream changes.

The set rule in step 2 is pure and gets its own test: given the expected ids and
the currently active ids, are we ready? The waiting stays in `mac.m`.

## Cost and limits

Startup can now take up to the existing 5s budget on a sleeping desk, where
before it took whatever the first panel needed. That is the price of a correct
canvas, it only applies when displays are asleep, and it is bounded by the same
constant as before.

This fixes the desk shape **at start**. It does not react to a monitor plugged
in later - that is still a manual restart, and the reviews above say why doing
it automatically is a bigger change than it looks.

## Out of scope

- Reacting to reconfiguration while running.
- In-place resize with `rfbNewFramebuffer`.
- Pinning `displayNumber` by display ID rather than by list index (a real
  latent bug: the index designates a different monitor after a hot-unplug).
