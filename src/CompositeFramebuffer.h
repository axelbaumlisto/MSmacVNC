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
