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
 * THREADING: EVERY function here takes the module's mutex, for long enough to
 * either mutate the stream list or copy it.
 *
 * It used to be only three of them, on the argument that the other readers
 * (Start, StopAndWait, WaitForFirstFrames, Count) run on client threads, which
 * rfbShutdownServer(screen, TRUE) joins before Build or Reset can run. That
 * argument was FALSE, and the counter-example ships: mac.m's capture keep-warm
 * timer fires on gCaptureStopQueue - a queue nothing joins - and calls
 * StopAndWait() and Count() after dropping captureControlMutex, so it can
 * overlap the Reset inside vncServerStopLocked, which nils and releases the
 * list. Enumerating `gCapturers` while another thread releases it is a
 * use-after-free with a plausible-looking stack.
 *
 * So the rule is now the simple one, with no per-caller reasoning to keep
 * true: readers snapshot under the lock (which retains every stream for the
 * duration of the call) and work on the snapshot; writers swap the pointer
 * under the lock and release the old list outside it.
 *
 * That mutex is a LEAF: it is taken after serverLifecycleMutex (Build/Reset run
 * under it) and never held while messaging a capturer, so no callback path can
 * take it in the other order. It is never held across -[ScreenCapturer dealloc]
 * either - Reset moves the list out under the lock and releases it outside,
 * because that dealloc can wait, bounded, for a sample queue to drain and the
 * main thread must not block for seconds behind it.
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
 * call. `hint` names the rectangles the capture source repainted, and is valid
 * for the duration of the call too; an empty hint means "sweep everything". Return false for "not now": the frame is re-submitted rather than
 * dropped, because after a static screen there may be no further frame for a
 * long time and its pixels would stay missing on the client.
 */
typedef bool (*MacVNCCaptureFrameHandler)(const MacVNCDisplayGeometry *geometry,
                                          const uint8_t *pixels,
                                          size_t stride,
                                          int width,
                                          int height,
                                          const MacVNCDirtyHint *hint);

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

/*
 * Whether the CURRENT session's streams are excluding this application, i.e.
 * whether what a successful SetSelfExcluded(true) established is still true.
 *
 * False when there is no session, and false again after a rebuild: the
 * exclusion is state on an SCStream and Build always constructs the default
 * filter, so a server stop/start silently un-hides us. Nothing reports that,
 * which is why it must be ASKED - a curtain whose windows are up over a stream
 * that no longer excludes them is the one state the raise/lift ordering exists
 * to prevent, and the curtain's controller polls this to catch it.
 */
bool macVNCCaptureSessionSelfExcluded(void);

void macVNCCaptureSessionStart(void);
void macVNCCaptureSessionStopAndWait(void);

/*
 * Waits for every stream's first frame, sharing ONE deadline across them all:
 * waiting `timeout` per display would multiply the client's wait by the number
 * of monitors. True when all became ready inside the budget.
 */
bool macVNCCaptureSessionWaitForFirstFrames(uint64_t timeoutNanoseconds);

/* Called exactly once, on the MAIN queue, with the outcome of an exclusion
 * request. Main queue because the only caller acts on it by ordering windows
 * in or out, which is main-thread-only work. */
typedef void (*MacVNCCaptureExclusionCompletion)(void *context, bool success);

/*
 * Ask every stream of the session to stop (or resume) capturing THIS
 * application's own windows - the capture half of curtain mode.
 *
 * Excludes by APPLICATION, not by window: the filter is rebuilt with
 * -[SCContentFilter initWithDisplay:excludingApplications:exceptingWindows:]
 * and swapped onto the RUNNING stream with -updateContentFilter:, so it
 * survives window recreation (display hot-plug needs no second round trip) and
 * the stream is never stopped and restarted.
 *
 * IT IS NOT ORDER-INDEPENDENT, though the first version of this comment said
 * so. WHICH application is named is ScreenCapturer's business, and naming it
 * requires finding this process in an SCShareableContent discovery - which
 * lists the owners of shareable WINDOWS. A live run settled it: a menu-bar app
 * that owns no window is absent from that list under EITHER discovery variant,
 * and the request then refuses. So the CALLER must already have a window on
 * screen before asking for `excluded:true` - MacVNCCurtain orders an invisible
 * one in first. The first exclusion of a stream spends one discovery round trip
 * on this (see -[ScreenCapturer resolveOwnApplicationWithCompletionHandler:]),
 * which is why this call is asynchronous and why the caller owns the deadline.
 * A process that cannot be resolved makes the request FAIL - never a filter
 * that excludes nobody while reporting success, which would black out the
 * remote viewer.
 *
 * `success` is true only when EVERY stream confirmed the swap. A session with
 * no streams reports failure: "nothing to exclude" must not read as "the
 * curtain may go up", because with no live stream a raised curtain shows the
 * local user black and the remote party nothing.
 *
 * Applies NO timeout of its own - a completion that never arrives is the
 * caller's to bound (see MacVNCCurtainWindow), so the deadline has one owner.
 *
 * Safe to call from the main thread concurrently with a server start or stop:
 * it takes the module mutex (see THREADING above) just long enough to copy the
 * stream list, which retains every stream for the duration of the request, and
 * releases it before messaging any of them. A session being rebuilt underneath
 * is seen as "no streams", i.e. failure.
 *
 * The exclusion lives on the streams of the CURRENT session only: it is state
 * on an SCStream, and Build always constructs the default filter, so a session
 * rebuilt after a server stop/start no longer excludes us. Whoever decides when
 * the curtain is up must re-establish or drop it; this module does not - it
 * only answers macVNCCaptureSessionSelfExcluded() honestly, including for a
 * request that confirms after the session it belonged to was replaced.
 */
void macVNCCaptureSessionSetSelfExcluded(bool excluded,
                                         MacVNCCaptureExclusionCompletion completion,
                                         void *context);
