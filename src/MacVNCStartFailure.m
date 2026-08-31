#import "MacVNCStartFailure.h"

MacVNCStartAdvice macVNCResolveStartAdvice(MacVNCStartOutcome outcome)
{
    if (outcome.started)
        return MacVNCStartAdviceNone;

    /* Already running is not a failure. Advising a port change here would be
       actively misleading: the server is serving on the current port. */
    if (outcome.alreadyRunning)
        return MacVNCStartAdviceNone;

    /* A bad configuration is reported even when permissions are missing: the
       user must fix it regardless, and its message is specific. */
    if (outcome.hasConfigurationError)
        return MacVNCStartAdviceConfiguration;

    /* Without permissions the permission flow already owns the conversation;
       a port-collision alert on top of it would be both wrong and stacked over
       the panel the user needs to act on. */
    if (!outcome.permissionsGranted)
        return MacVNCStartAdviceNone;

    return MacVNCStartAdvicePortInUse;
}

NSString *macVNCStartAdviceTitle(MacVNCStartAdvice advice)
{
    if (advice == MacVNCStartAdvicePortInUse)
        return @"macVNC could not start the server";
    return nil;
}

NSString *macVNCStartAdviceBody(MacVNCStartAdvice advice)
{
    if (advice == MacVNCStartAdvicePortInUse)
        return @"The VNC server failed to start. The most likely cause is that "
                "the port is already in use — for example macOS Screen Sharing "
                "on port 5900, or another macVNC instance. Choose a different "
                "port in Preferences and start the server again.";
    return nil;
}

bool
macVNCShouldActOnCaptureFailure(uint64_t reported, uint64_t current,
                                uint64_t *lastHandled)
{
    if (reported != current)
        return false;
    if (lastHandled != NULL && reported == *lastHandled)
        return false;
    if (lastHandled != NULL)
        *lastHandled = reported;
    return true;
}

MacVNCCaptureFailureResponse
macVNCResolveCaptureFailure(bool likelyPermissionDenial,
                            bool anyDisplayStillAttached,
                            int viewersConnected)
{
    /* The permission is the one failure the user must be told about, because
       only they can grant it back. */
    if (likelyPermissionDenial)
        return MacVNCCaptureFailurePermission;

    /* Nobody was watching. Whatever the streams did, taking the listener down
       costs a remote user their way in and buys nothing - and this is the
       common case, because a capturer outlives the stream it stopped and can
       report failure long after the last viewer left. */
    if (viewersConnected <= 0)
        return MacVNCCaptureFailureKeepServing;

    /* Something is still attached: a panel asleep, a mode change, one monitor
       of several gone. Drop the captures, keep the door open, let the next
       viewer rebuild against the desk as it then is. */
    if (anyDisplayStillAttached)
        return MacVNCCaptureFailureKeepServing;

    /* No displays at all: there is genuinely nothing to serve. */
    return MacVNCCaptureFailureStopServer;
}
