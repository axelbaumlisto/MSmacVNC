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

/*
 * How long the server holds a framebuffer update before sending it, so the
 * tiles of one captured frame travel together.
 *
 * This used to BE the capture interval, which stacked two delays: 83 ms
 * waiting for a frame at 12 FPS, then 84 ms holding it. Measured, that pairing
 * delivered 8.1 frames per second with a 125 ms average gap; the same capture
 * rate with a 10 ms window delivers 24.4 with a 41 ms gap, and the worst case
 * halves (174 -> 86 ms).
 *
 * The window is small but never zero: at zero, updates stop coalescing and the
 * tail collapses - measured p99 of 1.4 s and a 2.1 s stall, with double the
 * CPU. It is also clamped to the capture interval, because holding an update
 * longer than the wait for the next frame can only add latency (at 60 FPS the
 * interval is 17 ms).
 *
 * Returns zero when framesPerSecond is outside the supported range.
 */
int macVNCFramebufferDeferMilliseconds(int framesPerSecond);
