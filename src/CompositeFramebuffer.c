#include "CompositeFramebuffer.h"

#include <stdbool.h>

static bool
colorsDiffer(const uint8_t *source, const uint8_t *target, int pixels)
{
    for (int pixel = 0; pixel < pixels; ++pixel, source += 4, target += 4)
        if (source[0] != target[0] || source[1] != target[1] || source[2] != target[2])
            return true;
    return false;
}

static void
copyColors(uint8_t *target, const uint8_t *source, int pixels)
{
    for (int pixel = 0; pixel < pixels; ++pixel, source += 4, target += 4) {
        target[0] = source[0];
        target[1] = source[1];
        target[2] = source[2];
        target[3] = 0; /* RFB depth is 24; keep the unused byte deterministic. */
    }
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
    if (!canvas || !display || !source || canvasWidth <= 0 || canvasHeight <= 0 ||
        tileSize <= 0 || sourceStride < (size_t)display->input.pixelWidth * 4 ||
        display->framebufferX < 0 || display->framebufferY < 0 ||
        display->framebufferX + display->input.pixelWidth > canvasWidth ||
        display->framebufferY + display->input.pixelHeight > canvasHeight)
        return 0;

    size_t changedTiles = 0;
    for (int y = 0; y < display->input.pixelHeight; y += tileSize) {
        int tileHeight = tileSize;
        if (y + tileHeight > display->input.pixelHeight)
            tileHeight = display->input.pixelHeight - y;
        for (int x = 0; x < display->input.pixelWidth; x += tileSize) {
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
