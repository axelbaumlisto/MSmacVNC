#include "MacVNCLayoutRegistry.h"

#include <stdatomic.h>
#include <stddef.h>

/* Physical display a `displayNumber >= 0` selection resolved to, once per
   server run; 0 (never real) means "not yet pinned". _Atomic: read
   cross-thread by macVNCPinnedDisplayIDForTesting() - see ARCHITECTURE.md
   § MacVNCLayoutRegistry for why a plain uint32_t was unsafe. */
static _Atomic uint32_t gPinnedDisplayID;
uint32_t
macVNCLayoutRegistryPinnedDisplay(void)
{
    return atomic_load(&gPinnedDisplayID);
}

void
macVNCLayoutRegistryPinDisplay(uint32_t id)
{
    atomic_store(&gPinnedDisplayID, id);
}

void
macVNCLayoutRegistryResetPin(void)
{
    atomic_store(&gPinnedDisplayID, 0);
}

/* Double-buffered: two fixed slots plus an atomic pointer, so a publish is
   one atomic store into the non-published slot, never an in-place mutation
   the unlocked hot-path read in mac.m's compositeCapturedFrame could tear
   against. See ARCHITECTURE.md § CaptureLiveness for the race this replaced. */
static MacVNCDisplayLayout gDisplayLayoutSlots[2];
static _Atomic(MacVNCDisplayLayout *) gPublishedLayout = NULL;
/* Load ONCE into a local; re-reading mid-function would defeat the swap. */
const MacVNCDisplayLayout *
macVNCLayoutRegistryCurrent(void)
{
    return atomic_load(&gPublishedLayout);
}

/* Copies into the non-published slot, then publishes with one atomic store. */
const MacVNCDisplayLayout *
macVNCLayoutRegistryPublish(const MacVNCDisplayLayout *fresh)
{
    MacVNCDisplayLayout *live = atomic_load(&gPublishedLayout);
    MacVNCDisplayLayout *target = (live == &gDisplayLayoutSlots[0])
        ? &gDisplayLayoutSlots[1] : &gDisplayLayoutSlots[0];
    *target = *fresh;
    atomic_store(&gPublishedLayout, target);
    return target;
}

/* Which capture session a frame came from - orthogonal to which LAYOUT is
   published above (a same-shape re-arm bumps this without a new publish -
   see ARCHITECTURE.md § MacVNCLayoutRegistry). Bumped once per Build() call,
   never reused; 0 means "never Built", first claimed value is 1. Never
   reset for the process's life, so a stale frame from a previous run
   cannot collide either. */
static _Atomic uint64_t gCaptureSessionGeneration = 0;
/* Called in mac.m's rearmCaptures BEFORE StopAndWait: any frame the old
   session might still deliver must find the generation already advanced. */
uint64_t
macVNCLayoutRegistryNextSessionGeneration(void)
{
    /* fetch_add returns the PRE-increment value; +1 is this call's claim. */
    return atomic_fetch_add(&gCaptureSessionGeneration, 1) + 1;
}

uint64_t
macVNCLayoutRegistryCurrentSessionGeneration(void)
{
    return atomic_load(&gCaptureSessionGeneration);
}
