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
 * Server stop: withdraw the bit if - and only if - we are holding it.
 *
 * Deliberately NOT unconditional. The bit is machine-wide, shared with powerd
 * and with apps like Amphetamine, and has no reference count, so clearing it
 * regardless of ownership would silently cancel theirs. Records left by another
 * process or another boot are Start's business, not this function's.
 *
 * Does NOT latch. Stopping the server is a reversible act - the user can press
 * Start again, a failed start calls this on its way out, and a display change
 * may one day restart the server by itself - so a stop that permanently
 * disabled the feature would be a silent, unexplainable loss.
 */
void macVNCClamshellReleaseForServerStop(void);

/*
 * Quit path: the same withdrawal, plus a latch that no later connection can
 * undo.
 *
 * The latch is not decoration. Termination releases the bit while the listener
 * may still be accepting, and the backstop release inside the server stop sits
 * behind a teardown the quit path is allowed to abandon on a timeout - so a
 * viewer authenticating in that window could re-arm a bit that then outlives
 * the process. Only the quit path may latch; see above.
 */
void macVNCClamshellShutdown(void);

#if defined(MACVNC_ENABLE_TEST_HOOKS)
/* Whether the quit latch is set - the witness that keeps a server stop from
   quietly acquiring it again. */
bool macVNCClamshellIsTerminatingForTesting(void);
#endif

