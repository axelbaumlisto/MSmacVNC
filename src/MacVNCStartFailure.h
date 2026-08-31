#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/*
 * What to tell the user when the server does not come up.
 *
 * A pure decision, separated from AppDelegate's dispatch and NSAlert plumbing:
 * getting it wrong is silent. Reporting a port collision while the real cause
 * is a missing permission sends the user to Preferences instead of the
 * permission panel, and staying quiet on a genuine failure leaves the menu
 * saying "Not running" with no reason given.
 */

typedef struct {
    BOOL started;              /* vncServerStart() succeeded                   */
    BOOL alreadyRunning;       /* a run was already live; nothing changed      */
    BOOL hasConfigurationError;/* startup config refused to build              */
    BOOL permissionsGranted;   /* both permissions currently read as granted   */
} MacVNCStartOutcome;

typedef enum {
    /* Nothing to say: either it started, or the permission flow owns the
       message and a second alert would just stack on top of it. */
    MacVNCStartAdviceNone = 0,
    /* The configuration itself is invalid; the text comes from the builder. */
    MacVNCStartAdviceConfiguration,
    /* Permissions are fine, so the listener is the problem - almost always a
       port already taken by Screen Sharing or another instance. */
    MacVNCStartAdvicePortInUse,
} MacVNCStartAdvice;

MacVNCStartAdvice macVNCResolveStartAdvice(MacVNCStartOutcome outcome);

/*
 * Should this capture-failure notification be ACTED on?
 *
 * Pure decision for handleScreenCaptureFailure:. Two ways to say no:
 *  - reported != current: the run that raised it is no longer live;
 *  - reported == *lastHandled: a notification of this same run was already
 *    acted on. With one capturer per display, several failures arrive
 *    back-to-back before the async stop has bumped the generation, and
 *    without this latch each one stacks another modal alert.
 */
/* lastHandled is optional: passing NULL applies only the staleness rule, which
   is a case the tests exercise deliberately. It was declared non-null by the
   file-wide NS_ASSUME_NONNULL, so those tests compiled with a warning that an
   incremental build then hid from every later "warning-free" claim. */
bool macVNCShouldActOnCaptureFailure(uint64_t reported,
                                     uint64_t current,
                                     uint64_t *_Nullable lastHandled);

/*
 * What a capture failure should COST.
 *
 * Every capture failure used to stop the server and put up a modal, leaving no
 * listener at all. For a remote-access tool that is the most expensive possible
 * response: the recovery it offers - "start it again from the menu" - is in a
 * menu bar the remote user cannot reach. Losing the picture is bad; losing the
 * way back in is unrecoverable.
 *
 * This was not theoretical. Once macVNC stopped leaking the display-wake
 * assertion, its screens could idle-sleep again, and a sleeping display makes
 * ScreenCaptureKit report failure - including for capturers that outlive a
 * stopped stream, since stopping a stream deliberately does not detach the
 * capturer. The server then killed its own listener with nobody even watching.
 */
typedef enum {
    /* Keep the listener. Captures are dropped so the next viewer rebuilds
       them against whatever the desk looks like by then. */
    MacVNCCaptureFailureKeepServing = 0,
    /* The permission itself went away: the gate owns the message. */
    MacVNCCaptureFailurePermission,
    /* Nothing is left to capture, so there is nothing to serve. */
    MacVNCCaptureFailureStopServer,
} MacVNCCaptureFailureResponse;

MacVNCCaptureFailureResponse
macVNCResolveCaptureFailure(bool likelyPermissionDenial,
                            bool anyDisplayStillAttached,
                            int viewersConnected);

/* Title and body for an advice that has a fixed message. Returns nil for
   advices whose text belongs to the caller (None, Configuration). */
NSString *_Nullable macVNCStartAdviceTitle(MacVNCStartAdvice advice);
NSString *_Nullable macVNCStartAdviceBody(MacVNCStartAdvice advice);

NS_ASSUME_NONNULL_END
