#pragma once

#include <CoreMedia/CoreMedia.h>
#include <rfb/rfb.h>

#include "DisplayLayout.h"

/*
 * Compositing captured display frames into the single shared framebuffer.
 *
 * Owns the compositor lock and the client-locking dance, which is the subtlest
 * part of the server: LibVNCServer holds a client's sendMutex for the whole
 * encode-and-write, so waiting on it would let one stalled viewer freeze the
 * screen for everybody. Extracted from mac.m so this hazard lives in one place
 * with the reasoning next to it, instead of inside the server's start-up file.
 */

/*
 * Composites one captured frame for `geometry` into rfbScreen's framebuffer and
 * marks the changed tiles.
 *
 * Returns FALSE for "not now" - a client was mid-send, or memory ran out. The
 * caller must RE-SUBMIT the same frame rather than drop it: after a static
 * screen there may be no further frame for a long time, and the dropped pixels
 * would stay missing on the client.
 */
rfbBool macVNCCompositorSubmitFrame(rfbScreenInfoPtr screen,
                                    CMSampleBufferRef sampleBuffer,
                                    const MacVNCDisplayGeometry *geometry);
