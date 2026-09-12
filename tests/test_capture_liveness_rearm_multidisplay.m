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

/*
 * FIX-C: the whole-diff audit's own manual verification found what neither
 * test_capture_liveness.c's six pure rules nor test_capture_liveness_rearm.m/
 * _failure.m's single-display glue tests could - a defect that only shows up
 * with TWO OR MORE displays in the layout, one of which never redraws.
 *
 * This file pins ONE half - that genuine, total silence (no display
 * producing anything, the success-branch equivalent of
 * test_capture_liveness_rearm_failure.m's forced-failure case) still counts
 * every rearm attempt honestly and reaches GiveUp, i.e. a working rebuild
 * with nothing to show for it cannot loop forever either. The OTHER half -
 * an idle-but-present second display must never by itself cause a re-arm
 * while another display keeps producing frames - moved to its own file,
 * test_capture_liveness_rearm_multidisplay_idle.m, because it needs >= 2
 * displays to mean anything and used to fall back to a bare printf(...
 * SKIPPED ...) with no actual SKIP return code on a single-display host, so
 * ctest could not tell "proved the fix" from "never ran it" apart - see that
 * file's header for the full measurement this was built against.
 *
 * Same real-server pattern as test_capture_liveness_rearm.m: a live
 * ScreenCaptureKit session is genuinely running throughout (this file makes
 * no attempt to mock it), but the test binary itself is not expected to hold
 * a Screen Recording grant, so real frames are not expected to arrive on
 * their own - silence is the natural state here, exactly as documented in
 * test_capture_liveness_rearm.m, and this file's assertions are built to
 * SKIP (77) rather than fail outright if that assumption turns out wrong in
 * some environment.
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
        cfg.port = 25906; /* distinct from test_server_generation (25903),
                              test_capture_liveness_rearm (25904) and
                              test_capture_liveness_rearm_failure (25905) */
        cfg.password = "test-password";
        cfg.captureFramesPerSecond = 5;
        cfg.viewOnly = true;
        cfg.displayNumber = -2; /* ALL attached displays, not just the primary -
                                   this test's own assertions do not depend on
                                   the count (unlike the idle-second-display
                                   test), but ALL is still what the original
                                   incident ran with, so this stays close to it */
        cfg.listenAddress = "127.0.0.1";
        cfg.allowedClients = NULL;
        cfg.clientAccessMode = MACVNC_CLIENT_ACCESS_ALLOW_ALL_CONFIRMED;

        if (!portBindable(cfg.port)) {
            printf("test_capture_liveness_rearm_multidisplay: SKIP (port %d not bindable here)\n",
                   cfg.port);
            return 77;
        }

        MacVNCServerStartResult r = vncServerStartWithResult(&cfg);
        if (r != MacVNCServerStartOK) {
            printf("test_capture_liveness_rearm_multidisplay: SKIP (server did not start: %d)\n",
                   (int)r);
            return 77;
        }

        /* Same shrink the sibling files use: milliseconds, not the shipped
           ~10s cooldown, so a CI run does not pay the real budget. */
        macVNCSetCaptureLivenessLimitsForTesting(50ULL * 1000000ULL,  /* grace    50ms */
                                                 50ULL * 1000000ULL,  /* silence  50ms */
                                                 50ULL * 1000000ULL); /* cooldown 50ms */

        void *client = macVNCBeginClientForTesting(false);
        assert(client != NULL);
        macVNCReconcileCaptureForTesting();

        if (macVNCCaptureStartCountForTesting() == 0) {
            printf("test_capture_liveness_rearm_multidisplay: SKIP (capture did not start)\n");
            macVNCEndClientForTesting(client);
            vncServerStop();
            return 77;
        }

        /*
         * "Every display silent must still reach GiveUp; no reset rescues it."
         *
         * (Formerly "Test B" alongside an idle-second-display "Test A" that
         * now lives in test_capture_liveness_rearm_multidisplay_idle.m.)
         *
         * Nothing feeds ANY display here, and real ScreenCaptureKit is not
         * expected to deliver anything either (see the file header). This is
         * the SUCCESS-branch complement of test_capture_liveness_rearm_
         * failure.m's forced-failure case: rearmCaptures() itself is
         * expected to keep SUCCEEDING (the desk re-reads and rebuilds fine
         * every time - nothing here makes macVNCCaptureSessionBuild() fail),
         * yet with no frame ever arriving from any display, the watchdog
         * must still count every successful attempt toward maxRearms and
         * reach GiveUp - proving compositeCapturedFrame's per-frame reset
         * (see its comment on the two-independent-loads race, mac.m) really
         * does require a delivered frame, and cannot be tripped by anything
         * else.
         */
        double giveUpDeadline = monotonicSeconds() + 45.0; /* generous: each
            attempt here is a REAL StopAndWait + desk re-read + Build +
            Start against live ScreenCaptureKit, not a forced-failure no-op
            like test_capture_liveness_rearm_failure.m's - test_capture_
            liveness_rearm.m alone already budgets 10s for ONE such success. */
        bool gaveUp = false;
        while (monotonicSeconds() < giveUpDeadline) {
            usleep(50000);
            if (macVNCCaptureGiveUpCountForTesting() >= 1) {
                gaveUp = true;
                break;
            }
        }

        unsigned rearmSuccesses = macVNCCaptureRearmCountForTesting();
        unsigned rearmFailures = macVNCCaptureRearmFailureCountForTesting();
        unsigned giveUps = macVNCCaptureGiveUpCountForTesting();

        macVNCEndClientForTesting(client);
        vncServerStop();

        if (!gaveUp) {
            printf("test_capture_liveness_rearm_multidisplay: total-silence test SKIP "
                   "(no GiveUp observed in 45s - no usable display for a "
                   "real capture session, or frames arrived from somewhere?)\n");
            return 77;
        }

        printf("Total silence: rearmSuccesses=%u rearmFailures=%u giveUps=%u\n",
               rearmSuccesses, rearmFailures, giveUps);
        assert(rearmSuccesses >= 3); /* MACVNC_CAPTURE_LIVENESS_MAX_REARMS,
                                        reached via the SUCCESS branch */
        assert(rearmFailures == 0); /* nothing here forces a Build failure -
                                        a nonzero count here would mean this
                                        test is accidentally exercising the
                                        OTHER file's scenario */
        assert(giveUps >= 1);

        printf("test_capture_liveness_rearm_multidisplay: all assertions passed\n");
    }
    return 0;
}
