#include "DisplayLayout.h"

#include <math.h>
#include <string.h>

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
    for (size_t i = 0; i < count; ++i) {
        if (inputs[i].logicalWidth <= 0 || inputs[i].logicalHeight <= 0 ||
            inputs[i].pixelWidth <= 0 || inputs[i].pixelHeight <= 0)
            return false;
        if (inputs[i].logicalX < layout->logicalMinX)
            layout->logicalMinX = inputs[i].logicalX;
        if (inputs[i].logicalY < layout->logicalMinY)
            layout->logicalMinY = inputs[i].logicalY;
    }

    for (size_t i = 0; i < count; ++i) {
        MacVNCDisplayGeometry *geometry = &layout->displays[i];
        geometry->input = inputs[i];
        geometry->framebufferX = (int)llround(inputs[i].logicalX - layout->logicalMinX);
        geometry->framebufferY = (int)llround(inputs[i].logicalY - layout->logicalMinY);
        int right = geometry->framebufferX + inputs[i].pixelWidth;
        int bottom = geometry->framebufferY + inputs[i].pixelHeight;
        if (right > layout->width) layout->width = right;
        if (bottom > layout->height) layout->height = bottom;
    }

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
