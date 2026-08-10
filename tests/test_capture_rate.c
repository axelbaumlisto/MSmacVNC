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

    puts("capture rate tests passed");
    return 0;
}
