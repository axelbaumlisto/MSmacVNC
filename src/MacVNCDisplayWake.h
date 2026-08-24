#pragma once

/*
 * Keeps the Mac's display awake for remote viewing.
 *
 * A remote VNC client needs a live display to capture; if the Mac dims or
 * sleeps the screen, ScreenCaptureKit yields no frames (blank/black remote
 * screen). These helpers wake the display and hold a NoDisplaySleep power
 * assertion for the lifetime of the session.
 */

/* Wake the display now and declare local user activity so a sleeping/dimmed
 * screen lights up. Also acquires (once) a NoDisplaySleep assertion that is
 * held until macVNCReleaseDisplayAssertion(). Safe to call repeatedly. */
void macVNCWakeDisplays(void);

/* Release the NoDisplaySleep assertion acquired by macVNCWakeDisplays(). */
void macVNCReleaseDisplayAssertion(void);
