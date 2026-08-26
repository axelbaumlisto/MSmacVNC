#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "DisplayLayout.h"

/*
 * The per-display capture streams of one server run.
 *
 * This module owns ScreenCaptureKit. The server core asks it to build a session
 * for a display layout and never sees SCStream, CMSampleBuffer or an
 * SCStreamError: previously mac.m constructed every capturer by hand, held the
 * blocks that composite frames, and classified SCK error codes, so the file
 * that starts a TCP server also had to know the capture framework.
 *
 * THREADING, as used by mac.m - the stream list is not mutex-protected, and
 * that is sound only because of WHEN each operation runs:
 *
 *  - Build and Reset mutate the list. Both run under serverLifecycleMutex, at a
 *    point where no client thread exists yet or all have been joined by
 *    rfbShutdownServer(screen, TRUE).
 *  - Start, StopAndWait, WaitForFirstFrames and Count only READ the
 *    list (they message the streams, which are individually thread-safe).
 *    These do run on client threads.
 *
 * So a reader never overlaps a writer. Calling Build or Reset from a client
 * thread, or stopping the server without joining clients first, breaks that and
 * needs a lock here.
 *
 * StopAndWait BLOCKS - bounded, but up to five seconds per display while
 * in-flight capture work drains. Never call it while holding a lock that a
 * client thread needs (that stalls every other client, including a reconnect),
 * and never from a thread that must stay responsive. Reset can block for the
 * same reason and must follow StopAndWait.
 */

/*
 * Called on a capture queue with one display's freshly captured frame, already
 * unwrapped from ScreenCaptureKit.
 *
 * `pixels` is BGRA, `stride` bytes per row, valid only for the duration of the
 * call. Return false for "not now": the frame is re-submitted rather than
 * dropped, because after a static screen there may be no further frame for a
 * long time and its pixels would stay missing on the client.
 */
typedef bool (*MacVNCCaptureFrameHandler)(const MacVNCDisplayGeometry *geometry,
                                          const uint8_t *pixels,
                                          size_t stride,
                                          int width,
                                          int height);

/*
 * Called when capture fails at runtime. `likelyPermissionDenial` is true only
 * for errors consistent with a Screen Recording denial, so a transient failure
 * (display unplugged, stream stopped) cannot latch a permanent "permission
 * missing" state. Runs on a capture queue; the handler must hop threads itself.
 */
typedef void (*MacVNCCaptureFailureHandler)(bool likelyPermissionDenial);

/*
 * Creates a stream per display in `layout`.
 *
 * ALWAYS replaces the previous session, including when it then fails: a failed
 * rebuild must not leave the old run's streams installed, or the caller would
 * believe it has no session while stale streams still hold their displays.
 * So on false, Count() == 0.
 *
 * Does NOT start capture - Start does, once a client is authenticated.
 */
bool macVNCCaptureSessionBuild(const MacVNCDisplayLayout *layout,
                               int captureFramesPerSecond,
                               MacVNCCaptureFrameHandler frameHandler,
                               MacVNCCaptureFailureHandler failureHandler);

/* Releases the streams. A stream whose work never quiesced is deliberately
   leaked rather than freed while a callback may still touch it. */
void macVNCCaptureSessionReset(void);

size_t macVNCCaptureSessionCount(void);

void macVNCCaptureSessionStart(void);
void macVNCCaptureSessionStopAndWait(void);

/*
 * Waits for every stream's first frame, sharing ONE deadline across them all:
 * waiting `timeout` per display would multiply the client's wait by the number
 * of monitors. True when all became ready inside the budget.
 */
bool macVNCCaptureSessionWaitForFirstFrames(uint64_t timeoutNanoseconds);
