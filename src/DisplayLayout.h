#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define MACVNC_MAX_DISPLAYS 16

typedef struct {
    uint32_t displayID;
    double logicalX;
    double logicalY;
    double logicalWidth;
    double logicalHeight;
    int pixelWidth;
    int pixelHeight;
} MacVNCDisplayInput;

typedef struct {
    MacVNCDisplayInput input;
    int framebufferX;
    int framebufferY;
} MacVNCDisplayGeometry;

typedef struct {
    size_t count;
    int width;
    int height;
    double logicalMinX;
    double logicalMinY;
    MacVNCDisplayGeometry displays[MACVNC_MAX_DISPLAYS];
} MacVNCDisplayLayout;

/** A rectangle in DISPLAY-LOCAL pixels (not canvas coordinates). */
typedef struct {
    int x;
    int y;
    int width;
    int height;
} MacVNCDirtyRect;

/*
 * Where a frame changed, as reported by the capture source.
 *
 * ScreenCaptureKit already knows which rectangles it repainted, and comparing
 * the untouched 99% of a 29 MB frame against the canvas is the single most
 * expensive thing this server does per frame. `count == 0` means "no usable
 * hint" and asks for a full sweep - which the caller must also request
 * periodically, so a hint that ever under-reports cannot leave a region of
 * the canvas permanently stale.
 */
typedef struct {
    const MacVNCDirtyRect *rects;
    size_t count;
} MacVNCDirtyHint;

bool macVNCBuildDisplayLayout(const MacVNCDisplayInput *inputs,
                              size_t count,
                              MacVNCDisplayLayout *layout);

bool macVNCMapFramebufferPoint(const MacVNCDisplayLayout *layout,
                               int framebufferX,
                               int framebufferY,
                               double *globalX,
                               double *globalY,
                               uint32_t *displayID);
