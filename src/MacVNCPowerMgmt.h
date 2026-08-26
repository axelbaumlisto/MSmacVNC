#pragma once

#include <rfb/rfb.h>

/*
 * Keep the machine awake for the duration of a remote session, via ONE
 * process-scoped kIOPMAssertionTypeNoIdleSleep assertion.
 *
 * Deliberately NOT the old save/restore of the global Energy Saver timers:
 * that had no owner-death cleanup, so a crash or the app's own restart left
 * the Mac on "never sleep" permanently. Assertions die with the process.
 *
 * Display wake on demand is MacVNCDisplayWake's job: it nudges user activity
 * without holding anything; this module holds exactly one assertion while the
 * server runs. Neither ever touches a global pmset value.
 */

/* Configure prevent-dim / prevent-sleep before dimmingInit().
   preventSleep creates the no-idle-sleep assertion; preventDimming is covered
   by undim()'s activity nudge (macOS has no dim aggressiveness assertion). */
void macVNCSetPowerPolicy(rfbBool preventDimming, rfbBool preventSleep);

/* Create the assertion. Idempotent; returns 0 if already active. */
int dimmingInit(void);

/* Nudge display activity (throttled); called on every input event. */
int undim(void);

/* Release the assertion. Safe when nothing was created. */
int dimmingShutdown(void);
