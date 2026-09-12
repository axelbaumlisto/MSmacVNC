#include "MacVNCLayoutRegistry.h"

#include <stdatomic.h>
#include <stddef.h>

/* E2: once a `displayNumber >= 0` selection has been resolved by POSITION for
   the first time in a server run, this remembers the concrete display it
   picked, so every LATER re-resolution (a capture-liveness re-arm, mid-
   session) follows that identity rather than re-reading the same numeric
   position - which a desk event can silently hand to a different physical
   monitor. 0 (kCGNullDirectDisplay) means "not yet pinned this run": real
   CGDirectDisplayID values are never 0. Reset to 0 at every server (re)start,
   alongside `displayNumber` itself - see mac.m's vncServerStart. -1 (primary)
   and -2 (all) never populate this; they keep re-evaluating live, which is
   what those settings mean.

   _Atomic (H2): written on the capture control path, but read cross-thread
   by macVNCPinnedDisplayIDForTesting() from a test's own thread. A plain
   uint32_t here was safe only by accident - every test read happened to be
   preceded by polling a DIFFERENT atomic counter (a rearm/rebuild count)
   whose ordering gave a transitive happens-before edge to this one, a
   property a future refactor could silently break by moving this store
   relative to that counter's increment. Written at most once per
   resolution, so the atomic costs nothing that matters. */
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

/*
 * The published display layout, double-buffered.
 *
 * Before this, `displayLayout` was a single static struct that a re-arm
 * overwrote IN PLACE (`displayLayout = freshLayout;`) whenever the desk
 * changed shape. compositeCapturedFrame() - the per-display capture hot path,
 * running at up to 60 fps per display - read that same struct with no lock:
 * it scans `displayLayout.count` comparing `&displayLayout.displays[i]` against
 * its `geometry` pointer, then snapshots `*geometry`. A capture callback from
 * the just-stopped OLD session can still be in flight when that copy runs -
 * MacVNCCaptureSession.h documents exactly this: StopAndWait's wait is
 * bounded, and a stream whose work never quiesced is deliberately leaked
 * rather than freed because a callback may still touch it. So the multi-field
 * copy could tear against that read: `count` from one publish compared
 * against `displays[]` from another. Bounded (displays[] is a fixed
 * MACVNC_MAX_DISPLAYS array, never out-of-bounds; worst case is a dropped
 * frame or one stale-pixel frame that heals on the next real one - see
 * .pi/plans/capture-liveness.md), but new exposure from the shape-changed
 * re-arm, not present before it.
 *
 * The fix is PUBLISH BY POINTER SWAP, never mutate what is currently
 * published: two fixed slots hold successive publications of the layout, and
 * an atomic pointer says which one is current. A reader loads that pointer
 * ONCE and reads only through it, so every field it sees belongs to the same
 * publish - no lock needed on the hot path, because nothing ever writes into
 * the slot the pointer currently designates as published.
 *
 * Two slots, not one-per-publish: a writer publishing into slot N+1 always
 * targets whichever slot is NOT currently published (the one last holding
 * publish N-1, already retired one publish ago), so it never touches the live
 * slot. A stuck callback from publish N-1 keeps a valid (never freed) pointer
 * into that slot; if TWO MORE re-arms land before that callback finally shows
 * up, the slot has since been reused for publish N+1, and the callback reads
 * WHATEVER publish N+1 put there - not a torn read (still one atomic load's
 * worth of a complete, self-consistent MacVNCDisplayLayout, never
 * out-of-bounds, never freed memory), but not that callback's own generation
 * either.
 *
 * That residual case is closed by a DIFFERENT mechanism, not by adding a
 * third slot: mac.m's compositeCapturedFrame no longer identifies a frame by
 * which slot its geometry pointer happens to still address at all - see
 * MacVNCCaptureFrameOrigin and the session generation below, which reject
 * a stale frame by an explicit, never-reused counter BEFORE it ever reads a
 * slot's content, so a callback from ANY retired generation - one re-arm
 * stale or a hundred - never reaches a read of this structure in the first
 * place. What these two slots still exist for is narrower and unrelated: give
 * every reader that DOES pass that check (or never needed it - freshestFrameStamp,
 * ScreenInit) a torn-free, single-load view of the layout's own fields, so a
 * concurrent re-arm publishing a new shape can never be observed as `count`
 * from one shape and `displays[]` from another.
 *
 * Writers (resolveDisplayLayout at startup, rearmCaptures on re-arm, both in
 * mac.m) are always serialised - startup runs once before any capture
 * session exists, and re-arm is the only thing scheduled on gCaptureStopQueue,
 * a serial queue - so no lock is needed on the write side either; the atomic
 * pointer is what makes the SWAP itself visible to readers as a single
 * indivisible step, not what serialises writers against each other.
 */
static MacVNCDisplayLayout gDisplayLayoutSlots[2];
static _Atomic(MacVNCDisplayLayout *) gPublishedLayout = NULL;

/* The currently published layout. Callers that need more than one field must
   load this ONCE into a local and read every field through that local - see
   mac.m's compositeCapturedFrame for why re-reading this accessor
   mid-function would defeat the whole point of the pointer swap below. */
const MacVNCDisplayLayout *
macVNCLayoutRegistryCurrent(void)
{
    return atomic_load(&gPublishedLayout);
}

/* Copy `fresh` into whichever slot is NOT currently published, then publish
   it with one atomic store. Returns the new current pointer, so a caller that
   just published can keep using it without a second load. */
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

/*
 * Which capture session a frame came from - orthogonal to which LAYOUT is
 * published above. A re-arm that finds the desk unchanged rebuilds its
 * session onto the SAME already-published MacVNCDisplayLayout object (see
 * mac.m's rearmCaptures same-shape branch) rather than publishing a second,
 * identical copy of it - so a layout publish and a new capture session are
 * NOT the same event, and identifying a session by "which layout publish it
 * used" would fail to tell two such sessions apart. This counter is bumped
 * once per macVNCCaptureSessionBuild() call, always, whether or not the
 * layout changed, and never reused - so a frame carrying any value other than
 * the CURRENT one came from a session that is no longer THE session,
 * regardless of how many re-arms separate the two or whether the desk's
 * shape ever changed at all. See MacVNCCaptureFrameOrigin for how a frame
 * carries this, and mac.m's compositeCapturedFrame for where it is checked.
 *
 * 0 is reserved for "never Built against a real generation" and cannot
 * collide with a real one - the first claimed generation is 1 (see
 * macVNCLayoutRegistryNextSessionGeneration). No capture session is ever
 * Built with generation 0 in practice, but reserving it costs nothing and
 * gives a frame with a garbage/zeroed origin an unambiguous "never matches"
 * answer.
 *
 * Never reset for the life of the process - not even across a second
 * vncServerStart in the same run - which is what makes a stale frame from a
 * PREVIOUS server run just as unable to collide with the current one as a
 * stale frame from one re-arm ago: there is exactly one counter, monotonic
 * for the process, not per-server-run.
 */
static _Atomic uint64_t gCaptureSessionGeneration = 0;

/* Claims the generation the NEXT macVNCCaptureSessionBuild() call will use.
   Called exactly once per Build call site, and in mac.m's rearmCaptures
   BEFORE StopAndWait rather than right before Build - see rearmCaptures for
   why that ordering, not proximity to Build, is what actually matters:
   claiming it here means ANY frame the old, about-to-be-stopped session
   might still deliver - even one delivered while StopAndWait is still
   draining, even one from a stream that never quiesced and was deliberately
   leaked - already finds the session generation advanced past its own
   value, however early it arrives. */
uint64_t
macVNCLayoutRegistryNextSessionGeneration(void)
{
    /* fetch_add returns the PRE-increment value; +1 gives the generation this
       call just claimed, so the very first call returns 1, never the 0
       sentinel above. */
    return atomic_fetch_add(&gCaptureSessionGeneration, 1) + 1;
}

uint64_t
macVNCLayoutRegistryCurrentSessionGeneration(void)
{
    return atomic_load(&gCaptureSessionGeneration);
}
