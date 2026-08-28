#pragma once

#include <stdbool.h>

/*
 * How the server encodes pixels for a viewer.
 *
 * VNC lets the CLIENT ask for a Tight/JPEG quality level, and most viewers do.
 * The server owns the field afterwards, so this is the setting that decides
 * whether we honour that request or impose our own answer.
 *
 * The ladder below is measured, not chosen by taste (1600x600 UI+photo image,
 * identical pixels every run; MB/s from a reproducible scrolling workload):
 *
 *   level    wire      PSNR text   MB/s   note
 *   lossless 1.00x     perfect     5.7    only perfect option, highest CPU
 *   7        0.86x     35.7 dB     5.1
 *   6        0.72x     33.4 dB     4.4
 *   5        0.63x     31.5 dB     3.8    default
 *   4        0.51x     29.8 dB     3.2
 *   3        0.43x     28.5 dB     2.6    within noise of level 2
 *   2        0.42x     28.2 dB     2.6
 *   1        0.37x     27.3 dB     2.1
 *   0        0.29x     25.4 dB     1.9    smallest bandwidth
 *
 * Two levels are deliberately NOT offered, because measurement showed them
 * strictly dominated by lossless - more bytes AND worse pixels:
 * level 8 costs 1.07x for 39.1 dB, level 9 costs 2.45x for 53.0 dB.
 *
 * Compression level is not offered either: levels 1-9 produce byte-identical
 * output (305435 bytes every time, same CPU), and level 0 is 4.3x larger for
 * the same pixels. A setting whose only working value is "not 0" is not a
 * setting, so the encoder is simply given a sane fixed value.
 *
 * Frame rate is deliberately NOT part of this: there is one capture stream per
 * display shared by every viewer, so it cannot be per-connection.
 */

#define MACVNC_IMAGE_QUALITY_MIN 0
#define MACVNC_IMAGE_QUALITY_MAX 7
#define MACVNC_IMAGE_QUALITY_DEFAULT 5
/* The default as a stored NAME, so the defaults registration and the parser
   cannot disagree about what "default" means. */
#define MACVNC_IMAGE_PROFILE_DEFAULT_NAME "5"

/* Fixed compression level handed to the encoder; see the note above. */
#define MACVNC_IMAGE_COMPRESS_LEVEL 6

typedef enum {
    /* Leave the viewer's own request alone - per-device quality without the
       server keeping any per-client state. */
    MacVNCImageProfileFollowViewer = 0,
    /* Tight without JPEG: perfect pixels. */
    MacVNCImageProfileLossless = 1,
    /* Tight with JPEG at `qualityLevel`. */
    MacVNCImageProfileJPEG = 2,
} MacVNCImageProfileKind;

typedef struct {
    MacVNCImageProfileKind kind;
    /* Meaningful only for MacVNCImageProfileJPEG; 0..7. */
    int qualityLevel;
} MacVNCImageProfile;

/*
 * Parse a stored setting name: "viewer", "lossless", or "0".."7".
 *
 * Returns false for anything else - including levels 8 and 9, which exist in
 * the protocol but are dominated by lossless. On false the output is left
 * UNTOUCHED, so a caller can pre-load macVNCDefaultImageProfile() and let a
 * rejected name simply not overwrite it; an unparsable setting can never leave
 * the encoder with an undefined level.
 */
bool macVNCParseImageProfile(const char *name, MacVNCImageProfile *profile);

/** The measured best default: JPEG quality 5. */
MacVNCImageProfile macVNCDefaultImageProfile(void);

/** Stable name for a profile, suitable for storing and logging. */
const char *macVNCImageProfileName(MacVNCImageProfile profile);
