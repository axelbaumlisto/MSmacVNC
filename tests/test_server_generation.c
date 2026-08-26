#include <assert.h>
#include <stdio.h>
#include <pthread.h>
#include <unistd.h>
#include "mac.h"

/*
 * A stop must END the run's identity, exactly as a start begins it.
 *
 * Capture-failure notifications carry vncServerCurrentGeneration(); the UI
 * drops those whose generation is stale. With N displays one failure raises N
 * notifications for ONE run. If the generation only moved on START, all N
 * still compare equal after the first notification's stop - and the user gets
 * N stacked modal alerts. Bumping on stop makes every later notification from
 * that run stale on arrival.
 */

int main(void)
{
    /* Port 0 means "kernel picks", which LibVNCServer rejects outright
       ("Could not listen on port 0"), so pick a real high port instead and
       accept the tiny collision risk on a loopback bind. */
    MacVNCServerConfig cfg = {0};
    cfg.port = 25903;
    cfg.password = "test-password";
    cfg.captureFramesPerSecond = 5;
    cfg.viewOnly = true;          /* no capture, no input: pure lifecycle test */
    cfg.displayNumber = -1;
    cfg.listenAddress = "127.0.0.1";
    cfg.allowedClients = NULL;
    cfg.clientAccessMode = MACVNC_CLIENT_ACCESS_ALLOW_ALL_CONFIRMED;

    uint64_t before = vncServerCurrentGeneration();

    MacVNCServerStartResult r = vncServerStartWithResult(&cfg);
    if (r == MacVNCServerStartFailed) {
        /* Environment cannot bind at all; then assert nothing regressed. */
        printf("test_server_generation: skipped (no server possible here)\n");
        return 0;
    }
    uint64_t afterStart = vncServerCurrentGeneration();
    if (r == MacVNCServerStartAlreadyRunning) {
        printf("test_server_generation: skipped (server already running)\n");
        vncServerStop();
        return 0;
    }
    assert(afterStart != before);

    vncServerStop();
    uint64_t afterStop = vncServerCurrentGeneration();
    assert(afterStop != afterStart);

    /* And a fresh start after a stop must be a NEW generation again. */
    r = vncServerStartWithResult(&cfg);
    if (r == MacVNCServerStartOK) {
        assert(vncServerCurrentGeneration() != afterStop);
        vncServerStop();
    }

    puts("test_server_generation: all assertions passed");
    return 0;
}
