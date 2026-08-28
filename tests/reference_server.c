/*
 * Reference server: the instrument that made the codec measurements valid.
 *
 * A libvncserver instance whose framebuffer is fully controlled - either frozen
 * or scrolling at a fixed rate - filled with a real desktop screenshot.
 *
 * Measuring codec settings against the live screen failed three times: over the
 * ~60 s a sweep takes, the desktop repainted 10-40% of every candidate region,
 * so the "differences" being attributed to JPEG were mostly content changes.
 * This removes the desktop from the experiment: identical pixels for every
 * run, same encoder, same code path as the real server.
 *
 * usage: qserver <image.ppm> <port>
 */
#include <rfb/rfb.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int
main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <image.ppm> <port>\n", argv[0]);
        return 64;
    }

    FILE *f = fopen(argv[1], "rb");
    if (!f) {
        perror("open image");
        return 1;
    }
    char magic[3] = {0};
    int width = 0, height = 0, maxval = 0;
    if (fscanf(f, "%2s %d %d %d", magic, &width, &height, &maxval) != 4 ||
        strcmp(magic, "P6") || width <= 0 || height <= 0) {
        fprintf(stderr, "not a P6 PPM\n");
        return 1;
    }
    fgetc(f); /* single whitespace before the raster */

    uint8_t *rgb = malloc((size_t)width * height * 3);
    if (fread(rgb, 1, (size_t)width * height * 3, f) !=
        (size_t)width * height * 3) {
        fprintf(stderr, "short read\n");
        return 1;
    }
    fclose(f);

    rfbScreenInfoPtr screen = rfbGetScreen(&argc, argv, width, height, 8, 3, 4);
    screen->frameBuffer = malloc((size_t)width * height * 4);
    screen->port = atoi(argv[2]);
    screen->ipv6port = 0;
    screen->desktopName = "qserver static image";
    screen->alwaysShared = TRUE;

    for (size_t i = 0; i < (size_t)width * height; ++i) {
        uint8_t *dst = (uint8_t *)screen->frameBuffer + i * 4;
        dst[0] = rgb[i * 3 + 2]; /* B */
        dst[1] = rgb[i * 3 + 1]; /* G */
        dst[2] = rgb[i * 3 + 0]; /* R */
        dst[3] = 0;
    }
    free(rgb);

    rfbInitServer(screen);
    fprintf(stderr, "qserver: %dx%d on port %d%s\n", width, height, screen->port,
            getenv("QSERVER_ANIMATE") ? " (animating)" : " (static)");

    if (!getenv("QSERVER_ANIMATE")) {
        rfbRunEventLoop(screen, -1, FALSE);
        return 0;
    }

    /* Reproducible workload: scroll the image by a fixed number of pixels at a
       fixed rate. Comparing codec settings against a LIVE desktop was invalid -
       the bytes measured how much the desktop happened to repaint, not how the
       encoder behaves. Here every run encodes exactly the same changes. */
    const int shiftPerFrame = atoi(getenv("QSERVER_ANIMATE"));
    const int frameIntervalUs = 33333;
    uint8_t *scratch = malloc((size_t)width * 4);
    int offset = 0;
    while (rfbIsActive(screen)) {
        rfbProcessEvents(screen, frameIntervalUs);
        offset = (offset + shiftPerFrame) % width;
        for (int y = 0; y < height; ++y) {
            uint8_t *row = (uint8_t *)screen->frameBuffer + (size_t)y * width * 4;
            memcpy(scratch, row, (size_t)width * 4);
            for (int x = 0; x < width; ++x)
                memcpy(row + (size_t)x * 4,
                       scratch + (size_t)((x + shiftPerFrame) % width) * 4, 4);
        }
        rfbMarkRectAsModified(screen, 0, 0, width, height);
    }
    free(scratch);
    return 0;
}
