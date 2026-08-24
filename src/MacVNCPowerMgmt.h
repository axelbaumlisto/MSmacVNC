#pragma once

#include <rfb/rfb.h>

/*
 * Legacy IOPM aggressiveness-based screen dimming/sleep control.
 *
 * Note: display wake for remote viewing is handled separately by
 * MacVNCDisplayWake (NoDisplaySleep assertion). This module preserves the
 * original dim/sleep-prevention behavior tied to the server lifecycle.
 */

/* When TRUE, prevent the display from dimming while the server runs. */
extern rfbBool preventDimming;
/* When TRUE, prevent the system from sleeping while the server runs. */
extern rfbBool preventSleep;

/* Initialise power management and apply prevent-dim/prevent-sleep. */
int dimmingInit(void);

/* Temporarily bump activity to undim/keep awake (called on input events). */
int undim(void);

/* Restore original dim/sleep settings and tear down. */
int dimmingShutdown(void);
