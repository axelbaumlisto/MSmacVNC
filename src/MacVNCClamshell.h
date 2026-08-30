#pragma once

#include <stdbool.h>

/*
 * Closed-display mode: keep this Mac running with the lid shut while a viewer
 * is watching.
 *
 * macOS already does this when an external display is attached AND the adaptor
 * is in (IOPMrootDomain::shouldSleepOnClamshellClosed). This module relaxes it
 * to wall power alone, by setting the one remaining term in that expression,
 * clamshellSleepDisableMask, through kPMSetClamshellSleepState.
 *
 * Read MacVNCClamshellPolicy.h before changing anything here: the bit is
 * global, shared with powerd, has no reference count, cannot be read back, and
 * is NOT cleared when this process dies. Everything below exists because of
 * that last clause.
 *
 * All entry points are safe to call from any thread and are idempotent.
 */

/* Re-evaluate and act. Called on client connect/disconnect, on a power source
   change, and when the preference changes. */
void macVNCClamshellReevaluate(void);

/* Start watching the power source. Main thread, once, after defaults are
   registered. Also performs crash recovery: a marker left by a previous run
   means that run died with the bit set, so clear it. */
void macVNCClamshellStart(void);

/*
 * Quit path: latch against any further arming, then withdraw the bit if - and
 * only if - we are holding it.
 *
 * Deliberately NOT unconditional. The bit is machine-wide, shared with powerd
 * and with apps like Amphetamine, and has no reference count, so clearing it
 * regardless of ownership would silently cancel theirs. Records left by another
 * process or another boot are Start's business, not this function's.
 */
void macVNCClamshellShutdown(void);

