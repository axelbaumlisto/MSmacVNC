#pragma once

#include <stddef.h>
#include <stdint.h>

#include <rfb/rfb.h>

#include "CompositeFramebuffer.h"
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
 * Hand the compositor the screen it composites into, or NULL to detach.
 *
 * The compositor owns the pointer from here on: a capture callback can be in
 * flight at ANY moment, including the moment rfbScreenCleanup() frees the
 * screen. Reading the plain global at submit time had exactly that window -
 * load the pointer, get descheduled, watch the server tear down and free the
 * screen, then walk rfbGetClientIterator() on freed memory. SetScreen(NULL)
 * takes the compositor lock, so detaching BLOCKS until any in-flight composite
 * has finished; after it returns no callback can reach the old screen.
 *
 * Call SetScreen(rfbScreen) right after rfbInitServer, SetScreen(NULL) right
 * before rfbScreenCleanup. Cannot deadlock: the compositor only ever trylocks
 * client mutexes, never waits on the lifecycle lock.
 */
void macVNCCompositorSetScreen(rfbScreenInfoPtr screen);

/*
 * Composites one display's BGRA pixels into the attached screen's framebuffer
 * and marks the changed tiles. `stride` is bytes per row; the pixels need only
 * be valid for the duration of the call.
 *
 * Takes raw pixels, not a CMSampleBuffer: compositing has nothing to do with
 * ScreenCaptureKit, and depending on it made this module untestable without a
 * live capture stream.
 *
 * Returns FALSE for "not now" - a client was mid-send, or memory ran out. The
 * caller must RE-SUBMIT the same frame rather than drop it: after a static
 * screen there may be no further frame for a long time, and the dropped pixels
 * would stay missing on the client.
 */
rfbBool macVNCCompositorSubmitFrame(const MacVNCDisplayGeometry *geometry,
                                    const uint8_t *pixels,
                                    size_t stride,
                                    const MacVNCDirtyHint *hint);
