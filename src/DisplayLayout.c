#include "DisplayLayout.h"

#include <math.h>
#include <string.h>

/* One axis of a placed display, named so compactAxis() can do its work once
   instead of twice. `horizontal` selects X/width, otherwise Y/height. */
static int axisOrigin(const MacVNCDisplayGeometry *geometry, bool horizontal)
{
    return horizontal ? geometry->framebufferX : geometry->framebufferY;
}

static int axisSize(const MacVNCDisplayGeometry *geometry, bool horizontal)
{
    return horizontal ? geometry->input.pixelWidth : geometry->input.pixelHeight;
}

static void setAxisOrigin(MacVNCDisplayGeometry *geometry, bool horizontal, int origin)
{
    if (horizontal)
        geometry->framebufferX = origin;
    else
        geometry->framebufferY = origin;
}

/*
 * How many pixels one display puts behind one point, taking the larger of the
 * two axes: a Retina panel reports 2, a 1:1 external 1. Non-integer answers
 * (a scaled HiDPI mode) are legal and need no special case - only the ratio
 * matters below.
 */
static double displayScale(const MacVNCDisplayInput *input)
{
    double byWidth = (double)input->pixelWidth / input->logicalWidth;
    double byHeight = (double)input->pixelHeight / input->logicalHeight;
    return byWidth > byHeight ? byWidth : byHeight;
}

/*
 * Squeeze out the rows (or columns) no display occupies at all.
 *
 * Scaling the origins of a mixed-DPI desk opens bands of canvas that belong to
 * nobody: a 1x display is placed at a 2x distance from its neighbour while
 * keeping its own 1x size, so the difference is pure black. On the desk this
 * was measured against that cost 1046 wasted rows - a canvas 40% filled, which
 * every client then has to allocate, scale and scroll around.
 *
 * Only bands empty across the WHOLE axis are removed, and every display beyond
 * one is shifted by exactly its length, so:
 *   - relative order is preserved on both axes (who is left of / above whom);
 *   - two rectangles separated ONLY by a removed band end up edge-to-edge,
 *     never overlapping, because the shift equals the separation;
 *   - a separation that any third display spans is not a band at all, so it
 *     survives untouched.
 * A desk with no empty band - every uniform-DPI desk - is left exactly as it
 * was. The overlap check at the end of the build still runs over the result:
 * this reasoning is the intent, that check is the proof.
 */
static void compactAxis(MacVNCDisplayLayout *layout, bool horizontal)
{
    size_t order[MACVNC_MAX_DISPLAYS];
    for (size_t i = 0; i < layout->count; ++i)
        order[i] = i;

    /* Insertion sort by origin: MACVNC_MAX_DISPLAYS is 16, and a sort this
       small is cheaper to read than to optimise. */
    for (size_t i = 1; i < layout->count; ++i) {
        size_t key = order[i];
        int keyOrigin = axisOrigin(&layout->displays[key], horizontal);
        size_t j = i;
        while (j > 0 && axisOrigin(&layout->displays[order[j - 1]], horizontal) > keyOrigin) {
            order[j] = order[j - 1];
            --j;
        }
        order[j] = key;
    }

    int reached = 0;    /* furthest edge any earlier display covers */
    int removed = 0;    /* total empty length squeezed out so far */
    for (size_t i = 0; i < layout->count; ++i) {
        MacVNCDisplayGeometry *geometry = &layout->displays[order[i]];
        int origin = axisOrigin(geometry, horizontal);
        if (origin > reached)
            removed += origin - reached;
        int end = origin + axisSize(geometry, horizontal);
        if (end > reached)
            reached = end;
        setAxisOrigin(geometry, horizontal, origin - removed);
    }
}

static bool rectanglesOverlap(const MacVNCDisplayGeometry *a,
                              const MacVNCDisplayGeometry *b)
{
    return a->framebufferX < b->framebufferX + b->input.pixelWidth &&
           b->framebufferX < a->framebufferX + a->input.pixelWidth &&
           a->framebufferY < b->framebufferY + b->input.pixelHeight &&
           b->framebufferY < a->framebufferY + a->input.pixelHeight;
}

bool
macVNCBuildDisplayLayout(const MacVNCDisplayInput *inputs,
                         size_t count,
                         MacVNCDisplayLayout *layout)
{
    if (!inputs || !layout || count == 0 || count > MACVNC_MAX_DISPLAYS)
        return false;

    memset(layout, 0, sizeof(*layout));
    layout->count = count;
    layout->logicalMinX = inputs[0].logicalX;
    layout->logicalMinY = inputs[0].logicalY;
    /*
     * The canvas is the desk IN PIXELS, and a mixed-DPI desk has no single
     * pixel grid - so it is laid out at the highest scale present: origins are
     * scaled by `canvasScale`, sizes stay each display's own native pixels.
     *
     * Consequences, both deliberate:
     *   - every display contributes every pixel it really has (the point-grid
     *     layout this replaced forced a 2x panel to be captured at its POINT
     *     size, which threw away three quarters of its pixels);
     *   - a display coarser than the desk's finest lands further away than it
     *     is wide, because only the ORIGINS scale. The empty bands that opens
     *     are then removed by compactAxis() below - see its comment.
     * A uniform desk - every display at the same scale, which is every
     * single-display desk - has scale == canvasScale everywhere, so nothing
     * moves and the layout is identical to the one before this rule.
     */
    double canvasScale = 0;
    for (size_t i = 0; i < count; ++i) {
        if (inputs[i].logicalWidth <= 0 || inputs[i].logicalHeight <= 0 ||
            inputs[i].pixelWidth <= 0 || inputs[i].pixelHeight <= 0)
            return false;
        if (inputs[i].logicalX < layout->logicalMinX)
            layout->logicalMinX = inputs[i].logicalX;
        if (inputs[i].logicalY < layout->logicalMinY)
            layout->logicalMinY = inputs[i].logicalY;
        double scale = displayScale(&inputs[i]);
        if (scale > canvasScale)
            canvasScale = scale;
    }

    for (size_t i = 0; i < count; ++i) {
        MacVNCDisplayGeometry *geometry = &layout->displays[i];
        geometry->input = inputs[i];
        geometry->framebufferX =
            (int)llround((inputs[i].logicalX - layout->logicalMinX) * canvasScale);
        geometry->framebufferY =
            (int)llround((inputs[i].logicalY - layout->logicalMinY) * canvasScale);
    }

    compactAxis(layout, true);
    compactAxis(layout, false);

    for (size_t i = 0; i < count; ++i) {
        int right = layout->displays[i].framebufferX + inputs[i].pixelWidth;
        int bottom = layout->displays[i].framebufferY + inputs[i].pixelHeight;
        if (right > layout->width) layout->width = right;
        if (bottom > layout->height) layout->height = bottom;
    }

    /* Some VNC viewers require a framebuffer width divisible by four. */
    layout->width = (layout->width + 3) & ~3;

    if (layout->width <= 0 || layout->height <= 0 ||
        layout->width > UINT16_MAX || layout->height > UINT16_MAX)
        return false;

    for (size_t i = 0; i < count; ++i)
        for (size_t j = i + 1; j < count; ++j)
            if (rectanglesOverlap(&layout->displays[i], &layout->displays[j]))
                return false;

    return true;
}

bool
macVNCMapFramebufferPoint(const MacVNCDisplayLayout *layout,
                          int framebufferX,
                          int framebufferY,
                          double *globalX,
                          double *globalY,
                          uint32_t *displayID)
{
    if (!layout || framebufferX < 0 || framebufferY < 0 ||
        framebufferX >= layout->width || framebufferY >= layout->height)
        return false;

    for (size_t i = 0; i < layout->count; ++i) {
        const MacVNCDisplayGeometry *geometry = &layout->displays[i];
        int localX = framebufferX - geometry->framebufferX;
        int localY = framebufferY - geometry->framebufferY;
        if (localX < 0 || localY < 0 ||
            localX >= geometry->input.pixelWidth ||
            localY >= geometry->input.pixelHeight)
            continue;
        if (globalX)
            *globalX = geometry->input.logicalX +
                ((double)localX * geometry->input.logicalWidth / geometry->input.pixelWidth);
        if (globalY)
            *globalY = geometry->input.logicalY +
                ((double)localY * geometry->input.logicalHeight / geometry->input.pixelHeight);
        if (displayID)
            *displayID = geometry->input.displayID;
        return true;
    }
    return false; /* black gap between physical displays */
}

/* See the header: a landmine-avoidance margin, not evidence of expected
   drift - two reads of an unchanged desk return bit-identical doubles. */
#define MACVNC_DISPLAY_LAYOUT_EPSILON 0.5

static bool
sameLogicalValue(double a, double b)
{
    return fabs(a - b) < MACVNC_DISPLAY_LAYOUT_EPSILON;
}

bool
macVNCDisplayLayoutsEqual(const MacVNCDisplayLayout *a, const MacVNCDisplayLayout *b)
{
    if (!a || !b)
        return a == b; /* both NULL: vacuously equal; exactly one: never */
    if (a->count != b->count || a->width != b->width || a->height != b->height)
        return false;

    for (size_t i = 0; i < a->count; ++i) {
        const MacVNCDisplayGeometry *ga = &a->displays[i];
        const MacVNCDisplayGeometry *gb = &b->displays[i];
        if (ga->input.displayID != gb->input.displayID)
            return false;
        if (!sameLogicalValue(ga->input.logicalX, gb->input.logicalX) ||
            !sameLogicalValue(ga->input.logicalY, gb->input.logicalY) ||
            !sameLogicalValue(ga->input.logicalWidth, gb->input.logicalWidth) ||
            !sameLogicalValue(ga->input.logicalHeight, gb->input.logicalHeight))
            return false;
        if (ga->input.pixelWidth != gb->input.pixelWidth ||
            ga->input.pixelHeight != gb->input.pixelHeight)
            return false;
        /* Derived by macVNCBuildDisplayLayout from the logical rect above, but
           compared explicitly anyway: a hand-built MacVNCDisplayLayout (as in
           a re-arm's before/after snapshots, or a test) could otherwise have a
           stale or mismatched origin survive undetected. */
        if (ga->framebufferX != gb->framebufferX ||
            ga->framebufferY != gb->framebufferY)
            return false;
    }
    return true;
}
