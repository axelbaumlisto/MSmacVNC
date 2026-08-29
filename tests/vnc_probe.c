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
 *
 * Password: PROBE_PASSWORD in the environment, never an argv word, so it does
 * not sit in `ps` output for every user on the machine (the server side takes
 * the same care with MACVNC_PASSWORD_FILE).
 */
#include <rfb/rfbclient.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int REGION_X = 0, REGION_Y = 0, REGION_W = 1200, REGION_H = 800;

/* Sampling stride and the black threshold are printed with the numbers: a
   verdict whose definition is invisible is not a measurement. A pixel counts
   as non-black when its luma exceeds this, which tolerates the few units of
   ringing JPEG leaves on a genuinely black curtain. */
#define SAMPLE_STRIDE 3
#define BLACK_LUMA 8

struct regionStats {
    long long samples;  /* pixels actually examined */
    long long nonblack; /* of those, how many exceed BLACK_LUMA */
    long long sum;      /* luma sum, for the mean */
    int max;            /* brightest luma seen */
    int levels;         /* occupied buckets of a 64-bin luma histogram */
};

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

/*
 * libvncclient asks here, once, during the VNC auth handshake.
 *
 * The password arrives through the environment, not argv: an argument is world
 * readable through ps for as long as the probe runs. Returning NULL makes
 * libvncclient fail the handshake cleanly instead of sending an empty password
 * and reporting the confusing "authentication failed".
 *
 * Note VNC auth is DES-based: only the first 8 characters of the password are
 * significant, on this client and on every server.
 */
static char *
onPassword(rfbClient *cl)
{
    (void)cl;
    const char *pw = getenv("PROBE_PASSWORD");
    if (!pw || !*pw)
        pw = getenv("VNCPASS"); /* the older name, still honoured */
    if (!pw || !*pw) {
        fprintf(stderr,
                "vnc_probe: server asked for a password; "
                "set PROBE_PASSWORD in the environment\n");
        return NULL;
    }
    return strdup(pw);
}

/*
 * Sample the region and say what is in it in numbers.
 *
 * "I sampled nothing" and "I sampled a black screen" are different failures and
 * must not look alike: the first leaves samples == 0, the second leaves
 * samples > 0 with nonblack == 0.
 */
static void
sampleRegion(rfbClient *cl, struct regionStats *st)
{
    int histogram[64] = {0};
    memset(st, 0, sizeof(*st));

    const int bpp = cl->format.bitsPerPixel / 8;
    for (int y = REGION_Y; y < REGION_Y + REGION_H; y += SAMPLE_STRIDE) {
        for (int x = REGION_X; x < REGION_X + REGION_W; x += SAMPLE_STRIDE) {
            const uint8_t *p = (const uint8_t *)cl->frameBuffer +
                               ((size_t)y * cl->width + x) * bpp;
            /* BGRA in the framebuffer; Rec.601 luma. */
            int luma = (77 * p[2] + 150 * p[1] + 29 * p[0]) >> 8;
            histogram[luma / 4]++;
            st->sum += luma;
            if (luma > BLACK_LUMA)
                st->nonblack++;
            if (luma > st->max)
                st->max = luma;
            st->samples++;
        }
    }
    for (int i = 0; i < 64; ++i)
        if (histogram[i])
            st->levels++;
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
                "       %s host port stream <seconds> [quality compress jpeg]\n"
                "\n"
                "environment:\n"
                "  PROBE_PASSWORD  VNC password, for a server that requires one.\n"
                "                  Kept out of argv so it never shows up in ps.\n"
                "                  VNC auth is DES: only the first 8 characters\n"
                "                  count. Unset means \"expect no password\".\n"
                "  PROBE_REGION    x,y,w,h of the region to fetch and sample\n"
                "                  (default %d,%d,%d,%d), clamped to the server\n"
                "                  framebuffer.\n"
                "\n"
                "frame mode prints samples/nonblack/mean_luma/max_luma for the\n"
                "region it sampled: nonblack=0 with samples>0 is a BLACK screen,\n"
                "samples=0 means nothing was examined at all, and a desktop puts\n"
                "nonblack near 100%% with mean_luma in the tens or hundreds.\n",
                argv[0], argv[0], REGION_X, REGION_Y, REGION_W, REGION_H);
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
        /* Clamp to the framebuffer we actually got: sampling past its end reads
           other people's memory and reports whatever it finds as "content". */
        if (REGION_X < 0)
            REGION_X = 0;
        if (REGION_Y < 0)
            REGION_Y = 0;
        if (REGION_W <= 0 || REGION_H <= 0 || REGION_X >= cl->width ||
            REGION_Y >= cl->height) {
            printf("region %d,%d,%d,%d lies outside the %dx%d framebuffer: "
                   "samples=0 nonblack=0 *** NO SAMPLES ***\n",
                   REGION_X, REGION_Y, REGION_W, REGION_H, cl->width,
                   cl->height);
            return 2;
        }
        if (REGION_X + REGION_W > cl->width)
            REGION_W = cl->width - REGION_X;
        if (REGION_Y + REGION_H > cl->height)
            REGION_H = cl->height - REGION_Y;

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
           captured nothing must be impossible to mistake for a good run, and a
           black curtain must be impossible to mistake for a desktop. */
        struct regionStats st;
        sampleRegion(cl, &st);
        const char *verdict = "CONTENT";
        if (st.samples == 0)
            verdict = "*** NO SAMPLES ***";
        else if (st.nonblack == 0)
            verdict = "*** BLACK ***";
        else if (st.nonblack * 200 < st.samples)
            /* A black screen still carries the mouse cursor the server paints
               into the framebuffer: a handful of white pixels in 100k is not a
               desktop. Under half a percent, say that, not "flat". */
            verdict = "*** NEARLY BLACK (<0.5% lit) ***";
        else if (st.levels < 8)
            verdict = "*** EMPTY/FLAT ***";
        printf("q=%d c=%d jpeg=%d region=%dx%d+%d+%d px=%lld saved=%s "
               "elapsed=%.2fs stride=%d samples=%lld nonblack(>%d)=%lld (%.1f%%) "
               "mean_luma=%.1f max_luma=%d levels=%d %s\n",
               quality, compress, jpeg, REGION_W, REGION_H, REGION_X, REGION_Y,
               gPixels, out, now_seconds() - t0, SAMPLE_STRIDE, st.samples,
               BLACK_LUMA, st.nonblack,
               st.samples ? 100.0 * (double)st.nonblack / (double)st.samples
                          : 0.0,
               st.samples ? (double)st.sum / (double)st.samples : 0.0, st.max,
               st.levels, verdict);
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
