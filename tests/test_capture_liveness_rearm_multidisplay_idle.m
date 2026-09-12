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
 * "An idle-but-present second display cannot trigger a re-arm."
 *
 * Split OUT of test_capture_liveness_rearm_multidisplay.m (which keeps only
 * Test B, "total silence must still reach GiveUp") for one reason: that
 * file's own Test A used to fall back to a bare printf("... SKIPPED ...")
 * and keep running when only one display was available, so the whole binary
 * still exited 0 whether or not Test A's actual assertions ever ran - ctest
 * could not tell "proved the fix" from "never ran it" apart. A real SKIP
 * (return 77, wired to SKIP_RETURN_CODE 77 in CMakeLists.txt, same as this
 * file's siblings) makes that distinction visible in the ctest summary.
 *
 * Measured on the live installed build (2026-09-12): a two-display desk
 * where the user worked on only one panel produced NINE re-arms in about two
 * minutes on the IDLE panel's stale stamp alone, while the ACTIVE display's
 * viewer received a real, working session throughout (end-of-session stats:
 * 3144 ZRLE events, 1547 FramebufferUpdate requests). The old
 * `oldestFrameStamp()` took the MINIMUM stamp over the layout - one display
 * with nothing to redraw looked exactly like a dead stream, forever.
 *
 * Same real-server pattern as test_capture_liveness_rearm.m: a live
 * ScreenCaptureKit session genuinely runs throughout (no mocking), but the
 * test binary is not expected to hold a Screen Recording grant, so real
 * frames are not expected to arrive on their own - this file's synthetic
 * feed for display 0 is what proves the point, and its assertions are built
 * to SKIP (77) rather than fail outright if that assumption ever turns out
 * wrong in some environment.
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
        cfg.port = 25907; /* distinct from every sibling test's port (see
                              test_capture_liveness_rearm_multidisplay.m for
                              the rest of the list) */
        cfg.password = "test-password";
        cfg.captureFramesPerSecond = 5;
        cfg.viewOnly = true;
        cfg.displayNumber = -2; /* ALL attached displays - this test needs at
                                   least two to mean anything, and SKIPs
                                   honestly (77) when the host only has one */
        cfg.listenAddress = "127.0.0.1";
        cfg.allowedClients = NULL;
        cfg.clientAccessMode = MACVNC_CLIENT_ACCESS_ALLOW_ALL_CONFIRMED;

        if (!portBindable(cfg.port)) {
            printf("test_capture_liveness_rearm_multidisplay_idle: SKIP (port %d not bindable here)\n",
                   cfg.port);
            return 77;
        }

        MacVNCServerStartResult r = vncServerStartWithResult(&cfg);
        if (r != MacVNCServerStartOK) {
            printf("test_capture_liveness_rearm_multidisplay_idle: SKIP (server did not start: %d)\n",
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
            printf("test_capture_liveness_rearm_multidisplay_idle: SKIP (capture did not start)\n");
            macVNCEndClientForTesting(client);
            vncServerStop();
            return 77;
        }

        size_t layoutCount = macVNCCurrentDisplayLayoutCountForTesting();
        if (layoutCount < 2) {
            /* The real SKIP this file exists to make visible - see the file
               header. A bare printf here with no return 77 is exactly the
               regression this split fixes. */
            printf("test_capture_liveness_rearm_multidisplay_idle: SKIP "
                   "(only %zu display in the layout; needs >= 2 to make an "
                   "idle SECOND display meaningful)\n", layoutCount);
            macVNCEndClientForTesting(client);
            vncServerStop();
            return 77;
        }

        /*
         * Feed a synthetic frame to display index 0 every 20ms - faster than
         * the 50ms shrunk silence window, so display 0 never itself goes
         * quiet - and NEVER feed display index 1. Under the OLD
         * oldestFrameStamp() (the minimum), display 1's permanently-zero
         * stamp alone would have forced a re-arm within about
         * grace+silence (~100ms) and every ~cooldown (50ms) after,
         * regardless of display 0. Under the fix, silence is the MAXIMUM
         * stamp over the layout, so display 0 alone keeps the watchdog
         * satisfied; run for a comfortable multiple of the real 1Hz
         * watchdog tick (not just the shrunk windows) to prove this holds
         * across several real evaluations, not by luck on the first one.
         */
        double deadline = monotonicSeconds() + 3.5;
        while (monotonicSeconds() < deadline) {
            uint64_t generation = macVNCCurrentCaptureGenerationForTesting();
            macVNCCompositeSyntheticFrameForTesting(generation, 0);
            usleep(20000); /* 20ms */
        }
        unsigned rearms = macVNCCaptureRearmCountForTesting();
        unsigned giveUps = macVNCCaptureGiveUpCountForTesting();

        macVNCEndClientForTesting(client);
        vncServerStop();

        printf("Test (idle second display): rearms=%u giveUps=%u over %zu display(s)\n",
               rearms, giveUps, layoutCount);
        assert(rearms == 0);
        assert(giveUps == 0);

        printf("test_capture_liveness_rearm_multidisplay_idle: all assertions passed\n");
    }
    return 0;
}
