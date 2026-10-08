#include "DisplayLayout.h"

#include <assert.h>
#include <math.h>
#include <string.h>

static int near(double a, double b) { return fabs(a - b) < 0.001; }

int main(void)
{
    MacVNCDisplayInput current[] = {
        {1, 0, 0, 3840, 2160, 3840, 2160},
        {2, -1710, 1603, 1710, 1112, 1710, 1112},
    };
    MacVNCDisplayLayout layout;
    assert(macVNCBuildDisplayLayout(current, 2, &layout));
    assert(layout.width == 5552);
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

    /* MIXED DPI. A Retina panel delivers twice as many pixels as it occupies
       points, so the canvas cannot be a point grid: it is the desk in pixels
       at the HIGHEST scale present. Origins scale by that factor, sizes stay
       native - so a 1x display sits in a 2x-sized slot and the remainder is
       black, which is the only arrangement-preserving way to hold both. */
    MacVNCDisplayInput mixedScale[] = {
        {1, 0, 0, 100, 100, 200, 200},   /* 2x */
        {2, 100, 0, 100, 100, 100, 100}, /* 1x, to its right */
    };
    MacVNCDisplayLayout mixedLayout;
    assert(macVNCBuildDisplayLayout(mixedScale, 2, &mixedLayout));
    assert(mixedLayout.displays[0].framebufferX == 0);
    assert(mixedLayout.displays[0].framebufferY == 0);
    assert(mixedLayout.displays[1].framebufferX == 200); /* 100 points x 2 */
    assert(mixedLayout.displays[1].framebufferY == 0);
    assert(mixedLayout.width == 300); /* 200 + its own 100 native pixels */
    assert(mixedLayout.height == 200);

    /* The real desk this was found on: a 1x 4K external at the origin and a 2x
       built-in Retina panel below-left. Before the fix the built-in was
       described - and therefore captured - at its POINT size, so half of its
       real pixels never reached the wire. */
    MacVNCDisplayInput retinaDesk[] = {
        {1, 0, 0, 3840, 2160, 3840, 2160},
        {2, -1710, 1603, 1710, 1112, 3420, 2224},
    };
    MacVNCDisplayLayout retinaLayout;
    assert(macVNCBuildDisplayLayout(retinaDesk, 2, &retinaLayout));
    assert(retinaLayout.displays[0].framebufferX == 3420); /* 1710 points x 2 */
    assert(retinaLayout.displays[0].framebufferY == 0);
    assert(retinaLayout.displays[1].framebufferX == 0);
    /* 1603 points x 2 = 3206, minus the 1046 empty rows between the external's
       bottom edge (2160, unscaled because it is a 1x panel) and that origin. */
    assert(retinaLayout.displays[1].framebufferY == 2160);
    assert(retinaLayout.width == 7260);
    assert(retinaLayout.height == 4384);

    /* Pointer mapping is per-rectangle, so it keeps working across the scale
       change: a canvas pixel on the 2x panel still lands on the right POINT. */
    assert(macVNCMapFramebufferPoint(&retinaLayout, 3520, 100, &gx, &gy, &id));
    assert(id == 1 && near(gx, 100) && near(gy, 100));
    assert(macVNCMapFramebufferPoint(&retinaLayout, 200, 2360, &gx, &gy, &id));
    assert(id == 2 && near(gx, -1610) && near(gy, 1703));

    /* Empty bands are squeezed out on BOTH axes, and only bands nobody
       occupies: the desk below has a 2x panel at the origin and a 1x panel
       diagonally beyond it, so both a column band and a row band disappear and
       the two end up corner to corner. */
    MacVNCDisplayInput diagonal[] = {
        {1, 0, 0, 100, 100, 200, 200},     /* 2x: 200x200 px at (0,0) */
        {2, 200, 200, 100, 100, 100, 100}, /* 1x: scaled origin (400,400) */
    };
    MacVNCDisplayLayout diagonalLayout;
    assert(macVNCBuildDisplayLayout(diagonal, 2, &diagonalLayout));
    assert(diagonalLayout.displays[1].framebufferX == 200);
    assert(diagonalLayout.displays[1].framebufferY == 200);
    assert(diagonalLayout.width == 300);
    assert(diagonalLayout.height == 300);

    /* A band a THIRD display spans is not empty, so it must survive: the 1x
       panel below stays where its scaled origin put it, because the tall 2x
       panel covers those columns. */
    MacVNCDisplayInput spanned[] = {
        {1, 0, 0, 100, 100, 200, 200},     /* 2x at (0,0), 200x200 */
        {2, 100, 0, 50, 50, 50, 50},       /* 1x at (200,0), 50x50 */
        {3, 100, 50, 100, 100, 100, 100},  /* 1x at (200,100), spans to x=300 */
    };
    MacVNCDisplayLayout spannedLayout;
    assert(macVNCBuildDisplayLayout(spanned, 3, &spannedLayout));
    assert(spannedLayout.displays[1].framebufferX == 200);
    assert(spannedLayout.displays[1].framebufferY == 0);
    assert(spannedLayout.displays[2].framebufferX == 200);
    assert(spannedLayout.displays[2].framebufferY == 100);
    assert(spannedLayout.width == 300);
    assert(spannedLayout.height == 200);

    /* Scaling origins cannot rescue a desk whose POINT rectangles already
       overlap - CoreGraphics never reports one, and a silent accept here
       would composite two displays onto the same canvas pixels. */
    MacVNCDisplayInput mixedOverlapping[] = {
        {1, 0, 0, 100, 100, 200, 200},
        {2, 50, 0, 100, 100, 100, 100},
    };
    assert(!macVNCBuildDisplayLayout(mixedOverlapping, 2, &layout));

    MacVNCDisplayInput tooLarge[] = {{1, 0, 0, 70000, 100, 70000, 100}};
    assert(!macVNCBuildDisplayLayout(tooLarge, 1, &layout));

    /* --- macVNCDisplayLayoutsEqual --- */

    MacVNCDisplayLayout twoA, twoB;
    assert(macVNCBuildDisplayLayout(current, 2, &twoA));
    assert(macVNCBuildDisplayLayout(current, 2, &twoB));
    assert(macVNCDisplayLayoutsEqual(&twoA, &twoB));
    assert(macVNCDisplayLayoutsEqual(&twoB, &twoA));

    /* Reordered desk, identical geometry: positional comparison, NOT set
       equality - see the header for why a reorder must count as a change. */
    MacVNCDisplayLayout reorderedTwo;
    assert(macVNCBuildDisplayLayout(reversed, 2, &reorderedTwo));
    assert(!macVNCDisplayLayoutsEqual(&twoA, &reorderedTwo));

    /* One display resized (logical AND pixel). */
    MacVNCDisplayInput resized[] = {
        {1, 0, 0, 3840, 2160, 3840, 2160},
        {2, -1710, 1603, 1200, 800, 1200, 800},
    };
    MacVNCDisplayLayout resizedLayout;
    assert(macVNCBuildDisplayLayout(resized, 2, &resizedLayout));
    assert(!macVNCDisplayLayoutsEqual(&twoA, &resizedLayout));

    /* One display moved (logical origin only, same size). */
    MacVNCDisplayInput moved[] = {
        {1, 0, 0, 3840, 2160, 3840, 2160},
        {2, -1710, 1000, 1710, 1112, 1710, 1112},
    };
    MacVNCDisplayLayout movedLayout;
    assert(macVNCBuildDisplayLayout(moved, 2, &movedLayout));
    assert(!macVNCDisplayLayoutsEqual(&twoA, &movedLayout));

    /* Count differs. */
    MacVNCDisplayLayout oneOnly;
    assert(macVNCBuildDisplayLayout(current, 1, &oneOnly));
    assert(!macVNCDisplayLayoutsEqual(&twoA, &oneOnly));

    /* Both empty (no displays built at all - the zeroed struct): vacuously
       equal, nothing to compare and no canvas mismatch either. */
    MacVNCDisplayLayout emptyA, emptyB;
    memset(&emptyA, 0, sizeof(emptyA));
    memset(&emptyB, 0, sizeof(emptyB));
    assert(macVNCDisplayLayoutsEqual(&emptyA, &emptyB));

    /* Canvas size differs while every display entry is identical: a
       hand-built pair (never producible by macVNCBuildDisplayLayout itself)
       that only a WIDTH/HEIGHT check, not a per-display scan, can catch. */
    MacVNCDisplayLayout widerCanvas = twoA;
    widerCanvas.width += 4;
    assert(!macVNCDisplayLayoutsEqual(&twoA, &widerCanvas));

    /* NULL handling: both NULL is vacuously equal, exactly one is never. */
    assert(macVNCDisplayLayoutsEqual(NULL, NULL));
    assert(!macVNCDisplayLayoutsEqual(&twoA, NULL));
    assert(!macVNCDisplayLayoutsEqual(NULL, &twoA));

    return 0;
}
