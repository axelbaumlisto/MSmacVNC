#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * "Has the whole desk woken up yet?"
 *
 * macVNC used to answer this with a threshold - it waited until CoreGraphics
 * reported at least ONE active display and then built its canvas. On a desk
 * that was asleep, the first panel to wake ended the wait and the server came
 * up serving 3840x2160 of a 5550x2715 desk, with the second monitor invisible
 * to every viewer until someone restarted the app by hand.
 *
 * The fix is not a longer wait, it is a TARGET. CGGetOnlineDisplayList reports
 * every attached display - measured, with correct bounds, while asleep - so the
 * number to wait for is known before the waiting starts. This is the rule that
 * compares the two sets, kept pure so the awkward cases have tests rather than
 * a comment.
 */

/*
 * True when every id in `expected` appears in `active`.
 *
 * Order is irrelevant: CoreGraphics does not promise the two lists agree on it,
 * and a positional comparison would report "not ready" forever on a desk whose
 * lists merely differ in order.
 *
 * An EMPTY expectation is ready: there is nothing to wait for. That is not a
 * degenerate case to shrug at - it is what happens when the online list cannot
 * be read at all, and answering "wait" there would hang startup for the full
 * budget every time.
 */
bool macVNCDisplaysAllActive(const uint32_t *active, size_t activeCount,
                             const uint32_t *expected, size_t expectedCount);

/*
 * Copies into `out` the expected ids that are NOT active, so the caller can
 * name them in a log line instead of reporting a bare count. Returns how many
 * were written, never more than `outCapacity`.
 */
size_t macVNCDisplaysMissing(const uint32_t *active, size_t activeCount,
                             const uint32_t *expected, size_t expectedCount,
                             uint32_t *out, size_t outCapacity);
