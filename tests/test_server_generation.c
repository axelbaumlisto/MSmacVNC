#include <assert.h>
#include <stdio.h>
#include <pthread.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
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

/* Can this process bind the port at all? If not, skip VISIBLY (77): a green
   "skipped" print once made this target pass on hosts where start was broken,
   indistinguishable from a host that cannot bind. */
static int portBindable(int port)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((uint16_t)port);
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    int rc = bind(fd, (struct sockaddr *)&addr, sizeof(addr));
    close(fd);
    return rc == 0;
}

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

    if (!portBindable(cfg.port)) {
        printf("test_server_generation: SKIP (port %d not bindable here)\n", cfg.port);
        return 77;
    }

    MacVNCServerStartResult r = vncServerStartWithResult(&cfg);
    if (r == MacVNCServerStartFailed) {
        /* The port IS bindable, so a failure here is a real regression. */
        fprintf(stderr, "FAIL server would not start although the port is free\n");
        return 1;
    }
    uint64_t afterStart = vncServerCurrentGeneration();
    if (r == MacVNCServerStartAlreadyRunning) {
        printf("test_server_generation: SKIP (server already running)\n");
        vncServerStop();
        return 77;
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
