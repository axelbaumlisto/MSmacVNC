#import <Foundation/Foundation.h>

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "MacVNCCompositor.h"

/*
 * Compositing, exercised without ScreenCaptureKit.
 *
 * Until the capture framework was pushed behind MacVNCCaptureSession this
 * module took a CMSampleBufferRef, so none of it could be tested without a live
 * capture stream and a granted permission — the hot path that paints every
 * frame had no unit test at all.
 *
 * There are no clients here, so lockCurrentClients() locks an empty set and
 * compositing proceeds: exactly the path a frame takes between a client
 * disconnecting and the captures stopping.
 */

static rfbScreenInfo *makeScreen(int width, int height)
{
    rfbScreenInfo *screen = calloc(1, sizeof(*screen));
    assert(screen);
    screen->width = width;
    screen->height = height;
    screen->frameBuffer = calloc(1, (size_t)width * height * 4);
    assert(screen->frameBuffer);
    screen->clientHead = NULL;
    return screen;
}

static void freeScreen(rfbScreenInfo *screen)
{
    free(screen->frameBuffer);
    free(screen);
}

static MacVNCDisplayGeometry makeGeometry(int x, int y, int w, int h)
{
    MacVNCDisplayGeometry g;
    memset(&g, 0, sizeof(g));
    g.input.displayID = 1;
    g.input.pixelWidth = w;
    g.input.pixelHeight = h;
    g.framebufferX = x;
    g.framebufferY = y;
    return g;
}

int main(void)
{
    @autoreleasepool {
        const int W = 64, H = 32;
        rfbScreenInfo *screen = makeScreen(W, H);

        /* A source that is entirely one colour, placed at the origin. */
        const int sw = 16, sh = 8;
        size_t stride = (size_t)sw * 4;
        uint8_t *pixels = malloc(stride * sh);
        assert(pixels);
        memset(pixels, 0x7F, stride * sh);

        MacVNCDisplayGeometry geometry = makeGeometry(0, 0, sw, sh);
        assert(macVNCCompositorSubmitFrame(screen, &geometry, pixels, stride) == TRUE);

        /* The pixels landed where the geometry says, and nowhere else. */
        const uint8_t *canvas = (const uint8_t *)screen->frameBuffer;
        assert(canvas[0] == 0x7F);
        assert(canvas[((size_t)(sh - 1) * W + (sw - 1)) * 4] == 0x7F);
        assert(canvas[((size_t)0 * W + sw) * 4] == 0x00);       /* just right of it */
        assert(canvas[((size_t)sh * W + 0) * 4] == 0x00);        /* just below it */

        /* A second display at an offset must not disturb the first. */
        uint8_t *other = malloc(stride * sh);
        assert(other);
        memset(other, 0x21, stride * sh);
        MacVNCDisplayGeometry offset = makeGeometry(sw, 0, sw, sh);
        assert(macVNCCompositorSubmitFrame(screen, &offset, other, stride) == TRUE);
        assert(canvas[0] == 0x7F);                                /* untouched */
        assert(canvas[((size_t)0 * W + sw) * 4] == 0x21);         /* newly painted */

        /* A torn-down server must be survivable: a frame can still be in flight
           while the screen is being freed, and the bounded capture stop means it
           really does happen. TRUE means "not retryable", not "composited". */
        assert(macVNCCompositorSubmitFrame(NULL, &geometry, pixels, stride) == TRUE);
        rfbScreenInfo *noBuffer = makeScreen(W, H);
        free(noBuffer->frameBuffer);
        noBuffer->frameBuffer = NULL;
        assert(macVNCCompositorSubmitFrame(noBuffer, &geometry, pixels, stride) == TRUE);
        free(noBuffer);
        assert(macVNCCompositorSubmitFrame(screen, NULL, pixels, stride) == TRUE);
        assert(macVNCCompositorSubmitFrame(screen, &geometry, NULL, stride) == TRUE);

        free(other);
        free(pixels);
        freeScreen(screen);

        printf("test_compositor_submit: all assertions passed\n");
    }
    return 0;
}
