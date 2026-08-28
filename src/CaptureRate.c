#include "CaptureRate.h"

#include <limits.h>

MacVNCCaptureRateParseResult
macVNCParseCaptureFPS(const char *value, int *framesPerSecond)
{
    if (!framesPerSecond)
        return MACVNC_CAPTURE_RATE_INVALID;
    if (!value || !*value) {
        *framesPerSecond = MACVNC_CAPTURE_FPS_DEFAULT;
        return MACVNC_CAPTURE_RATE_DEFAULTED;
    }

    int parsed = 0;
    for (const unsigned char *cursor = (const unsigned char *)value; *cursor; ++cursor) {
        if (*cursor < '0' || *cursor > '9')
            return MACVNC_CAPTURE_RATE_INVALID;
        int digit = *cursor - '0';
        if (parsed > (INT_MAX - digit) / 10)
            return MACVNC_CAPTURE_RATE_INVALID;
        parsed = parsed * 10 + digit;
    }
    if (parsed < MACVNC_CAPTURE_FPS_MIN || parsed > MACVNC_CAPTURE_FPS_MAX)
        return MACVNC_CAPTURE_RATE_INVALID;

    *framesPerSecond = parsed;
    return MACVNC_CAPTURE_RATE_VALID;
}

/* Coalescing window: long enough to batch one frame's tiles, short enough to
   be invisible. See the header for the measurements behind both bounds. */
#define MACVNC_DEFER_TARGET_MILLISECONDS 10

/* The window must never exceed the wait for the next frame. Rather than a
   runtime clamp - which is unreachable while the fastest supported rate leaves
   a 17 ms interval, and therefore untestable dead code - the relationship is
   enforced here: raising MACVNC_CAPTURE_FPS_MAX past 100 breaks the build
   instead of quietly making the defer the dominant delay. */
_Static_assert(1000 / MACVNC_CAPTURE_FPS_MAX >= MACVNC_DEFER_TARGET_MILLISECONDS,
               "defer window would exceed the capture interval at the maximum "
               "supported frame rate");

int
macVNCFramebufferDeferMilliseconds(int framesPerSecond)
{
    if (macVNCCaptureFrameIntervalMilliseconds(framesPerSecond) == 0)
        return 0; /* invalid rate: report it the same way its sibling does */
    return MACVNC_DEFER_TARGET_MILLISECONDS;
}

int
macVNCCaptureFrameIntervalMilliseconds(int framesPerSecond)
{
    if (framesPerSecond < MACVNC_CAPTURE_FPS_MIN ||
        framesPerSecond > MACVNC_CAPTURE_FPS_MAX)
        return 0;
    return (1000 + framesPerSecond - 1) / framesPerSecond;
}
