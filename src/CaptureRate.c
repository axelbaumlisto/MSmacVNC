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

int
macVNCCaptureFrameIntervalMilliseconds(int framesPerSecond)
{
    if (framesPerSecond < MACVNC_CAPTURE_FPS_MIN ||
        framesPerSecond > MACVNC_CAPTURE_FPS_MAX)
        return 0;
    return (1000 + framesPerSecond - 1) / framesPerSecond;
}
