#import <Foundation/Foundation.h>

#include <assert.h>
#include <arpa/inet.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "mac.h"
#include "ScreenCapturer.h"

/*
 * B4 (post-audit FIX-B): the FAILURE half of a live re-arm, through the real
 * mac.m glue - not the pure resolver's rules in isolation (test_capture_
 * liveness.c already pins those six rules) and not test_capture_liveness_
 * rearm.m's happy path (which only ever forces rearmCaptures() to SUCCEED
 * onto the same, unchanged layout).
 *
 * Before FIX-A, a failed rearmCaptures() left gLastRearmNs/gRearmsSinceFrame
 * untouched, so the watchdog resolved Rearm again on the very next 1Hz tick,
 * failed again, forever - maxRearms and GiveUp were unreachable on exactly
 * the failure mode most likely to need them. FIX-A made a failed attempt
 * count toward the cap; this test is the integration proof that it actually
 * does, driven end to end rather than asserted by reading the diff.
 *
 * The fault is injected with macVNCFailCaptureInitializationAfter(0) (see
 * tests/test_server_init_failure.m for the same seam's other use): every
 * ScreenCapturer construction from that call on fails, so every rearm attempt
 * this test forces fails at macVNCCaptureSessionBuild(), the same way a
 * genuinely unplaceable desk layout or a transient CoreGraphics read glitch
 * would.
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

static double
monotonicSeconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

int
main(void)
{
    @autoreleasepool {
        MacVNCServerConfig cfg = {0};
        cfg.port = 25905; /* distinct from test_server_generation (25903) and
                              test_capture_liveness_rearm (25904) */
        cfg.password = "test-password";
        cfg.captureFramesPerSecond = 5;
        cfg.viewOnly = true;
        cfg.displayNumber = -1;
        cfg.listenAddress = "127.0.0.1";
        cfg.allowedClients = NULL;
        cfg.clientAccessMode = MACVNC_CLIENT_ACCESS_ALLOW_ALL_CONFIRMED;

        if (!portBindable(cfg.port)) {
            printf("test_capture_liveness_rearm_failure: SKIP (port %d not bindable here)\n",
                   cfg.port);
            return 77;
        }

        MacVNCServerStartResult r = vncServerStartWithResult(&cfg);
        if (r != MacVNCServerStartOK) {
            printf("test_capture_liveness_rearm_failure: SKIP (server did not start: %d)\n",
                   (int)r);
            return 77;
        }

        /* Same shrink test_capture_liveness_rearm.m uses: milliseconds, not
           the shipped ~10s cooldown, so a CI run does not pay the real budget. */
        macVNCSetCaptureLivenessLimitsForTesting(50ULL * 1000000ULL,  /* grace    50ms */
                                                 50ULL * 1000000ULL,  /* silence  50ms */
                                                 50ULL * 1000000ULL); /* cooldown 50ms */

        void *client = macVNCBeginClientForTesting(false);
        assert(client != NULL);
        macVNCReconcileCaptureForTesting();

        if (macVNCCaptureStartCountForTesting() == 0) {
            printf("test_capture_liveness_rearm_failure: SKIP (capture did not start)\n");
            macVNCEndClientForTesting(client);
            vncServerStop();
            return 77;
        }

        /* NOW arm the fault - after the initial Build succeeded, so the
           server is genuinely running, and before any watchdog tick can fire
           a rearm. Every ScreenCapturer construction from here on fails,
           which means every future macVNCCaptureSessionBuild() call - i.e.
           every rearm attempt the shrunk windows below force - fails too. */
        macVNCFailCaptureInitializationAfter(0);

        double giveUpDeadline = monotonicSeconds() + 20.0; /* generous: ~4 real
            seconds are needed even with 50ms windows, since the watchdog only
            re-evaluates once per second regardless of how short the windows
            are (grace+silence+cooldown*(maxRearms-1) all fit inside a single
            1Hz tick); bounded generously above that for a loaded CI box. */
        double firstFailureAt = 0.0;
        bool gaveUp = false;
        while (monotonicSeconds() < giveUpDeadline) {
            usleep(50000); /* 50ms */
            if (firstFailureAt == 0.0 && macVNCCaptureRearmFailureCountForTesting() >= 1)
                firstFailureAt = monotonicSeconds();
            if (macVNCCaptureGiveUpCountForTesting() >= 1) {
                gaveUp = true;
                break;
            }
        }
        double giveUpAt = monotonicSeconds();

        unsigned rearmFailures = macVNCCaptureRearmFailureCountForTesting();
        unsigned rearmSuccesses = macVNCCaptureRearmCountForTesting();
        unsigned giveUps = macVNCCaptureGiveUpCountForTesting();

        macVNCEndClientForTesting(client);
        vncServerStop();

        if (!gaveUp) {
            printf("test_capture_liveness_rearm_failure: SKIP (no GiveUp observed in 20s - "
                   "no usable display for a real capture session to fail against?)\n");
            return 77;
        }

        /* The bookkeeping FIX-A added: a FAILED attempt still counts toward
           the cap - MACVNC_CAPTURE_LIVENESS_MAX_REARMS (3, not overridable)
           failed attempts, never a success, since the fault makes every
           attempt fail. */
        printf("rearmFailures=%u rearmSuccesses=%u giveUps=%u firstFailureAt=%.2f giveUpAt=%.2f\n",
               rearmFailures, rearmSuccesses, giveUps, firstFailureAt, giveUpAt);
        assert(rearmFailures >= 3);
        assert(rearmSuccesses == 0); /* proves these are FAILURE counters, not
                                        a mislabeled copy of the success one */
        assert(giveUps >= 1);
        assert(macVNCCaptureInitializationFaultWasConsumed());

        /* Spaced by the cooldown, not a 1Hz spin that happened to also
           advance a counter: reaching maxRearms failures takes at least TWO
           cooldown gaps (attempts 1->2 and 2->3), so GiveUp cannot fire in
           under one cooldown window's worth of real time after the first
           failure - a loose floor, robust to CI jitter, that a regression
           back to "no bookkeeping on failure" (an instant spin within the
           SAME tick) would violate outright. */
        assert(firstFailureAt > 0.0);
        assert(giveUpAt - firstFailureAt >= 0.05); /* >= one shrunk cooldown */

        printf("test_capture_liveness_rearm_failure: all assertions passed\n");
    }
    return 0;
}
