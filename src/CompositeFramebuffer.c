#include "CompositeFramebuffer.h"

#include <stdbool.h>
#include <string.h>

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
            size_t rowBytes = (size_t)tileWidth * 4;
            bool changed = false;
            for (int row = 0; row < tileHeight; ++row) {
                const uint8_t *src = source + (size_t)(y + row) * sourceStride + (size_t)x * 4;
                uint8_t *dst = canvas +
                    ((size_t)(display->framebufferY + y + row) * canvasWidth +
                     display->framebufferX + x) * 4;
                if (memcmp(src, dst, rowBytes) != 0) {
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
                memcpy(dst, src, rowBytes);
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
