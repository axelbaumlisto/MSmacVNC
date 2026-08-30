#import <Foundation/Foundation.h>

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>

#include "mac.h"
#include "MacVNCDisplayWake.h"
#include "MacVNCClamshell.h"

/*
 * The two client counts, and the window between them.
 *
 * The server counts an authenticated client twice, at two different moments,
 * and the difference is not bookkeeping pedantry - it is what stops curtain
 * mode blacking out the local screen while the remote viewer is still looking
 * at a placeholder:
 *
 *   vncConnectedClients                     moves when the password is
 *                                           accepted, because that is what has
 *                                           to START the captures that produce
 *                                           the first frame;
 *   vncAuthenticatedClientsReceivingUpdates moves only after the first-frame
 *                                           wait has ended - up to 8 seconds
 *                                           later on a cold start.
 *
 * Curtain mode reads the SECOND one, and it reads it on a 2 s timer as well as
 * on the server's notification, so the increment itself (not merely the
 * announcement) has to happen after the wait. That was a real bug once: the
 * announcement was moved and the increment was not, and the timer raised the
 * curtain during the wait anyway.
 *
 * There is no socket and no display here: the hooks drive the SAME counting
 * functions the client paths use, so what is asserted below is the rule
 * itself, not a copy of it.
 */

static int connectedClients(void)
{
    return atomic_load(&vncConnectedClients);
}

static int clientsReceivingUpdates(void)
{
    return atomic_load(&vncAuthenticatedClientsReceivingUpdates);
}

int main(void)
{
    @autoreleasepool {
        atomic_store(&vncConnectedClients, 0);
        atomic_store(&vncAuthenticatedClientsReceivingUpdates, 0);

        /* A client whose password was accepted and which is now inside the
           first-frame wait. Captures must know about it - they are what makes
           the frame - and the curtain must NOT, because there is nothing to
           hide behind yet. */
        /* Stopping the server must not permanently disable closed-display
           mode. The quit latch used to live in the release path that every
           server stop runs, so Stop followed by Start in the menu killed the
           feature for the rest of the app's life, silently. Only termination
           may latch. */
        assert(!macVNCClamshellIsTerminatingForTesting());
        macVNCClamshellReleaseForServerStop();
        assert(!macVNCClamshellIsTerminatingForTesting());

        assert(!macVNCDisplayWakeIsHoldingForTesting());
        void *waiting = macVNCBeginClientForTesting(false);
        assert(waiting != NULL);
        assert(connectedClients() == 1);
        assert(clientsReceivingUpdates() == 0);

        /* The display wake is tied to COUNTING a client, not to accepting a
           socket. It used to fire in newClient(), before authentication, which
           meant anyone able to reach the port could light up this Mac's screen
           without the password - measured with a deliberately wrong one - and
           the UserIsActive assertion it created was never released, because an
           unauthenticated client never reaches the reconciler that releases it. */
        assert(macVNCDisplayWakeIsHoldingForTesting());

        /* Frames arrived: now it counts for the curtain too. */
        macVNCClientReceivedFirstFramesForTesting(waiting);
        assert(connectedClients() == 1);
        assert(clientsReceivingUpdates() == 1);

        /* Idempotent, because the production path re-enters it on any retry:
           a second announcement must not inflate the count and leave a curtain
           standing over nobody. */
        macVNCClientReceivedFirstFramesForTesting(waiting);
        assert(clientsReceivingUpdates() == 1);

        /* A SECOND viewer connects and is still warming up. */
        void *second = macVNCBeginClientForTesting(false);
        assert(second != NULL);
        assert(connectedClients() == 2);
        assert(clientsReceivingUpdates() == 1);

        /* ...and gives up during its own wait. This is the case the guard in
           the disconnect path exists for: it was never added to the narrow
           count, so it must not subtract from it. Without that guard the count
           drops to zero while the FIRST viewer is still watching - which lifts
           a curtain that should have stayed up, on a machine whose owner
           thought the screen was hidden. */
        macVNCEndClientForTesting(second);
        assert(connectedClients() == 1);
        assert(clientsReceivingUpdates() == 1);

        /* The watching viewer leaves: both counts empty out. */
        macVNCEndClientForTesting(waiting);
        assert(connectedClients() == 0);
        assert(clientsReceivingUpdates() == 0);

        /* A client that never got past the wait at all, alone: its disconnect
           must leave the narrow count at zero rather than at -1, which would
           read as "somebody is watching" the moment the next viewer arrives
           and the clamp is applied. */
        void *neverReady = macVNCBeginClientForTesting(false);
        macVNCEndClientForTesting(neverReady);
        assert(connectedClients() == 0);
        assert(clientsReceivingUpdates() == 0);

        printf("test_client_counts: all assertions passed\n");
    }
    return 0;
}
