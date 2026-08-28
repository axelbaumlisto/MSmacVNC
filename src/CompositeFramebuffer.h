#pragma once

#include "DisplayLayout.h"

#include <stddef.h>
#include <stdint.h>

typedef void (*MacVNCDirtyRectCallback)(void *context,
                                        int x,
                                        int y,
                                        int width,
                                        int height);

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

/** Copy changed BGRA tiles from one display frame into the composite canvas. */
size_t macVNCCompositeDisplayFrame(uint8_t *canvas,
                                   int canvasWidth,
                                   int canvasHeight,
                                   const MacVNCDisplayGeometry *display,
                                   const uint8_t *source,
                                   size_t sourceStride,
                                   int tileSize,
                                   MacVNCDirtyRectCallback dirtyCallback,
                                   void *dirtyContext);

/*
 * As above, but only examines tiles overlapping `hint`.
 *
 * Every tile it does examine is still compared before being copied, so a hint
 * that over-reports costs nothing but a scan, and overlapping rectangles are
 * harmless: the second visit finds the tile already identical.
 */
size_t macVNCCompositeDisplayFrameHinted(uint8_t *canvas,
                                         int canvasWidth,
                                         int canvasHeight,
                                         const MacVNCDisplayGeometry *display,
                                         const uint8_t *source,
                                         size_t sourceStride,
                                         int tileSize,
                                         const MacVNCDirtyHint *hint,
                                         MacVNCDirtyRectCallback dirtyCallback,
                                         void *dirtyContext);
