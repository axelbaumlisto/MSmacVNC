#import <Foundation/Foundation.h>

#include <assert.h>
#include <stdio.h>

#include <stdatomic.h>

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

        /* The rule that actually matters is not "the gate returns false" but
           "the core does not START capture when it does". Asserted through the
           real reconciler and a start counter, because touching capture without
           the permission is what makes macOS raise its own dialog. */
        macVNCResetCaptureStateForTesting();
        assert(macVNCCaptureStartCountForTesting() == 0);
        assert(macVNCCaptureStopCountForTesting() == 0);

        macVNCCaptureAllowed = countingGate;
        gAnswer = false;
        atomic_store(&vncConnectedClients, 1);   /* a client is waiting */
        macVNCReconcileCaptureForTesting();       /* the real decision path */
        assert(macVNCCaptureStartCountForTesting() == 0); /* refused: no start */

        /* Drop the client and settle, without clearing the counter yet. */
        atomic_store(&vncConnectedClients, 0);
        macVNCReconcileCaptureForTesting();
        assert(macVNCCaptureStartCountForTesting() == 0);

        /* With the permission, the same path does start capture - so the zero
           above is a real refusal, not a path that never runs. */
        gAnswer = true;
        atomic_store(&vncConnectedClients, 1);
        macVNCReconcileCaptureForTesting();
        assert(macVNCCaptureStartCountForTesting() == 1);

        /* The OTHER half of "captures run iff clients > 0": the last client
           leaving must STOP them. Without this witness, deleting the stop
           branch wholesale leaves every target green while captures (and the
           macOS capture indicator) run forever with nobody watching. */
        atomic_store(&vncConnectedClients, 0);
        macVNCReconcileCaptureForTesting();
        assert(macVNCCaptureStopCountForTesting() == 1);

        /* Idempotent in both directions: a reconcile with nobody connected
           must not stop again, one with a client must not start again. */
        macVNCReconcileCaptureForTesting();
        assert(macVNCCaptureStopCountForTesting() == 1);

        atomic_store(&vncConnectedClients, 1);
        macVNCReconcileCaptureForTesting();
        assert(macVNCCaptureStartCountForTesting() == 2);

        atomic_store(&vncConnectedClients, 0);
        macVNCReconcileCaptureForTesting();
        assert(macVNCCaptureStopCountForTesting() == 2);
        macVNCCaptureAllowed = NULL;

        printf("test_capture_gate: all assertions passed\n");
    }
    return 0;
}
