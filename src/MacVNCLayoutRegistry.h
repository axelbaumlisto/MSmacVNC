#pragma once

#include "DisplayLayout.h"

#include <stdint.h>

/*
 * Ownership of the desk's current shape, extracted from mac.m
 * (.pi/plans/core-decomposition.md, step 7) so the double-buffer/generation/
 * pin mechanics that used to live as four bare globals in the server core
 * have one file that owns them and one API that reaches them. This is a PURE
 * MOVE (invariant I1): every rule below is unchanged from what mac.m did
 * before this file existed - see MacVNCLayoutRegistry.c for the WHY comments,
 * moved here rather than rewritten.
 */

/*
 * Copy `fresh` into whichever slot is NOT currently published, then publish
 * it with one atomic store. Returns the new current pointer, so a caller
 * that just published can keep using it without a second load - the same
 * ergonomics mac.m's own publishDisplayLayout() always had; the two real
 * callers (resolveDisplayLayout, rearmCaptures) both use the return value
 * for exactly this reason, and forcing a second Current() call after every
 * Publish() would cost an avoidable atomic load in a path that already knows
 * the answer.
 *
 * Single-writer contract: startup's one-time resolve and a re-arm's rebuild
 * are the only writers, and they are already serialised (startup runs before
 * any capture session exists; re-arm is the only thing scheduled on its
 * serial queue) - see MacVNCLayoutRegistry.c for why that makes a lock
 * unnecessary on the write side too.
 */
const MacVNCDisplayLayout *macVNCLayoutRegistryPublish(const MacVNCDisplayLayout *fresh);

/* The currently published layout, or NULL before the first Publish() of this
   process. Callers that need more than one field must load this ONCE into a
   local and read every field through that local - see
   MacVNCLayoutRegistry.c for why re-reading this accessor mid-function would
   defeat the whole point of the pointer swap above. */
const MacVNCDisplayLayout *macVNCLayoutRegistryCurrent(void);

/*
 * Which capture session a frame came from - orthogonal to which LAYOUT is
 * published above. Claims the generation the NEXT capture session Build will
 * use; never reused, never reset for the life of the process (see
 * MacVNCLayoutRegistry.c for why that property is what makes a second server
 * start in the same process safe).
 */
uint64_t macVNCLayoutRegistryNextSessionGeneration(void);

/* The generation currently in effect, for a frame's origin to be checked
   against - see mac.m's compositeCapturedFrame. */
uint64_t macVNCLayoutRegistryCurrentSessionGeneration(void);

/* The display identity a `displayNumber >= 0` selection first resolved to,
   or 0 (kCGNullDirectDisplay, never a real display id) if this run has not
   pinned one yet. Plain last-write-wins at this layer - see
   MacVNCLayoutRegistry.c; the set-once RULE (do not call PinDisplay again
   once a pin exists) is enforced by the caller in mac.m's
   applySelectionAndBuildLayout, exactly as it was before this file existed,
   not by this accessor. */
uint32_t macVNCLayoutRegistryPinnedDisplay(void);
void macVNCLayoutRegistryPinDisplay(uint32_t id);
/* Back to "not yet pinned this run" - called once, at server start, exactly
   where mac.m's vncServerStart already reset gPinnedDisplayID to 0. */
void macVNCLayoutRegistryResetPin(void);
