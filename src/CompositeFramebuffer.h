#pragma once

#include "DisplayLayout.h"

#include <stddef.h>
#include <stdint.h>

typedef void (*MacVNCDirtyRectCallback)(void *context,
                                        int x,
                                        int y,
                                        int width,
                                        int height);

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
