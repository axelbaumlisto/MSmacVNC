/*
 * Measuring instrument, not a test: it needs a running server.
 *
 * Two-mode probe for choosing server settings from measurement.
 *
 *   frame  <quality> <compress> <jpeg> <out.ppm>
 *       Fetch ONE fixed region and save it. Quality -1 with JPEG off asks the
 *       server for LOSSLESS Tight (zlib only), which is the ground truth every
 *       lossy setting is compared against.
 *
 *   stream <seconds>
 *       Sit in the steady state a viewer sits in and report the distribution of
 *       gaps between completed framebuffer updates: min, mean, max and
 *       percentiles. Min/max matter as much as the median - the max IS the
 *       stall you notice.
 *
 * A fixed sub-region rather than the whole 15 Mpx screen: it keeps a sweep
 * quick, and text-heavy content is exactly what the quality question is about.
 */
#include <rfb/rfbclient.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int REGION_X = 0, REGION_Y = 0, REGION_W = 1200, REGION_H = 800;

static double gArrivals[200000];
static int gCount;
static long long gPixels;
static int gGotFrame;

static double
now_seconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void
onRect(rfbClient *cl, int x, int y, int w, int h)
{
    (void)cl; (void)x; (void)y;
    gPixels += (long long)w * h;
}

static void
onFinished(rfbClient *cl)
{
    (void)cl;
    gGotFrame = 1;
    if (gCount < (int)(sizeof(gArrivals) / sizeof(gArrivals[0])))
        gArrivals[gCount++] = now_seconds();
}

static char *
onPassword(rfbClient *cl)
{
    (void)cl;
    return strdup(getenv("VNCPASS") ? getenv("VNCPASS") : "");
}

static int
cmp_double(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static void
writeRegionPPM(rfbClient *cl, const char *path)
{
    FILE *f = fopen(path, "wb");
    if (!f) {
        perror("fopen");
        return;
    }
    fprintf(f, "P6\n%d %d\n255\n", REGION_W, REGION_H);
    const int bpp = cl->format.bitsPerPixel / 8;
    for (int y = REGION_Y; y < REGION_Y + REGION_H; ++y) {
        for (int x = REGION_X; x < REGION_X + REGION_W; ++x) {
            const uint8_t *p = (const uint8_t *)cl->frameBuffer +
                               ((size_t)y * cl->width + x) * bpp;
            /* Server framebuffer is BGRA; PPM wants RGB. */
            fputc(p[2], f);
            fputc(p[1], f);
            fputc(p[0], f);
        }
    }
    fclose(f);
}

int
main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr,
                "usage: %s host port frame <quality> <compress> <jpeg> <out.ppm>\n"
                "       %s host port stream <seconds>\n", argv[0], argv[0]);
        return 64;
    }
    const char *host = argv[1];
    const int port = atoi(argv[2]);
    const char *mode = argv[3];
    /* Region comes from the environment so a sweep can aim at content chosen
       by measurement (text vs photo) instead of whatever sits at 0,0. */
    if (getenv("PROBE_REGION")) {
        sscanf(getenv("PROBE_REGION"), "%d,%d,%d,%d",
               &REGION_X, &REGION_Y, &REGION_W, &REGION_H);
    }

    rfbClient *cl = rfbGetClient(8, 3, 4);
    cl->GotFrameBufferUpdate = onRect;
    cl->FinishedFrameBufferUpdate = onFinished;
    cl->GetPassword = onPassword;
    cl->serverHost = strdup(host);
    cl->serverPort = port;
    cl->appData.encodingsString = "tight";

    int quality = 7, compress = 5, jpeg = 1;
    double seconds = 20.0;
    const char *out = NULL;

    if (!strcmp(mode, "frame")) {
        if (argc < 8) {
            fprintf(stderr, "frame mode needs quality compress jpeg out.ppm\n");
            return 64;
        }
        quality = atoi(argv[4]);
        compress = atoi(argv[5]);
        jpeg = atoi(argv[6]);
        out = argv[7];
    } else if (!strcmp(mode, "stream")) {
        if (argc > 4)
            seconds = atof(argv[4]);
        if (argc > 7) {
            quality = atoi(argv[5]);
            compress = atoi(argv[6]);
            jpeg = atoi(argv[7]);
        }
    } else {
        fprintf(stderr, "unknown mode %s\n", mode);
        return 64;
    }

    cl->appData.compressLevel = compress;
    cl->appData.enableJPEG = jpeg ? TRUE : FALSE;
    /* libvncclient rewrites a negative quality to 5 when JPEG is on, so
       lossless MUST come in as jpeg=0: then no quality pseudo-encoding is
       sent, the server keeps tightQualityLevel = -1, and Tight stays zlib. */
    cl->appData.qualityLevel = quality;

    if (!rfbInitClient(cl, NULL, NULL)) {
        printf("connect failed\n");
        return 1;
    }

    if (out) {
        double t0 = now_seconds();
        SendFramebufferUpdateRequest(cl, REGION_X, REGION_Y, REGION_W, REGION_H,
                                     FALSE);
        /* Wait for the region's worth of PIXELS, not merely for one "update
           finished": the first completed update can be empty (cursor, LastRect
           only), and saving then produced a pure black image that silently
           invalidated an entire measurement sweep. */
        const long long needed = (long long)REGION_W * REGION_H;
        while ((!gGotFrame || gPixels < needed) && now_seconds() - t0 < 30.0) {
            int w = WaitForMessage(cl, 200000);
            if (w < 0)
                break;
            if (w && !HandleRFBServerMessage(cl))
                break;
        }
        if (!gGotFrame) {
            printf("no frame\n");
            return 2;
        }
        writeRegionPPM(cl, out);
        /* Content signature, printed by the TOOL: a measurement that silently
           captured nothing must be impossible to mistake for a good run. */
        int histogram[64] = {0};
        long long sum = 0, samples = 0;
        const int bpp = cl->format.bitsPerPixel / 8;
        for (int y = REGION_Y; y < REGION_Y + REGION_H; y += 3) {
            for (int x = REGION_X; x < REGION_X + REGION_W; x += 3) {
                const uint8_t *p = (const uint8_t *)cl->frameBuffer +
                                   ((size_t)y * cl->width + x) * bpp;
                int v = (p[0] + p[1] + p[2]) / 3;
                histogram[v / 4]++;
                sum += v;
                samples++;
            }
        }
        int occupied = 0;
        for (int i = 0; i < 64; ++i)
            if (histogram[i])
                ++occupied;
        printf("q=%d c=%d jpeg=%d region=%dx%d px=%lld saved=%s elapsed=%.2fs "
               "mean=%.1f levels=%d %s\n",
               quality, compress, jpeg, REGION_W, REGION_H, gPixels, out,
               now_seconds() - t0, samples ? (double)sum / samples : 0.0,
               occupied, occupied >= 8 ? "CONTENT" : "*** EMPTY/FLAT ***");
        rfbClientCleanup(cl);
        return 0;
    }

    /* Stream mode: full screen, incremental, like a viewer. */
    double start = now_seconds();
    SendFramebufferUpdateRequest(cl, 0, 0, cl->width, cl->height, FALSE);
    while (now_seconds() - start < seconds) {
        int w = WaitForMessage(cl, 500000);
        if (w < 0)
            break;
        if (w && !HandleRFBServerMessage(cl))
            break;
        SendFramebufferUpdateRequest(cl, 0, 0, cl->width, cl->height, TRUE);
    }

    if (gCount < 4) {
        printf("updates=%d (too few)\n", gCount);
        return 3;
    }
    int n = gCount - 1; /* drop the initial full frame */
    int ngaps = n - 1;
    double *gaps = malloc(sizeof(double) * (size_t)ngaps);
    double sum = 0;
    for (int i = 0; i < ngaps; ++i) {
        gaps[i] = 1000.0 * (gArrivals[i + 2] - gArrivals[i + 1]);
        sum += gaps[i];
    }
    qsort(gaps, (size_t)ngaps, sizeof(double), cmp_double);
    double span = gArrivals[gCount - 1] - gArrivals[1];
    printf("frames=%d fps=%.1f gap_ms min=%.1f mean=%.1f p50=%.1f p90=%.1f "
           "p99=%.1f max=%.1f Mpx_s=%.1f\n",
           n, span > 0 ? n / span : 0,
           gaps[0], sum / ngaps, gaps[ngaps / 2],
           gaps[(int)(ngaps * 0.90)], gaps[(int)(ngaps * 0.99)],
           gaps[ngaps - 1], span > 0 ? (double)gPixels / span / 1e6 : 0);
    free(gaps);
    rfbClientCleanup(cl);
    return 0;
}
