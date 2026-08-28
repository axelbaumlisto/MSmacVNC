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
    /* Absent input selects the default. Written against the constant, not a
       literal: the default is a measured choice that will move again, and a
       test that has to be edited alongside it tests the edit, not the code. */
    int fps = -1;
    assert(macVNCParseCaptureFPS(NULL, &fps) == MACVNC_CAPTURE_RATE_DEFAULTED);
    assert(fps == MACVNC_CAPTURE_FPS_DEFAULT);
    fps = -1;
    assert(macVNCParseCaptureFPS("", &fps) == MACVNC_CAPTURE_RATE_DEFAULTED);
    assert(fps == MACVNC_CAPTURE_FPS_DEFAULT);

    /* The default must be one the parser accepts and the defer helper supports:
       shipping a default outside the supported range would refuse to start. */
    int roundTrip = -1;
    char defaultText[8];
    snprintf(defaultText, sizeof(defaultText), "%d", MACVNC_CAPTURE_FPS_DEFAULT);
    assert(macVNCParseCaptureFPS(defaultText, &roundTrip) == MACVNC_CAPTURE_RATE_VALID);
    assert(roundTrip == MACVNC_CAPTURE_FPS_DEFAULT);
    assert(macVNCFramebufferDeferMilliseconds(MACVNC_CAPTURE_FPS_DEFAULT) > 0);

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

    /* A rejected value must not touch the output: callers rely on it to keep
       the fallback they pre-loaded, instead of restating it in every branch. */
    int preloaded = 42;
    assert(macVNCParseCaptureFPS("999", &preloaded) == MACVNC_CAPTURE_RATE_INVALID);
    assert(preloaded == 42);
    assert(macVNCParseCaptureFPS("abc", &preloaded) == MACVNC_CAPTURE_RATE_INVALID);
    assert(preloaded == 42);
    assert(macVNCParseCaptureFPS("-5", &preloaded) == MACVNC_CAPTURE_RATE_INVALID);
    assert(preloaded == 42);

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

    /* The ladder the settings UI offers. Tested here because a list living
       inside a UI builder cannot be, and then nothing guarantees the shipped
       default is even on it. */
    size_t ladder = macVNCCaptureRateLadderCount();
    assert(ladder == 4);
    assert(macVNCCaptureRateLadderValue(ladder) == 0);
    assert(macVNCCaptureRateLadderTitle(ladder) == NULL);

    int defaultsSeen = 0, previous = 0;
    for (size_t i = 0; i < ladder; ++i) {
        int rate = macVNCCaptureRateLadderValue(i);
        const char *title = macVNCCaptureRateLadderTitle(i);
        assert(title && *title);

        /* Every offered rate must be one the server accepts and can derive a
           defer window from: a popup must not be able to store a value that
           refuses to start. */
        int parsed = -1;
        char text[8];
        snprintf(text, sizeof(text), "%d", rate);
        assert(macVNCParseCaptureFPS(text, &parsed) == MACVNC_CAPTURE_RATE_VALID);
        assert(parsed == rate);
        assert(macVNCFramebufferDeferMilliseconds(rate) > 0);

        /* Ascending, so the popup reads as a scale rather than an unordered set. */
        assert(rate > previous);
        previous = rate;

        if (rate == MACVNC_CAPTURE_FPS_DEFAULT)
            ++defaultsSeen;
    }
    /* The shipped default must be ON the ladder - otherwise the popup shows
       "Custom" for a fresh install, which reads like a misconfiguration. */
    assert(defaultsSeen == 1);

    puts("capture rate tests passed");
    return 0;
}
