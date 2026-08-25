#pragma once

#import <Foundation/Foundation.h>

#include <stdbool.h>
#include <stdint.h>

@class ScreenCapturer;

/*
 * The set of per-display capture streams belonging to one server run.
 *
 * Extracted from mac.m, which iterated the capturer array in five places and
 * had to get "start once, stop once, wait within a shared budget" right each
 * time. Collecting it here means the empty case (a run with no capturers) and
 * the shared readiness budget are written once instead of per call site.
 *
 * Threading, as actually used by mac.m - the array is NOT mutex-protected, and
 * that is only sound because of when each operation runs:
 *
 *  - Reset/Add mutate the set. Both run under serverLifecycleMutex, in
 *    ScreenInit or vncServerStopLocked, at a point where no client thread
 *    exists yet or all have been joined by rfbShutdownServer(screen, TRUE).
 *  - Start, StopAndWait, WaitForFirstFrames, AllReady and Count only READ the
 *    array (they message the capturers, which are individually thread-safe).
 *    These do run on client threads.
 *
 * So a reader never overlaps a writer. Adding a call to Reset or Add from a
 * client thread, or stopping the server without joining clients first, breaks
 * that invariant and needs a lock here.
 */

/* Replaces the current set; releases any previous capturers. */
void macVNCCaptureSessionReset(void);

/* Adds a capturer, retaining it. Returns false only if `capturer` is nil. */
bool macVNCCaptureSessionAdd(ScreenCapturer *capturer);

size_t macVNCCaptureSessionCount(void);

void macVNCCaptureSessionStart(void);
void macVNCCaptureSessionStopAndWait(void);

/*
 * Waits for every stream's first frame, sharing one deadline across them all:
 * waiting `timeout` per display would multiply the client's wait by the number
 * of monitors. True when all became ready inside the budget.
 */
bool macVNCCaptureSessionWaitForFirstFrames(uint64_t timeoutNanoseconds);

/* True when every stream has delivered a frame for the current generation. */
bool macVNCCaptureSessionAllReady(void);
