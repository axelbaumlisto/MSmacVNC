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

/*
 * Hold the display and the system awake for as long as the SERVER is running,
 * rather than for as long as a viewer is watching.
 *
 * A SEPARATE pair from the session assertions above, and separate on purpose.
 * Those exist while somebody is looking; this one exists because the machine
 * must still be reachable when nobody is - and its cost is real, so it is off
 * unless the user asks for it.
 *
 * The reason it exists at all was learned the hard way. macOS was configured to
 * lock immediately when the display turns off; the display never turned off,
 * because macVNC leaked a UserIsActive assertion and a caffeinate agent was
 * running besides. Fixing the leak and removing the agent made both supports
 * vanish at once, and every remote connection then landed on the macOS login
 * screen. Doing it here means the behaviour belongs to the tool that needs it,
 * is visible in Preferences, and dies with the process the way an assertion
 * should - unlike a launchd agent or a global pmset value.
 *
 * Idempotent: calling it repeatedly with the same value creates nothing new.
 */
void macVNCSetKeepDisplayAwake(rfbBool enabled);

/* Whether the keep-awake assertions are currently held. */
rfbBool macVNCKeepDisplayAwakeIsHeld(void);

/* Test hooks: how many activity nudges actually fired. */
unsigned macVNCUndimNudgeCountForTesting(void);
void macVNCResetUndimCountForTesting(void);
