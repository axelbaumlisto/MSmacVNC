#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define MACVNC_MAX_DISPLAYS 16

typedef struct {
    uint32_t displayID;
    double logicalX;
    double logicalY;
    double logicalWidth;
    double logicalHeight;
    int pixelWidth;
    int pixelHeight;
} MacVNCDisplayInput;

typedef struct {
    MacVNCDisplayInput input;
    int framebufferX;
    int framebufferY;
} MacVNCDisplayGeometry;

typedef struct {
    size_t count;
    int width;
    int height;
    double logicalMinX;
    double logicalMinY;
    MacVNCDisplayGeometry displays[MACVNC_MAX_DISPLAYS];
} MacVNCDisplayLayout;

/** A rectangle in DISPLAY-LOCAL pixels (not canvas coordinates). */
typedef struct {
    int x;
    int y;
    int width;
    int height;
} MacVNCDirtyRect;

/*
 * Where a frame changed, as reported by the capture source.
 *
 * ScreenCaptureKit already knows which rectangles it repainted, and comparing
 * the untouched 99% of a 29 MB frame against the canvas is the single most
 * expensive thing this server does per frame. `count == 0` means "no usable
 * hint" and asks for a full sweep - which the caller must also request
 * periodically, so a hint that ever under-reports cannot leave a region of
 * the canvas permanently stale.
 */
typedef struct {
    const MacVNCDirtyRect *rects;
    size_t count;
} MacVNCDirtyHint;

bool macVNCBuildDisplayLayout(const MacVNCDisplayInput *inputs,
                              size_t count,
                              MacVNCDisplayLayout *layout);

bool macVNCMapFramebufferPoint(const MacVNCDisplayLayout *layout,
                               int framebufferX,
                               int framebufferY,
                               double *globalX,
                               double *globalY,
                               uint32_t *displayID);

/*
 * True when two layouts describe the same desk in the same arrangement.
 *
 * The comparison is POSITIONAL, not set-equality: two layouts with the same
 * displays but at different array indices are NOT equal. That is deliberate,
 * not an oversight - two real callers read a MacVNCDisplayLayout BY INDEX and
 * would silently misattribute data across different physical displays if a
 * reorder were called "no change":
 *   - the capture-liveness watchdog's per-display frame timestamps (mac.m)
 *     are indexed by position; calling a reorder "equal" would skip resetting
 *     them, so a timestamp measuring how long PANEL A has been silent would
 *     keep being read as PANEL B's history the moment the two swap slots;
 *   - `macVNCSelectDisplays` with a specific index (or falling back to "first
 *     entry" for PRIMARY) picks BY POSITION in whatever CoreGraphics just
 *     enumerated - an enumeration order that is not guaranteed to stay the
 *     same across two reads of an otherwise-unchanged desk. Treating a reorder
 *     as "no change" would let a later positional selection start capturing a
 *     different monitor with nothing anywhere saying so.
 * Whichever of those two risks would actually materialize for a given reorder
 * depends on facts this module does not have (why the order changed, which
 * selector is configured) - so the safe rule is the one that can never hide a
 * real difference: order counts.
 *
 * Equal requires: same `count`, same canvas `width`/`height`, and per index the
 * same `displayID`, logical rect, pixel size and framebuffer origin.
 *
 * Logical coordinates are direct `CGDisplayBounds` reads, not the result of
 * arithmetic on them, so two reads of a truly unchanged desk return
 * bit-identical doubles in practice. The epsilon below exists only so this
 * function is not a landmine if that ever stops being exactly true - it is not
 * evidence that real drift is expected, and it is far smaller than any change
 * a display reconfiguration could plausibly produce.
 */
bool macVNCDisplayLayoutsEqual(const MacVNCDisplayLayout *a,
                               const MacVNCDisplayLayout *b);
