#include "CompositeFramebuffer.h"

#include <assert.h>
#include <stdbool.h>
#include <string.h>

/* Colour lives in the low three bytes of each 32-bit pixel; the fourth is
   alpha, which RFB depth-24 ignores. Comparing and copying byte-by-byte cost
   three loads and three stores per pixel and dominated every frame, so both
   loops now work on whole 32-bit pixels with alpha masked out. */
#define COLOR_MASK_32 UINT32_C(0x00FFFFFF)
#define COLOR_MASK_64 UINT64_C(0x00FFFFFF00FFFFFF)

static bool
colorsDiffer(const uint8_t *source, const uint8_t *target, int pixels)
{
    int pixel = 0;

    /* Two pixels per iteration. memcpy is the portable way to say "unaligned
       load"; every compiler we build with turns it into a single instruction. */
    for (; pixel + 2 <= pixels; pixel += 2, source += 8, target += 8) {
        uint64_t a, b;
        memcpy(&a, source, sizeof(a));
        memcpy(&b, target, sizeof(b));
        if (((a ^ b) & COLOR_MASK_64) != 0)
            return true;
    }
    for (; pixel < pixels; ++pixel, source += 4, target += 4) {
        uint32_t a, b;
        memcpy(&a, source, sizeof(a));
        memcpy(&b, target, sizeof(b));
        if (((a ^ b) & COLOR_MASK_32) != 0)
            return true;
    }
    return false;
}

static void
copyColors(uint8_t *target, const uint8_t *source, int pixels)
{
    int pixel = 0;

    for (; pixel + 2 <= pixels; pixel += 2, source += 8, target += 8) {
        uint64_t a;
        memcpy(&a, source, sizeof(a));
        a &= COLOR_MASK_64; /* zero both alpha bytes: RFB depth is 24 */
        memcpy(target, &a, sizeof(a));
    }
    for (; pixel < pixels; ++pixel, source += 4, target += 4) {
        uint32_t a;
        memcpy(&a, source, sizeof(a));
        a &= COLOR_MASK_32;
        memcpy(target, &a, sizeof(a));
    }
}

/*
 * Composite every tile in the tile-aligned band [x0,x1) x [y0,y1) of
 * display-local pixels. Shared by the full sweep and the hinted path so the
 * comparison and copy rules cannot drift between them.
 */
static size_t
compositeTileRange(uint8_t *canvas,
                   int canvasWidth,
                   const MacVNCDisplayGeometry *display,
                   const uint8_t *source,
                   size_t sourceStride,
                   int tileSize,
                   int x0, int y0, int x1, int y1,
                   MacVNCDirtyRectCallback dirtyCallback,
                   void *dirtyContext)
{
    /* The band is the caller's responsibility: clamping a hint into the frame
       is what keeps this loop from forming pointers outside the buffers or
       spinning over a rectangle that claims to be a million pixels wide. */
    assert(x0 >= 0 && y0 >= 0 && x0 <= x1 && y0 <= y1);
    assert(x1 <= display->input.pixelWidth && y1 <= display->input.pixelHeight);

    size_t changedTiles = 0;
    for (int y = y0; y < y1; y += tileSize) {
        int tileHeight = tileSize;
        if (y + tileHeight > display->input.pixelHeight)
            tileHeight = display->input.pixelHeight - y;
        for (int x = x0; x < x1; x += tileSize) {
            int tileWidth = tileSize;
            if (x + tileWidth > display->input.pixelWidth)
                tileWidth = display->input.pixelWidth - x;
            bool changed = false;
            for (int row = 0; row < tileHeight; ++row) {
                const uint8_t *src = source + (size_t)(y + row) * sourceStride + (size_t)x * 4;
                uint8_t *dst = canvas +
                    ((size_t)(display->framebufferY + y + row) * canvasWidth +
                     display->framebufferX + x) * 4;
                if (colorsDiffer(src, dst, tileWidth)) {
                    changed = true;
                    break;
                }
            }
            if (!changed)
                continue;

            for (int row = 0; row < tileHeight; ++row) {
                const uint8_t *src = source + (size_t)(y + row) * sourceStride + (size_t)x * 4;
                uint8_t *dst = canvas +
                    ((size_t)(display->framebufferY + y + row) * canvasWidth +
                     display->framebufferX + x) * 4;
                copyColors(dst, src, tileWidth);
            }
            ++changedTiles;
            if (dirtyCallback)
                dirtyCallback(dirtyContext,
                              display->framebufferX + x,
                              display->framebufferY + y,
                              tileWidth,
                              tileHeight);
        }
    }
    return changedTiles;
}

static bool
argumentsAreSane(const uint8_t *canvas,
                 int canvasWidth,
                 int canvasHeight,
                 const MacVNCDisplayGeometry *display,
                 const uint8_t *source,
                 size_t sourceStride,
                 int tileSize)
{
    return canvas && display && source && canvasWidth > 0 && canvasHeight > 0 &&
           tileSize > 0 && sourceStride >= (size_t)display->input.pixelWidth * 4 &&
           display->framebufferX >= 0 && display->framebufferY >= 0 &&
           display->framebufferX + display->input.pixelWidth <= canvasWidth &&
           display->framebufferY + display->input.pixelHeight <= canvasHeight;
}

size_t
macVNCCompositeDisplayFrame(uint8_t *canvas,
                            int canvasWidth,
                            int canvasHeight,
                            const MacVNCDisplayGeometry *display,
                            const uint8_t *source,
                            size_t sourceStride,
                            int tileSize,
                            MacVNCDirtyRectCallback dirtyCallback,
                            void *dirtyContext)
{
    if (!argumentsAreSane(canvas, canvasWidth, canvasHeight, display, source,
                          sourceStride, tileSize))
        return 0;

    return compositeTileRange(canvas, canvasWidth, display, source, sourceStride,
                              tileSize, 0, 0,
                              display->input.pixelWidth,
                              display->input.pixelHeight,
                              dirtyCallback, dirtyContext);
}

/* Round down to the tile grid; the grid is what the comparison works on. */
static int
alignDown(int value, int tileSize)
{
    if (value <= 0)
        return 0;
    return value - (value % tileSize);
}

size_t
macVNCCompositeDisplayFrameHinted(uint8_t *canvas,
                                  int canvasWidth,
                                  int canvasHeight,
                                  const MacVNCDisplayGeometry *display,
                                  const uint8_t *source,
                                  size_t sourceStride,
                                  int tileSize,
                                  const MacVNCDirtyHint *hint,
                                  MacVNCDirtyRectCallback dirtyCallback,
                                  void *dirtyContext)
{
    if (!argumentsAreSane(canvas, canvasWidth, canvasHeight, display, source,
                          sourceStride, tileSize))
        return 0;

    if (!hint || hint->count == 0 || !hint->rects)
        return macVNCCompositeDisplayFrame(canvas, canvasWidth, canvasHeight,
                                           display, source, sourceStride,
                                           tileSize, dirtyCallback, dirtyContext);

    size_t changedTiles = 0;
    for (size_t i = 0; i < hint->count; ++i) {
        const MacVNCDirtyRect *rect = &hint->rects[i];
        /* Clamp into the display: a hint is untrusted input, and a rect that
           runs past the frame would read and write outside both buffers. */
        int left = rect->x < 0 ? 0 : rect->x;
        int top = rect->y < 0 ? 0 : rect->y;
        long right = (long)rect->x + rect->width;
        long bottom = (long)rect->y + rect->height;
        if (right > display->input.pixelWidth)
            right = display->input.pixelWidth;
        if (bottom > display->input.pixelHeight)
            bottom = display->input.pixelHeight;
        if (left >= right || top >= bottom)
            continue;

        changedTiles += compositeTileRange(canvas, canvasWidth, display, source,
                                           sourceStride, tileSize,
                                           alignDown(left, tileSize),
                                           alignDown(top, tileSize),
                                           (int)right, (int)bottom,
                                           dirtyCallback, dirtyContext);
    }
    return changedTiles;
}
