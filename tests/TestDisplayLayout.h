#pragma once

/*
 * Shared setup for tests that need a real capture target.
 *
 * Two capture tests had grown their own copy of "find the first active display
 * and describe it as a one-display layout", and they had drifted: one asserted
 * where the other skipped. Any test that touches ScreenCaptureKit needs this,
 * so it lives in one place with one behaviour.
 */

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

#include "DisplayLayout.h"

/*
 * Describe the first active display as a single-display layout.
 *
 * Returns false when there is no usable display, which every caller must
 * treat as SKIP (exit 77) rather than failure: a machine with no attached
 * display cannot exercise capture, and that is not a defect in the code.
 */
static inline bool
testBuildSingleDisplayLayout(MacVNCDisplayLayout *layout)
{
    CGDirectDisplayID displays[8];
    CGDisplayCount displayCount = 0;
    if (CGGetActiveDisplayList(8, displays, &displayCount) != kCGErrorSuccess ||
        displayCount == 0)
        return false;

    MacVNCDisplayInput input = { .displayID = displays[0] };
    input.logicalWidth = (double)CGDisplayPixelsWide(displays[0]);
    input.logicalHeight = (double)CGDisplayPixelsHigh(displays[0]);
    input.pixelWidth = (int)CGDisplayPixelsWide(displays[0]);
    input.pixelHeight = (int)CGDisplayPixelsHigh(displays[0]);

    return macVNCBuildDisplayLayout(&input, 1, layout);
}
