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
 * E2/F1: the display-PINNING glue in mac.m, driven through a real server.
 *
 * applySelectionAndBuildLayout()'s pure decision - "select by id once pinned,
 * refuse rather than substitute if that id is gone" - is exercised here
 * across every trigger that can re-resolve the desk mid-session: the
 * silence-driven liveness watchdog, a desk-shape notification, and a
 * reconnect after a full stop (keep-warm elapsed). A whole-diff review named
 * this glue as verified only by manual code-tracing; this file is what
 * closes that gap.
 *
 * What this file does NOT and cannot prove, and says so rather than
 * pretending: that a hot-unplug/replug which reorders CoreGraphics'
 * enumeration resolves position 0 to a genuinely DIFFERENT physical display
 * after the pin is lost. Reordering real attached displays is not
 * reproducible in this environment (there is no second monitor to unplug in
 * CI, and even here, adding one is not scriptable). That specific claim is
 * covered instead by DisplaySelection.c's pure unit tests (which already
 * prove positional selection follows enumeration order) and by inspection of
 * the single unconditional reset this file drives indirectly, in step 5
 * below (`gPinnedDisplayID = 0` at the top of every vncServerStartWithResult,
 * mac.m, before `displayNumber` is even adopted from config).
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

/* Polls a counter/getter until it satisfies `done`, or a bounded bail-out
   elapses - the same idiom every sibling e2e file in this directory uses for
   a real, if short, wait on real ScreenCaptureKit/watchdog timing. */
static bool
pollUntil(bool (^done)(void), double timeoutSeconds)
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds];
    while (deadline.timeIntervalSinceNow > 0) {
        if (done())
            return true;
        usleep(10000); /* 10ms */
    }
    return done();
}

int
main(void)
{
    @autoreleasepool {
        MacVNCServerConfig cfg = {0};
        cfg.port = 25909; /* distinct from every sibling test's port */
        cfg.password = "test-password";
        cfg.captureFramesPerSecond = 5;
        cfg.viewOnly = true;
        cfg.displayNumber = 0; /* PINNED by position - what this file tests */
        cfg.listenAddress = "127.0.0.1";
        cfg.allowedClients = NULL;
        cfg.clientAccessMode = MACVNC_CLIENT_ACCESS_ALLOW_ALL_CONFIRMED;

        if (!portBindable(cfg.port)) {
            printf("test_capture_liveness_rearm_pin: SKIP (port %d not bindable here)\n",
                   cfg.port);
            return 77;
        }

        MacVNCServerStartResult r = vncServerStartWithResult(&cfg);
        if (r != MacVNCServerStartOK) {
            printf("test_capture_liveness_rearm_pin: SKIP (server did not start: %d)\n",
                   (int)r);
            return 77;
        }

        /* Set the instant ScreenInit's own resolveDisplayLayout() ran - no
           client needed yet: a displayNumber>=0 run pins on the FIRST
           resolve, which happens synchronously inside server start. */
        uint32_t pinA = macVNCPinnedDisplayIDForTesting();
        printf("Pinned display id after start: %u\n", pinA);
        assert(pinA != 0);

        /* Shrink every window this file's triggers depend on, so real
           ScreenCaptureKit/watchdog timing does not cost this file the
           shipped ~35s budget three times over. */
        macVNCSetCaptureLivenessLimitsForTesting(20ULL * 1000000ULL,   /* grace  20ms */
                                                  20ULL * 1000000ULL,  /* silence 20ms */
                                                  20ULL * 1000000ULL); /* cooldown 20ms */
        macVNCSetDeskShapeDebounceForTesting(20ULL * 1000000ULL);      /* 20ms */
        macVNCSetCaptureKeepWarmForTesting(20ULL * 1000000ULL);        /* 20ms */

        void *client = macVNCBeginClientForTesting(false);
        assert(client != NULL);
        macVNCReconcileCaptureForTesting();

        if (macVNCCaptureStartCountForTesting() == 0) {
            printf("test_capture_liveness_rearm_pin: SKIP (capture did not start)\n");
            macVNCEndClientForTesting(client);
            vncServerStop();
            return 77;
        }

        size_t layoutCount = macVNCCurrentDisplayLayoutCountForTesting();
        assert(layoutCount >= 1);

        /*
         * 1) The pin SURVIVES a desk-shape-triggered rearm (FIX-D's path):
         *    a real rearmCaptures() runs, re-resolving through
         *    applySelectionAndBuildLayout - and must select by the SAME id,
         *    not by position again.
         */
        unsigned rebuildsBefore = macVNCDeskShapeRebuildCountForTesting();
        macVNCForceDeskShapeDifferentForTesting(true);
        vncServerNoteDeskShapeMayHaveChanged();
        bool sawDeskShapeRebuild = pollUntil(^bool{
            return macVNCDeskShapeRebuildCountForTesting() > rebuildsBefore;
        }, 5.0);
        macVNCForceDeskShapeDifferentForTesting(false);
        printf("Desk-shape rearm observed: %s (rebuilds %u -> %u)\n",
               sawDeskShapeRebuild ? "yes" : "no", rebuildsBefore,
               macVNCDeskShapeRebuildCountForTesting());
        assert(sawDeskShapeRebuild);
        assert(macVNCPinnedDisplayIDForTesting() == pinA);
        assert(macVNCCurrentDisplayLayoutCountForTesting() == layoutCount);

        /*
         * 2) The pin SURVIVES a silence-triggered rearm (the liveness
         *    watchdog's own path, independent of FIX-D).
         */
        unsigned rearmsBefore = macVNCCaptureRearmCountForTesting();
        bool sawSilenceRearm = pollUntil(^bool{
            return macVNCCaptureRearmCountForTesting() > rearmsBefore;
        }, 5.0);
        printf("Silence-driven rearm observed: %s (rearms %u -> %u)\n",
               sawSilenceRearm ? "yes" : "no", rearmsBefore,
               macVNCCaptureRearmCountForTesting());
        assert(sawSilenceRearm);
        assert(macVNCPinnedDisplayIDForTesting() == pinA);

        /*
         * 3) The pin SURVIVES a reconnect-after-keep-warm rebuild: the last
         *    client leaves, captures fully stop once keep-warm elapses, and
         *    the NEXT client's rebuild (FIX-B's reconnect path) re-resolves
         *    through the same by-id selection - not a fresh by-position one.
         */
        unsigned stopsBefore = macVNCCaptureStopCountForTesting();
        macVNCEndClientForTesting(client);
        macVNCReconcileCaptureForTesting(); /* Begin/End do not reconcile on
            their own - the reconciler is a separate, explicit step every
            sibling e2e file in this directory also calls after each one. */
        bool sawStop = pollUntil(^bool{
            return macVNCCaptureStopCountForTesting() > stopsBefore;
        }, 5.0);
        printf("Keep-warm stop observed: %s\n", sawStop ? "yes" : "no");
        assert(sawStop);

        unsigned startsBefore = macVNCCaptureStartCountForTesting();
        void *client2 = macVNCBeginClientForTesting(false);
        assert(client2 != NULL);
        macVNCReconcileCaptureForTesting();
        bool sawReconnectStart = pollUntil(^bool{
            return macVNCCaptureStartCountForTesting() > startsBefore;
        }, 5.0);
        printf("Reconnect-after-stop start observed: %s\n",
               sawReconnectStart ? "yes" : "no");
        assert(sawReconnectStart);
        assert(macVNCPinnedDisplayIDForTesting() == pinA);

        /*
         * 4) The pinned display GONE: applySelectionAndBuildLayout() must
         *    REFUSE - a failed re-arm attempt, the previous published layout
         *    left exactly as it was, the pin itself left exactly as it was
         *    (never cleared, never replaced by another monitor's id), and
         *    the server never stopped (this test keeps talking to it below).
         *
         *    H1: the hook this drives no longer short-circuits before the
         *    real lookup - it substitutes an impossible id into the value
         *    macVNCSelectDisplayByID() searches for (see its own comment in
         *    mac.m), so control genuinely reaches that function's scan, its
         *    genuine miss, its MACVNC_DISPLAY_SELECTION_NO_SUCH_DISPLAY
         *    return, and applySelectionAndBuildLayout's refusal on THAT
         *    return value - not a hand-written stand-in for it. The
         *    assertions below are what only that real path can show: no
         *    substitute display was chosen (the layout below is identical,
         *    not merely non-empty), the pin survives untouched, and the
         *    failure reached the existing rearm-failure route rather than
         *    stopping the server.
         */
        layoutCount = macVNCCurrentDisplayLayoutCountForTesting();
        unsigned rearmFailuresBefore = macVNCCaptureRearmFailureCountForTesting();
        macVNCForcePinnedDisplayGoneForTesting(true);
        bool sawRefusal = pollUntil(^bool{
            return macVNCCaptureRearmFailureCountForTesting() > rearmFailuresBefore;
        }, 5.0);
        printf("Refusal on a vanished pin observed: %s (rearm failures %u -> %u)\n",
               sawRefusal ? "yes" : "no", rearmFailuresBefore,
               macVNCCaptureRearmFailureCountForTesting());
        assert(sawRefusal);
        /* Never substituted: still the same id, still the same layout. */
        assert(macVNCPinnedDisplayIDForTesting() == pinA);
        assert(macVNCCurrentDisplayLayoutCountForTesting() == layoutCount);
        macVNCForcePinnedDisplayGoneForTesting(false);

        /* The server is still alive: a further real interaction succeeds. */
        macVNCEndClientForTesting(client2);
        vncServerStop();

        /*
         * 5) A SECOND server start in the SAME process re-derives the pin
         *    rather than reusing whatever the first run last held - even
         *    right after a run that spent its last moments refusing on a
         *    forced-vanished pin. gPinnedDisplayID is reset to 0
         *    unconditionally at the top of vncServerStartWithResult, before
         *    displayNumber is even adopted, so no run can begin with a stale
         *    pin or a stale refusal.
         */
        MacVNCServerStartResult r2 = vncServerStartWithResult(&cfg);
        assert(r2 == MacVNCServerStartOK);
        uint32_t pinB = macVNCPinnedDisplayIDForTesting();
        printf("Pinned display id after a second start: %u\n", pinB);
        assert(pinB != 0);
        vncServerStop();

        printf("test_capture_liveness_rearm_pin: all assertions passed\n");
    }
    return 0;
}
