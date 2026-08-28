#include "CaptureRate.h"

#include <assert.h>
#include <stdio.h>

static void expect_valid(const char *value, int expected)
{
    int fps = -1;
    assert(macVNCParseCaptureFPS(value, &fps) == MACVNC_CAPTURE_RATE_VALID);
    assert(fps == expected);
}

static void expect_invalid(const char *value)
{
    int fps = 37;
    assert(macVNCParseCaptureFPS(value, &fps) == MACVNC_CAPTURE_RATE_INVALID);
    assert(fps == 37);
}

int main(void)
{
    int fps = -1;
    assert(macVNCParseCaptureFPS(NULL, &fps) == MACVNC_CAPTURE_RATE_DEFAULTED);
    assert(fps == 12);
    fps = -1;
    assert(macVNCParseCaptureFPS("", &fps) == MACVNC_CAPTURE_RATE_DEFAULTED);
    assert(fps == 12);

    expect_valid("1", 1);
    expect_valid("12", 12);
    expect_valid("20", 20);
    expect_valid("30", 30);
    expect_valid("60", 60);

    expect_invalid("0");
    expect_invalid("61");
    expect_invalid("-1");
    expect_invalid("+20");
    expect_invalid(" 20");
    expect_invalid("20 ");
    expect_invalid("20.0");
    expect_invalid("NaN");
    expect_invalid("1e1");
    expect_invalid("999999999999999999999999999999999");
    assert(macVNCParseCaptureFPS("20", NULL) == MACVNC_CAPTURE_RATE_INVALID);

    assert(macVNCCaptureFrameIntervalMilliseconds(0) == 0);
    assert(macVNCCaptureFrameIntervalMilliseconds(1) == 1000);
    assert(macVNCCaptureFrameIntervalMilliseconds(12) == 84);
    assert(macVNCCaptureFrameIntervalMilliseconds(20) == 50);
    assert(macVNCCaptureFrameIntervalMilliseconds(30) == 34);
    assert(macVNCCaptureFrameIntervalMilliseconds(60) == 17);
    assert(macVNCCaptureFrameIntervalMilliseconds(61) == 0);

    /* The defer is a SEPARATE decision from the capture interval. Deriving it
       from the rate stacked two delays and cost 3x the delivered frame rate. */
    assert(macVNCFramebufferDeferMilliseconds(12) == 10);
    assert(macVNCFramebufferDeferMilliseconds(30) == 10);
    assert(macVNCFramebufferDeferMilliseconds(1) == 10);

    /* Never longer than the wait for the next frame: holding an update past
       that can only add latency. At 120 FPS the interval would be 9 ms - but
       the supported maximum is 60, where the interval is 17 ms. */
    assert(macVNCFramebufferDeferMilliseconds(60) == 10);
    assert(macVNCFramebufferDeferMilliseconds(60) <=
           macVNCCaptureFrameIntervalMilliseconds(60));

    /* Never zero for a valid rate: at zero, updates stop coalescing and the
       tail collapses (measured p99 1.4 s, max 2.1 s, double the CPU). */
    for (int fps = MACVNC_CAPTURE_FPS_MIN; fps <= MACVNC_CAPTURE_FPS_MAX; ++fps) {
        assert(macVNCFramebufferDeferMilliseconds(fps) > 0);
        assert(macVNCFramebufferDeferMilliseconds(fps) <=
               macVNCCaptureFrameIntervalMilliseconds(fps));
    }

    /* Invalid rates report zero, exactly like the interval helper. */
    assert(macVNCFramebufferDeferMilliseconds(0) == 0);
    assert(macVNCFramebufferDeferMilliseconds(61) == 0);
    assert(macVNCFramebufferDeferMilliseconds(-1) == 0);

    puts("capture rate tests passed");
    return 0;
}
