#pragma once

#include <stddef.h>

/*
 * Measured default. 12 FPS was chosen when compositing a frame cost 44 ms of
 * CPU; it costs 3 ms now. With the 10 ms defer window, 30 FPS delivers 33.4
 * frames per second to a viewer at a 30 ms average gap and a 53 ms p99, for
 * CPU comparable to the PRE-optimisation server - while 60 FPS delivers no
 * more frames and has worse tails. The Preferences popup is the way down for
 * a slow link or a battery.
 */
#define MACVNC_CAPTURE_FPS_DEFAULT 30
#define MACVNC_CAPTURE_FPS_MIN 1
#define MACVNC_CAPTURE_FPS_MAX 60

typedef enum {
    MACVNC_CAPTURE_RATE_DEFAULTED = 0,
    MACVNC_CAPTURE_RATE_VALID = 1,
    MACVNC_CAPTURE_RATE_INVALID = 2,
} MacVNCCaptureRateParseResult;

/* Empty or unset input selects the default. Non-empty input must consist only
   of decimal digits and be in the inclusive supported range. */
/* On MACVNC_CAPTURE_RATE_INVALID the output is left UNTOUCHED, so a caller can
   pre-load its fallback and let a rejected value simply not overwrite it. */
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

/*
 * The rates the settings UI offers, in ascending order.
 *
 * Here rather than in the Preferences file for the same reason the image
 * ladder moved into MacVNCImageProfile: a list that only exists inside a UI
 * builder cannot be tested, and nothing then guarantees that the rate we SHIP
 * as the default is even on it - changing the default would silently downgrade
 * the popup to "Custom - N fps" instead of failing.
 *
 * Measured on a two-display Mac: 8 delivers ~16 frames per second to a viewer,
 * 15 delivers ~24, 30 delivers ~33 at a 30 ms average gap, and 60 delivers no
 * more than 30 with worse worst-cases because the limit is encode and transfer.
 */
size_t macVNCCaptureRateLadderCount(void);
int macVNCCaptureRateLadderValue(size_t index);
const char *macVNCCaptureRateLadderTitle(size_t index);
