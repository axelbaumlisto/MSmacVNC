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
   preventSleep creates the PreventUserIdleSystemSleep assertion;
   preventDimming creates PreventUserIdleDisplaySleep. */
void macVNCSetPowerPolicy(rfbBool preventDimming, rfbBool preventSleep);

/* Create the assertions (idempotent). Returns -1 if a requested assertion
   could not be created; the session still works, the machine may just sleep. */
int dimmingInit(void);

/* Nudge display activity (throttled to 1/s; no-op before dimmingInit). */
int undim(void);

/* Release the assertions. Safe when nothing was created; idempotent. */
int dimmingShutdown(void);

/* Test hooks: how many activity nudges actually fired. */
unsigned macVNCUndimNudgeCountForTesting(void);
void macVNCResetUndimCountForTesting(void);
