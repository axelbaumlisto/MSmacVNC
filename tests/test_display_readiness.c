/*
 * Waiting for the whole desk, rather than for the first monitor that answers.
 *
 * The bug these assertions exist for was measured, not imagined: macVNC was
 * restarted while both panels were asleep, the external one woke first, the
 * "at least one active display" wait ended there, and the server served a
 * 3840x2160 canvas of a 5550x2715 desk. Every viewer lost a whole monitor
 * until somebody restarted the app by hand.
 *
 * The opposite failure matters too and is quieter: a rule that waits for a
 * display which is never coming back - a monitor switched off at the wall -
 * spends the entire startup budget on every launch and then serves the same
 * thing anyway.
 */

#include <assert.h>
#include <stdio.h>

#include "DisplayReadiness.h"

static void
testTheMeasuredBug(void)
{
    /* Two attached panels; only the external one has woken. */
    const uint32_t expected[] = { 3, 1 };
    const uint32_t halfAwake[] = { 3 };
    assert(!macVNCDisplaysAllActive(halfAwake, 1, expected, 2));

    /* ...and once the built-in follows, the wait ends. */
    const uint32_t bothAwake[] = { 3, 1 };
    assert(macVNCDisplaysAllActive(bothAwake, 2, expected, 2));
}

static void
testSameCountIsNotTheSameDesk(void)
{
    /* Two awake displays, two expected - and one of them is a monitor we were
       never waiting for. A readiness rule written as "enough displays are up"
       reports ready here and the server builds its canvas around a panel that
       may still be mid-wake. Happens for real when a display is swapped or
       renumbered while we wait. */
    const uint32_t expected[] = { 3, 1 };
    const uint32_t different[] = { 3, 7 };
    assert(!macVNCDisplaysAllActive(different, 2, expected, 2));

    /* Even a longer active list does not help if the one we want is absent. */
    const uint32_t manyWrong[] = { 7, 8, 9 };
    assert(!macVNCDisplaysAllActive(manyWrong, 3, expected, 2));
}

static void
testOrderIsIrrelevant(void)
{
    /* CoreGraphics does not promise the online and active lists agree on
       order. A positional comparison would wait forever on this desk. */
    const uint32_t expected[] = { 3, 1 };
    const uint32_t activeReversed[] = { 1, 3 };
    assert(macVNCDisplaysAllActive(activeReversed, 2, expected, 2));
}

static void
testExtraActiveDisplaysDoNotBlock(void)
{
    /* More awake than expected is ready: a display that appeared between the
       two readings is not a reason to keep waiting. */
    const uint32_t expected[] = { 3 };
    const uint32_t active[] = { 3, 1, 7 };
    assert(macVNCDisplaysAllActive(active, 3, expected, 1));
}

static void
testNothingExpectedIsReady(void)
{
    /* The "online list unreadable" path. Answering "keep waiting" here would
       burn the whole startup budget on every launch and change nothing. */
    const uint32_t active[] = { 3 };
    assert(macVNCDisplaysAllActive(active, 1, NULL, 0));
    assert(macVNCDisplaysAllActive(NULL, 0, NULL, 0));

    const uint32_t expected[] = { 3 };
    assert(macVNCDisplaysAllActive(NULL, 0, expected, 0));
}

static void
testNothingActiveIsNotReady(void)
{
    /* A wholly asleep desk must keep waiting - this is the state the server
       used to refuse to start in, and it must not silently read as ready. */
    const uint32_t expected[] = { 3, 1 };
    assert(!macVNCDisplaysAllActive(NULL, 0, expected, 2));
}

static void
testMissingDisplaysAreNamed(void)
{
    /* The log line must be able to say WHICH monitor never woke; a bare count
       leaves the user guessing which cable to check. */
    const uint32_t expected[] = { 3, 1, 9 };
    const uint32_t active[] = { 1 };
    uint32_t missing[4] = { 0 };
    size_t n = macVNCDisplaysMissing(active, 1, expected, 3, missing, 4);
    assert(n == 2);
    assert(missing[0] == 3);
    assert(missing[1] == 9);
}

static void
testMissingRespectsCapacity(void)
{
    const uint32_t expected[] = { 3, 1, 9 };
    uint32_t one[1] = { 0 };
    assert(macVNCDisplaysMissing(NULL, 0, expected, 3, one, 1) == 1);
    assert(one[0] == 3);

    /* No buffer, no writing, no crash. */
    assert(macVNCDisplaysMissing(NULL, 0, expected, 3, NULL, 4) == 0);
    assert(macVNCDisplaysMissing(NULL, 0, expected, 3, one, 0) == 0);
    assert(macVNCDisplaysMissing(NULL, 0, NULL, 3, one, 1) == 0);
}

static void
testNothingMissingWhenAllAwake(void)
{
    const uint32_t expected[] = { 3, 1 };
    const uint32_t active[] = { 1, 3 };
    uint32_t missing[4] = { 0 };
    assert(macVNCDisplaysMissing(active, 2, expected, 2, missing, 4) == 0);
}

int
main(void)
{
    testTheMeasuredBug();
    testSameCountIsNotTheSameDesk();
    testOrderIsIrrelevant();
    testExtraActiveDisplaysDoNotBlock();
    testNothingExpectedIsReady();
    testNothingActiveIsNotReady();
    testMissingDisplaysAreNamed();
    testMissingRespectsCapacity();
    testNothingMissingWhenAllAwake();

    puts("test_display_readiness: all assertions passed");
    return 0;
}
