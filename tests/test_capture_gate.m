#import <Foundation/Foundation.h>

#include <assert.h>
#include <stdio.h>

#include "mac.h"

/*
 * The injected capture-permission gate.
 *
 * Before macVNCCaptureAllowed existed, the core called
 * CGPreflightScreenCaptureAccess() itself, so "capture must not start without
 * the permission" could not be asserted anywhere: the answer came from the
 * machine's real TCC state. That rule is the one protecting the project's
 * hardest requirement - macVNC must never cause macOS's own permission dialog,
 * and touching capture without the grant is what causes it.
 */

static int gAskCount = 0;
static bool gAnswer = false;

static bool countingGate(void)
{
    ++gAskCount;
    return gAnswer;
}

int main(void)
{
    @autoreleasepool {
        /* No gate installed means unrestricted, so an embedder or a unit test
           without a permission model still captures. */
        macVNCCaptureAllowed = NULL;
        assert(macVNCCaptureIsAllowedForTesting() == true);

        /* Permission refused: the core must decide NOT to touch capture. This
           is the rule that keeps macOS's own dialog from ever appearing. */
        macVNCCaptureAllowed = countingGate;
        gAnswer = false;
        gAskCount = 0;
        assert(macVNCCaptureIsAllowedForTesting() == false);
        assert(gAskCount == 1); /* asked the injected policy, not TCC */

        /* Permission granted: capture is allowed. */
        gAnswer = true;
        assert(macVNCCaptureIsAllowedForTesting() == true);
        assert(gAskCount == 2);

        /* Answer is re-read every time, never cached: the grant can be revoked
           while the server runs. */
        gAnswer = false;
        assert(macVNCCaptureIsAllowedForTesting() == false);
        assert(gAskCount == 3);

        /* The seam must be resettable, or a stale pointer would answer for a
           previous run's process state. */
        macVNCCaptureAllowed = NULL;
        assert(macVNCCaptureIsAllowedForTesting() == true);

        printf("test_capture_gate: all assertions passed\n");
    }
    return 0;
}
