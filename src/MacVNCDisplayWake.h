#pragma once

/*
 * Wakes the Mac's display on demand for remote viewing.
 *
 * A remote VNC client needs a live display to capture; if the Mac dims or
 * sleeps the screen, ScreenCaptureKit yields no frames (blank/black remote
 * screen). These helpers nudge the display awake WITHOUT holding a persistent
 * NoDisplaySleep assertion (that would behave like a built-in caffeinate).
 * Sustained sleep/dim prevention, if desired, lives in MacVNCPowerMgmt.
 */

/* Wake the display now by declaring local user activity so a sleeping/dimmed
 * screen lights up and the idle timer resets. Holds no persistent assertion.
 * Safe to call repeatedly (e.g. on each client connect). */
void macVNCWakeDisplays(void);

/* Retained for API symmetry; no persistent assertion is held, so this is a
 * no-op. Safe to call. */
void macVNCReleaseDisplayAssertion(void);
