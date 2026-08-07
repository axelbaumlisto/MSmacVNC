#include "DisplayLayout.h"

#include <assert.h>
#include <math.h>

static int near(double a, double b) { return fabs(a - b) < 0.001; }

int main(void)
{
    MacVNCDisplayInput current[] = {
        {1, 0, 0, 3840, 2160, 3840, 2160},
        {2, -1710, 1603, 1710, 1112, 1710, 1112},
    };
    MacVNCDisplayLayout layout;
    assert(macVNCBuildDisplayLayout(current, 2, &layout));
    assert(layout.width == 5550);
    assert(layout.height == 2715);
    assert(layout.displays[0].framebufferX == 1710);
    assert(layout.displays[0].framebufferY == 0);
    assert(layout.displays[1].framebufferX == 0);
    assert(layout.displays[1].framebufferY == 1603);

    double gx, gy; uint32_t id;
    assert(macVNCMapFramebufferPoint(&layout, 1810, 100, &gx, &gy, &id));
    assert(id == 1 && near(gx, 100) && near(gy, 100));
    assert(macVNCMapFramebufferPoint(&layout, 100, 1703, &gx, &gy, &id));
    assert(id == 2 && near(gx, -1610) && near(gy, 1703));
    assert(!macVNCMapFramebufferPoint(&layout, 100, 100, &gx, &gy, &id));
    assert(!macVNCMapFramebufferPoint(&layout, 5000, 2500, &gx, &gy, &id));

    /* Half-open seam belongs to the external display, not the internal one. */
    assert(macVNCMapFramebufferPoint(&layout, 1710, 1603, &gx, &gy, &id));
    assert(id == 1);

    MacVNCDisplayInput reversed[] = { current[1], current[0] };
    MacVNCDisplayLayout reversedLayout;
    assert(macVNCBuildDisplayLayout(reversed, 2, &reversedLayout));
    assert(reversedLayout.width == layout.width && reversedLayout.height == layout.height);

    MacVNCDisplayInput overlapping[] = {
        {1, 0, 0, 100, 100, 100, 100},
        {2, 50, 50, 100, 100, 100, 100},
    };
    assert(!macVNCBuildDisplayLayout(overlapping, 2, &layout));

    /* Native-pixel rectangles overlap after logical normalization: reject safely. */
    MacVNCDisplayInput mixedScale[] = {
        {1, 0, 0, 100, 100, 200, 200},
        {2, 100, 0, 100, 100, 100, 100},
    };
    assert(!macVNCBuildDisplayLayout(mixedScale, 2, &layout));

    MacVNCDisplayInput tooLarge[] = {{1, 0, 0, 70000, 100, 70000, 100}};
    assert(!macVNCBuildDisplayLayout(tooLarge, 1, &layout));
    return 0;
}
