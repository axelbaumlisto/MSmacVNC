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
bool macVNCShouldActOnCaptureFailure(uint64_t reported,
                                     uint64_t current,
                                     uint64_t *lastHandled);

/* Title and body for an advice that has a fixed message. Returns nil for
   advices whose text belongs to the caller (None, Configuration). */
NSString *_Nullable macVNCStartAdviceTitle(MacVNCStartAdvice advice);
NSString *_Nullable macVNCStartAdviceBody(MacVNCStartAdvice advice);

NS_ASSUME_NONNULL_END
