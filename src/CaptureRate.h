#pragma once

#define MACVNC_CAPTURE_FPS_DEFAULT 12
#define MACVNC_CAPTURE_FPS_MIN 1
#define MACVNC_CAPTURE_FPS_MAX 60

typedef enum {
    MACVNC_CAPTURE_RATE_DEFAULTED = 0,
    MACVNC_CAPTURE_RATE_VALID = 1,
    MACVNC_CAPTURE_RATE_INVALID = 2,
} MacVNCCaptureRateParseResult;

/* Empty or unset input selects the default. Non-empty input must consist only
   of decimal digits and be in the inclusive supported range. */
MacVNCCaptureRateParseResult macVNCParseCaptureFPS(const char *value, int *framesPerSecond);

/* Convert a validated FPS to a millisecond interval without exceeding that
   rate. Returns zero when framesPerSecond is outside the supported range. */
int macVNCCaptureFrameIntervalMilliseconds(int framesPerSecond);
