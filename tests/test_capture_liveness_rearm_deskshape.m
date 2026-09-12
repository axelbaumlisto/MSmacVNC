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
#include "MacVNCCaptureSupervisor.h"

/*
 * FIX-D: react to macOS's own display-configuration notification while a
 * client is watching, instead of waiting for the effect (silence) the
 * liveness watchdog can already see.
 *
 * Why this exists: measured on the installed build (2026-09-12), changing
 * the built-in display's mode mid-session (1710x1112 -> 1470x956) produced
 * 753 client updates and ZERO re-arms while the canvas stayed stuck at the
 * pre-change 5552x2715 composite size. ScreenCapturer.m pins
 * SCStreamConfiguration.width/height at Build time, so a reconfigured
 * display keeps delivering frames - just rescaled to the OLD dimensions -
 * and nothing about that looks like silence to the watchdog.
 *
 * This test drives vncServerNoteDeskShapeMayHaveChanged() directly - the
 * REAL, always-compiled entry point AppDelegate calls from its
 * NSApplicationDidChangeScreenParametersNotification observer - rather than
 * going through AppKit, which test binaries here do not link against. It
 * asserts the DECISION, not the plumbing:
 *   - a burst of notifications collapses into ONE evaluation (debounce);
 *   - an UNCHANGED desk (the real, live one - nothing here reconfigures a
 *     display) triggers no rebuild;
 *   - a desk FORCED to look different (macVNCForceDeskShapeDifferentForTesting,
 *     since faking a real CoreGraphics reconfiguration is neither
 *     reproducible on demand nor available without physical hardware)
 *     triggers EXACTLY one rebuild, through the same already-tested
 *     rearmCaptures() every other trigger uses;
 *   - a notification with NO client connected is a no-op.
 *
 * No Screen Recording grant is required: only whether a rebuild was
 * ATTEMPTED is asserted (macVNCDeskShapeRebuildCountForTesting /
 * macVNCDeskShapeRebuildFailureCountForTesting, both of which advance
 * whether or not real frames ever arrive), never whether frames arrived.
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
        cfg.port = 25908; /* distinct from every sibling test's port */
        cfg.password = "test-password";
        cfg.captureFramesPerSecond = 5;
        cfg.viewOnly = true;
        cfg.displayNumber = -2;
        cfg.listenAddress = "127.0.0.1";
        cfg.allowedClients = NULL;
        cfg.clientAccessMode = MACVNC_CLIENT_ACCESS_ALLOW_ALL_CONFIRMED;

        if (!portBindable(cfg.port)) {
            printf("test_capture_liveness_rearm_deskshape: SKIP (port %d not bindable here)\n",
                   cfg.port);
            return 77;
        }

        MacVNCServerStartResult r = vncServerStartWithResult(&cfg);
        if (r != MacVNCServerStartOK) {
            printf("test_capture_liveness_rearm_deskshape: SKIP (server did not start: %d)\n",
                   (int)r);
            return 77;
        }

        /* Shrink the debounce so this test does not pay the shipped 500ms
           per assertion - same shrink-for-speed pattern every sibling file
           uses on its own windows. */
        const uint64_t debounceNs = 40ULL * 1000000ULL; /* 40ms */
        macVNCSetDeskShapeDebounceForTesting(debounceNs);
        /* Shipped liveness windows stay large (no shrink here): this file's
           assertions are about the DEBOUNCE timer, and a shrunk silence
           window could race a real watchdog-driven rearm into the same
           counters this test never touches (gCaptureRearmCount) - but an
           accidental GiveUp/capture-failure modal mid-test would still be
           noise worth avoiding. */

        void *client = macVNCBeginClientForTesting(false);
        assert(client != NULL);
        macVNCReconcileCaptureForTesting();

        if (macVNCCaptureStartCountForTesting() == 0) {
            printf("test_capture_liveness_rearm_deskshape: SKIP (capture did not start)\n");
            macVNCEndClientForTesting(client);
            vncServerStop();
            return 77;
        }

        double settle = (double)debounceNs / 1e9 + 0.5; /* generous slack over
            the debounce window itself, so a slow CI machine still observes
            the firing rather than racing it */

        /*
         * 1) Burst of N notifications while the desk genuinely has not
         *    changed => exactly ONE evaluation, and it decides "no rebuild".
         */
        for (int i = 0; i < 8; ++i) {
            vncServerNoteDeskShapeMayHaveChanged();
            usleep(5000); /* 5ms apart - well inside the 40ms debounce, so
                              every call in this loop reschedules the SAME
                              firing rather than producing its own */
        }
        usleep((useconds_t)(settle * 1000000.0));
        unsigned rechecksAfterBurst = macVNCDeskShapeRecheckCountForTesting();
        unsigned rebuildsAfterBurst = macVNCDeskShapeRebuildCountForTesting();
        printf("Burst of 8 notifications (unchanged desk): rechecks=%u rebuilds=%u\n",
               rechecksAfterBurst, rebuildsAfterBurst);
        assert(rechecksAfterBurst == 1); /* the burst debounced to ONE evaluation */
        assert(rebuildsAfterBurst == 0); /* the real desk did not change, so it
                                             decided against a rebuild */

        /*
         * 2) A desk FORCED to look different => exactly one rebuild, via the
         *    real rearmCaptures() (unmocked) every other trigger already uses.
         */
        macVNCForceDeskShapeDifferentForTesting(true);
        vncServerNoteDeskShapeMayHaveChanged();
        usleep((useconds_t)(settle * 1000000.0));
        macVNCForceDeskShapeDifferentForTesting(false); /* stop forcing before
            anything else in this process re-evaluates, so a later,
            unrelated recheck cannot also count as "different" by accident */
        unsigned rechecksAfterForce = macVNCDeskShapeRecheckCountForTesting();
        unsigned rebuildsAfterForce = macVNCDeskShapeRebuildCountForTesting();
        unsigned rebuildFailuresAfterForce = macVNCDeskShapeRebuildFailureCountForTesting();
        printf("Forced-different notification: rechecks=%u rebuilds=%u rebuildFailures=%u\n",
               rechecksAfterForce, rebuildsAfterForce, rebuildFailuresAfterForce);
        assert(rechecksAfterForce == rechecksAfterBurst + 1); /* exactly one
            MORE evaluation for exactly one MORE notification */
        assert(rebuildsAfterForce == rebuildsAfterBurst + 1); /* exactly one
            rebuild - rearmCaptures() re-reads the REAL (unchanged) desk
            internally and still succeeds via its own same-shape branch */
        assert(rebuildFailuresAfterForce == 0); /* nothing here makes
            macVNCCaptureSessionBuild() fail */

        /*
         * 3) No client connected => vncServerNoteDeskShapeMayHaveChanged() is
         *    a no-op: no new recheck, no new rebuild.
         */
        macVNCEndClientForTesting(client); /* decrements vncConnectedClients
            to 0 synchronously (uncountClientLocked) - no need to wait out a
            keep-warm window just to prove the NEXT call is a no-op */
        vncServerNoteDeskShapeMayHaveChanged();
        usleep((useconds_t)(settle * 1000000.0));
        unsigned rechecksWhileIdle = macVNCDeskShapeRecheckCountForTesting();
        printf("Notification with no client connected: rechecks=%u (expect unchanged at %u)\n",
               rechecksWhileIdle, rechecksAfterForce);
        assert(rechecksWhileIdle == rechecksAfterForce); /* no new evaluation -
            the early return in vncServerNoteDeskShapeMayHaveChanged() never
            even reached the debounce timer */

        vncServerStop();

        printf("test_capture_liveness_rearm_deskshape: all assertions passed\n");
    }
    return 0;
}
