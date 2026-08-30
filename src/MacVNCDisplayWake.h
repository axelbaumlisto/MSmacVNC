#pragma once

#include <stdbool.h>

/*
 * Wakes the Mac's display on demand for remote viewing.
 *
 * A remote VNC client needs a live display to capture; if the Mac dims or
 * sleeps the screen, ScreenCaptureKit yields no frames (blank/black remote
 * screen). Sustained sleep/dim prevention lives in MacVNCPowerMgmt; this module
 * is about the transition.
 *
 * IT DOES HOLD AN ASSERTION, and this header used to deny it.
 * IOPMAssertionDeclareUserActivity is not a fire-and-forget nudge: it creates a
 * UserIsActive assertion and hands back an ID that stays held until released.
 * The old wording ("holds no persistent assertion", "this is a no-op") was
 * measured false on a live machine - `pmset -g assertions` showed
 * `macVNC remote session` held continuously for hours with no viewer connected,
 * which by itself stopped the display ever idle-sleeping. Release is therefore
 * a real obligation, paired with the last viewer leaving rather than with the
 * server stopping: a listener under "Start at Login" runs for weeks.
 */

/* Wake the display now by declaring local user activity, so a sleeping or
 * dimmed screen lights up and the idle timer resets. Safe to call repeatedly:
 * the same assertion ID is passed back in, which updates the existing activity
 * instead of accumulating assertions. */
void macVNCWakeDisplays(void);

/* Release the assertion. Idempotent, and safe when nothing was ever declared.
 * Must be called when the last viewer goes away, not only at server stop. */
void macVNCReleaseDisplayAssertion(void);

#if defined(MACVNC_ENABLE_TEST_HOOKS)
/* Whether an assertion is currently held - the witness that makes the leak
   above visible to a test instead of only to pmset. */
bool macVNCDisplayWakeIsHoldingForTesting(void);
#endif
