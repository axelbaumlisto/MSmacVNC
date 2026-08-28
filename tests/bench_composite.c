/*
 * Microbenchmark for the tile compositor - the one CPU-bound stage that runs
 * on EVERY captured frame of EVERY display, before a single byte reaches a
 * client. It answers three questions with numbers instead of intuition:
 *
 *   1. What does an IDLE frame cost? (pure comparison, nothing copied)
 *   2. What does a realistic change cost? (cursor / typing / window / scroll)
 *   3. Which tile size is actually best for this canvas?
 *
 * Reported per scenario: milliseconds per frame, the implied frame ceiling
 * (how many such frames per second one core could composite), throughput in
 * canvas-MB/s, and how many tiles were marked dirty.
 *
 * Not a ctest target: it is a measuring instrument, not an assertion.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "CompositeFramebuffer.h"

/* The real deployment: two Retina displays side by side, 5552x2715 canvas. */
#define CANVAS_W 5552
#define CANVAS_H 2715
#define DISP_W 3456
#define DISP_H 2234

static double
nowSeconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static size_t gDirtyRects;

static void
countDirty(void *ctx, int x, int y, int w, int h)
{
    (void)ctx; (void)x; (void)y; (void)w; (void)h;
    ++gDirtyRects;
}

/* Photo-ish content: neighbouring pixels differ, so no memcmp shortcut can
   pretend the frame is empty. */
static void
fillNoise(uint8_t *buf, size_t pixels, unsigned seed)
{
    uint32_t state = seed ? seed : 1u;
    for (size_t i = 0; i < pixels; ++i) {
        state = state * 1664525u + 1013904223u;
        buf[i * 4 + 0] = (uint8_t)(state >> 16);
        buf[i * 4 + 1] = (uint8_t)(state >> 8);
        buf[i * 4 + 2] = (uint8_t)state;
        buf[i * 4 + 3] = 0;
    }
}

/* Dirty a w x h box at (x0,y0) in the SOURCE frame only. */
static void
dirtyBox(uint8_t *src, size_t stridePixels, int x0, int y0, int w, int h, unsigned seed)
{
    uint32_t state = seed ? seed : 1u;
    for (int y = y0; y < y0 + h; ++y)
        for (int x = x0; x < x0 + w; ++x) {
            state = state * 1664525u + 1013904223u;
            uint8_t *p = src + ((size_t)y * stridePixels + (size_t)x) * 4;
            p[0] = (uint8_t)(state >> 16);
            p[1] = (uint8_t)(state >> 8);
            p[2] = (uint8_t)state;
        }
}

typedef struct {
    const char *name;
    int boxW, boxH;      /* 0x0 = identical frame; -1 = whole display */
    int hinted;          /* 1 = tell the compositor where the box is */
} Scenario;

static const Scenario kScenarios[] = {
    { "idle (identical frame)",        0,    0,    0 },
    { "cursor move (64x64)",           64,   64,   0 },
    { "cursor move + SCK hint",        64,   64,   1 },
    { "typing / caret (300x40)",       300,  40,   0 },
    { "typing + SCK hint",             300,  40,   1 },
    { "video window (1280x720)",       1280, 720,  0 },
    { "video window + SCK hint",       1280, 720,  1 },
    { "full-screen scroll",            -1,   -1,   0 },
    { "full-screen scroll + hint",     -1,   -1,   1 },
};

static const int kTileSizes[] = { 16, 32, 64, 128, 256 };

int
main(void)
{
    const size_t canvasPixels = (size_t)CANVAS_W * CANVAS_H;
    const size_t dispPixels = (size_t)DISP_W * DISP_H;
    uint8_t *canvas = malloc(canvasPixels * 4);
    uint8_t *source = malloc(dispPixels * 4);
    uint8_t *pristine = malloc(dispPixels * 4);
    if (!canvas || !source || !pristine) {
        fprintf(stderr, "out of memory\n");
        return 1;
    }

    MacVNCDisplayGeometry display;
    memset(&display, 0, sizeof(display));
    display.input.displayID = 1;
    display.input.pixelWidth = DISP_W;
    display.input.pixelHeight = DISP_H;
    display.framebufferX = 0;
    display.framebufferY = 0;

    const size_t stride = (size_t)DISP_W * 4;
    const double displayMB = (double)(dispPixels * 4) / (1024.0 * 1024.0);

    printf("canvas %dx%d, display %dx%d (%.1f MB per frame)\n\n",
           CANVAS_W, CANVAS_H, DISP_W, DISP_H, displayMB);
    printf("%-28s %6s %9s %9s %9s %8s\n",
           "scenario", "tile", "ms/frame", "fps ceil", "MB/s", "dirty");
    printf("%-28s %6s %9s %9s %9s %8s\n",
           "----------------------------", "-----", "--------", "--------",
           "--------", "-------");

    for (size_t s = 0; s < sizeof(kScenarios) / sizeof(kScenarios[0]); ++s) {
        const Scenario *sc = &kScenarios[s];
        for (size_t t = 0; t < sizeof(kTileSizes) / sizeof(kTileSizes[0]); ++t) {
            const int tile = kTileSizes[t];

            fillNoise(pristine, dispPixels, 12345u);
            memset(canvas, 0, canvasPixels * 4);
            /* Prime the canvas so the benchmarked frames start from a
               steady state, exactly like a running session. */
            memcpy(source, pristine, dispPixels * 4);
            macVNCCompositeDisplayFrame(canvas, CANVAS_W, CANVAS_H, &display,
                                        source, stride, tile, NULL, NULL);

            const int rounds = (sc->boxW == 0) ? 20 : 10;
            double best = 1e9;
            size_t dirtyTiles = 0;
            for (int r = 0; r < rounds; ++r) {
                memcpy(source, pristine, dispPixels * 4);
                if (sc->boxW < 0)
                    dirtyBox(source, DISP_W, 0, 0, DISP_W, DISP_H, (unsigned)(r + 7));
                else if (sc->boxW > 0)
                    dirtyBox(source, DISP_W, 100, 100, sc->boxW, sc->boxH,
                             (unsigned)(r + 7));

                /* What ScreenCaptureKit would have told us about this frame. */
                MacVNCDirtyRect hintRect;
                if (sc->boxW < 0)
                    hintRect = (MacVNCDirtyRect){ 0, 0, DISP_W, DISP_H };
                else
                    hintRect = (MacVNCDirtyRect){ 100, 100, sc->boxW, sc->boxH };
                MacVNCDirtyHint hint = { &hintRect, sc->hinted ? 1 : 0 };

                gDirtyRects = 0;
                double t0 = nowSeconds();
                dirtyTiles = macVNCCompositeDisplayFrameHinted(
                    canvas, CANVAS_W, CANVAS_H, &display, source, stride, tile,
                    &hint, countDirty, NULL);
                double dt = nowSeconds() - t0;
                if (dt < best)
                    best = dt;
                /* Restore the canvas so every round does the same work. */
                if (sc->boxW != 0) {
                    memcpy(source, pristine, dispPixels * 4);
                    macVNCCompositeDisplayFrame(canvas, CANVAS_W, CANVAS_H,
                                                &display, source, stride, tile,
                                                NULL, NULL);
                }
            }

            printf("%-28s %6d %9.2f %9.0f %9.0f %8zu\n",
                   t == 0 ? sc->name : "", tile, best * 1000.0, 1.0 / best,
                   displayMB / best, dirtyTiles);
        }
        printf("\n");
    }

    free(canvas);
    free(source);
    free(pristine);
    return 0;
}
