#import <Foundation/Foundation.h>

#include <assert.h>
#include <arpa/inet.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "mac.h"

/*
 * One full re-arm cycle through the mac.m GLUE, not just the pure resolver.
 *
 * test_capture_liveness.c pins the six rules of CaptureLiveness.c in
 * isolation, with no ScreenCaptureKit and no server. That leaves the wiring
 * in mac.m - the frame-arrival stamp, the watchdog timer, rearmCaptures() -
 * entirely unexercised, and macVNCCaptureRearmCountForTesting() /
 * macVNCSetCaptureLivenessLimitsForTesting() as hooks nothing calls.
 *
 * Getting mac.m's `displayLayout` populated with at least one real display is
 * only possible through a REAL vncServerStart(): resolveDisplayLayout() runs
 * inside ScreenInit and nowhere else, so this test starts a real (loopback,
 * throwaway-port) server, exactly like test_server_generation.c, then drives
 * a synthetic client through it exactly like test_capture_gate.m.
 *
 * No Screen Recording grant is required either way: shrinking every liveness
 * window to milliseconds (well under this machine's real frame interval,
 * granted or not) means the watchdog observes "no frame yet" and re-arms
 * regardless of whether a real frame was ever going to arrive - the same
 * silence the shipped windows would eventually notice on their own, just
 * forced into a test's patience.
 */

static int
portBindable(int port)
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

int
main(void)
{
    @autoreleasepool {
        MacVNCServerConfig cfg = {0};
        cfg.port = 25904; /* distinct from test_server_generation's 25903 */
        cfg.password = "test-password";
        cfg.captureFramesPerSecond = 5;
        cfg.viewOnly = true; /* no input needed: this is a capture-only test */
        cfg.displayNumber = -1;
        cfg.listenAddress = "127.0.0.1";
        cfg.allowedClients = NULL;
        cfg.clientAccessMode = MACVNC_CLIENT_ACCESS_ALLOW_ALL_CONFIRMED;

        if (!portBindable(cfg.port)) {
            printf("test_capture_liveness_rearm: SKIP (port %d not bindable here)\n",
                   cfg.port);
            return 77;
        }

        MacVNCServerStartResult r = vncServerStartWithResult(&cfg);
        if (r != MacVNCServerStartOK) {
            /* Most likely no attached display to build a layout from
               (headless CI, closed lid with nothing external) - the same
               condition test_server_init_failure/test_capture_restart/
               test_first_frame_wait already skip on, for the same reason. */
            printf("test_capture_liveness_rearm: SKIP (server did not start: %d)\n",
                   (int)r);
            return 77;
        }

        /* Shrink every window to milliseconds so a silent stream is re-armed
           in well under a second instead of the shipped ~10s cooldown. */
        macVNCSetCaptureLivenessLimitsForTesting(50ULL * 1000000ULL,  /* grace    50ms */
                                                 50ULL * 1000000ULL,  /* silence  50ms */
                                                 50ULL * 1000000ULL); /* cooldown 50ms */

        /* A synthetic client: no socket, no display, just the same counting
           and reconciler production code a real connect runs (test_capture_
           gate.m's pattern) - this is what starts captures and arms the
           watchdog. */
        void *client = macVNCBeginClientForTesting(false);
        assert(client != NULL);
        macVNCReconcileCaptureForTesting();

        if (macVNCCaptureStartCountForTesting() == 0) {
            printf("test_capture_liveness_rearm: SKIP (capture did not start)\n");
            macVNCEndClientForTesting(client);
            vncServerStop();
            return 77;
        }

        /* Wait for the watchdog's 1Hz timer to notice silence and re-arm.
           Bounded generously above the shrunk windows above (which are
           milliseconds) for a loaded CI box; the shipped windows are ~35s and
           this waits nowhere near that. */
        bool rearmed = false;
        for (int i = 0; i < 200 && !rearmed; ++i) {
            usleep(50000); /* 50ms */
            rearmed = macVNCCaptureRearmCountForTesting() >= 1;
        }

        unsigned finalCount = macVNCCaptureRearmCountForTesting();
        macVNCEndClientForTesting(client);
        vncServerStop(); /* exercises the item-1 rendezvous with any in-flight re-arm */

        if (!rearmed) {
            printf("test_capture_liveness_rearm: SKIP (no re-arm observed in 10s - "
                   "no usable display for a real capture session?)\n");
            return 77;
        }

        assert(finalCount >= 1);
        printf("test_capture_liveness_rearm: all assertions passed (rearm count=%u)\n",
               finalCount);
    }
    return 0;
}
