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
 * Not thread-safe by itself: the caller serialises access, as mac.m does under
 * its client-lifecycle lock.
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
