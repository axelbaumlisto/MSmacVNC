#include "CaptureLiveness.h"

MacVNCCaptureLivenessVerdict
macVNCResolveCaptureLiveness(const MacVNCCaptureLivenessInput *input,
                             const MacVNCCaptureLivenessLimits *limits)
{
    if (!input->clientsConnected || !input->capturesRunning)
        return MacVNCCaptureAlive;

    uint64_t sinceStart = input->nowNs - input->capturesStartedNs;

    /* Still warming up: no first frame yet, and a cold start (measured
       1.3-2.1s for two displays, more if a panel was asleep) must not be
       mistaken for a dead stream. */
    if (input->lastFrameNs == 0 && sinceStart < limits->graceNs)
        return MacVNCCaptureAlive;

    uint64_t lastActivity = input->lastFrameNs > input->capturesStartedNs
                                ? input->lastFrameNs
                                : input->capturesStartedNs;
    if (input->nowNs - lastActivity < limits->silenceNs)
        return MacVNCCaptureAlive;

    /* 0 means "never re-armed this run", not "just re-armed at time zero" -
       macVNCMonotonicNow() never returns 0, so treating it as a sentinel
       cannot collide with a real timestamp. Without this a nowNs close to
       zero (never happens in production, but costs nothing to guard) would
       read as "inside the cooldown" on the very first re-arm decision. */
    if (input->lastRearmNs != 0 &&
        input->nowNs - input->lastRearmNs < limits->cooldownNs)
        return MacVNCCaptureAlive;

    if (input->rearmsSinceFrame >= limits->maxRearms)
        return MacVNCCaptureGiveUp;

    return MacVNCCaptureRearm;
}
