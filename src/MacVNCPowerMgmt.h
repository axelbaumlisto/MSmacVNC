#pragma once

#include <rfb/rfb.h>

/*
 * Legacy IOPM aggressiveness-based screen dimming/sleep control.
 *
 * Note: one-shot display wake for remote viewing is handled separately by
 * MacVNCDisplayWake (user-activity nudge, no persistent assertion). This
 * module preserves the original dim/sleep-prevention behavior tied to the
 * server lifecycle.
 */

/* Configure prevent-dim / prevent-sleep before dimmingInit(). Replaces the
 * former mutable extern globals with an explicit setter (config, not state). */
void macVNCSetPowerPolicy(rfbBool preventDimming, rfbBool preventSleep);

/* Initialise power management and apply the configured prevent-dim/sleep. */
int dimmingInit(void);

/* Temporarily bump activity to undim/keep awake (called on input events). */
int undim(void);

/* Restore original dim/sleep settings and tear down. */
int dimmingShutdown(void);
