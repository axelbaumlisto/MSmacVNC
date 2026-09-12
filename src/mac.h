#pragma once

#include <rfb/rfb.h>
#include <stdatomic.h>
#include <stddef.h>
#include "MacVNCEncryptionPolicy.h"
#include "MacVNCImageProfile.h"
#include "NetworkPolicyResolver.h"

#define MACVNC_LISTEN_ADDRESS_MAX 64
#define MACVNC_ALLOWED_CLIENTS_MAX 4096

/* -----------------------------------------------------------------------
 * Immutable server configuration passed by value to vncServerStart().
 * Replaces the former ambient mutable globals: AppDelegate builds this from
 * the resolved network policy and defaults, and the server owns a private
 * copy for its lifetime.
 * ----------------------------------------------------------------------- */
typedef struct {
    int port;                    /* TCP port (5900 = VNC default). */
    const char *password;        /* Shared password; must be non-empty. */
    int captureFramesPerSecond;
    /* How pixels are encoded for viewers; see MacVNCImageProfile.h. */
    MacVNCImageProfile imageProfile;
    /* Whether an unencrypted viewer is admitted at all. */
    MacVNCEncryptionPolicy encryptionPolicy;  /* Validated capture rate for every display. */
    rfbBool viewOnly;            /* TRUE = accept clients but ignore input. */
    int displayNumber;           /* -2 = all displays, -1 = primary, >=0 = one. */
    const char *listenAddress;   /* IPv4 bind address; NULL/empty = all. */
    const char *allowedClients;  /* IPv4/CIDR allowlist; meaning per access mode. */
    MacVNCClientAccessMode clientAccessMode;
} MacVNCServerConfig;

/* -----------------------------------------------------------------------
 * Live statistics (updated atomically from LibVNCServer threads).
 * ----------------------------------------------------------------------- */

/* Number of VNC clients currently connected. */
extern _Atomic int vncConnectedClients;

/*
 * The narrower count: authenticated clients past the first-frame wait,
 * therefore RECEIVING UPDATES - the only count curtain mode may act on.
 * Moves when the wait ENDS, not when it SUCCEEDS (a deliberate choice - see
 * ARCHITECTURE.md § Key seams, macVNCAuthenticatedClientsChangedHandler).
 * Read this rather than the notification below when the question is "is
 * anybody watching right now": it is level-triggered, the notification is
 * only a prompt to look again.
 */
extern _Atomic int vncAuthenticatedClientsReceivingUpdates;

/* Optional handler invoked when screen capture cannot proceed, e.g. Screen
 * Recording is not effectively granted or ScreenCaptureKit failed at runtime.
 * The server shows no UI itself; AppDelegate owns the permission popup.
 *
 * THREAD: any. Raised from the ScreenCaptureKit error queue AND from a client
 * thread when a connection is refused for lack of permission. The handler must
 * therefore hop to the main queue itself (AppDelegate does, via
 * performSelectorOnMainThread:). An earlier version of this comment promised
 * "on the main queue", which was not true of every call site. */
/* likelyPermissionDenial is TRUE only when the underlying error is consistent
 * with a TCC/Screen-Recording denial. Other capture failures (display removed,
 * stream stopped for unrelated reasons) pass FALSE so the caller does not latch
 * a permanent "permission missing" state on a transient/topology error.
 *
 * serverGeneration answers "is the run that raised this still live" (a stale
 * report from a since-stopped/restarted server must never act); captureGeneration
 * answers "which capture attempt" (see gCaptureSessionGeneration) and is what
 * the caller must latch on to decide whether THIS failure was already acted
 * on - the two are orthogonal, see macVNCShouldActOnCaptureFailure. */
extern void (*macVNCScreenCaptureFailureHandler)(bool likelyPermissionDenial,
                                                 uint64_t serverGeneration,
                                                 uint64_t captureGeneration);

/*
 * Optional handler invoked whenever `vncAuthenticatedClientsReceivingUpdates`
 * may have changed. Carries no count on purpose: two notifications raised on
 * client threads could arrive out of order and invent a connect that never
 * happened, so the handler re-reads the atomic count itself - see
 * ARCHITECTURE.md § Key seams for the full reasoning.
 *
 * THREAD: any, including with the server lifecycle lock held. The handler
 * must not block and must not call back into the server core.
 */
extern void (*macVNCAuthenticatedClientsChangedHandler)(void);

/*
 * The password the RUNNING server authenticates against, whatever it was
 * configured from - Preferences or MACVNC_PASSWORD_FILE. Curtain mode's way
 * back in must be armed with THAT secret and no other. Writes it into
 * `buffer` NUL-terminated and returns its length; 0 if not running or if it
 * would not fit (refused, never truncated - a truncated secret is a
 * DIFFERENT secret).
 */
size_t vncServerCopyPassword(char *buffer, size_t size);


/*
 * Answers "may we touch screen capture right now?". Injected by the owner of
 * permission policy (AppDelegate) so the core never asks macOS for TCC
 * itself - touching capture without it is what raises the system's own
 * recording-permission dialog. Must not prompt; safe from a client thread.
 * NULL means "unrestricted" (unit tests, embedders without a permission
 * model).
 */
extern bool (*macVNCCaptureAllowed)(void);

/*
 * Monotonic id of the current server run, incremented by every start.
 * A capture-failure notification carries the generation it was raised for, so a
 * notification queued by an already-stopped run (e.g. delivered after a modal
 * finishes) can be discarded instead of killing a freshly started server.
 *
 * The stamp is read when the notification is RAISED and compared when it is
 * HANDLED on the main queue, so it can only filter out notifications from a run
 * that had already ended by then — which is exactly its purpose. It is not a
 * lock: a start that lands between the two points is handled by the handler
 * re-checking live state.
 */
uint64_t vncServerCurrentGeneration(void);

/* -----------------------------------------------------------------------
 * Server lifecycle
 * ----------------------------------------------------------------------- */

/*
 * Outcome of a start attempt. "Already running" must be distinguishable from a
 * genuine failure: reporting it as one made the UI advise the user to change the
 * port while the server was in fact serving on the current one.
 */
typedef enum {
    MacVNCServerStartOK = 0,
    /* A run is already live; nothing was changed. */
    MacVNCServerStartAlreadyRunning,
    /* Bad configuration, no displays, bind refused, out of memory, ... */
    MacVNCServerStartFailed,
} MacVNCServerStartResult;

/*
 * Initialise and start the VNC server from an immutable configuration.
 * config->password must be non-empty (authentication is mandatory); a NULL
 * or empty password makes this fail.
 *
 * On failure the reason is printed via rfbLog().
 * Must not be called on the main thread because rfbInitServer() briefly
 * blocks while binding the listen socket.
 */
MacVNCServerStartResult vncServerStartWithResult(const MacVNCServerConfig *config);

/* Convenience wrapper: TRUE only for MacVNCServerStartOK. */
rfbBool vncServerStart(const MacVNCServerConfig *config);

/*
 * Disconnect all clients, stop the server and free all resources.
 * Safe to call from any thread.
 */
void vncServerStop(void);

/*
 * Drop the running captures WITHOUT touching the listener, and let the
 * reconciler rebuild them if anyone is still watching.
 *
 * The recovery for a capture failure that is not fatal. Stopping the whole
 * server was the old answer, and for a remote-access tool it is the most
 * expensive one available: the offered recovery lives in a menu bar the remote
 * user cannot reach.
 */
void vncServerDropCaptures(void);

/*
 * Close the listening sockets without a full stop, freeing the port. Used
 * immediately before relaunching: a still-open listener makes the successor's
 * bind() fail. Deliberately NOT vncServerStop(): that joins client threads
 * and waits for in-flight capture work, which can sit behind a system
 * prompt and would freeze the menu bar at the moment the user pressed
 * Restart. Takes the lifecycle lock with a bounded retry, never a blocking
 * wait, and logs if it cannot get it.
 */
void vncServerCloseListeners(void);

/*
 * Told that macOS posted NSApplicationDidChangeScreenParametersNotification -
 * call this from AppDelegate's observer, unconditionally, on any thread.
 * A no-op unless a client is connected (idle is covered by the next
 * connect). Otherwise debounces, then rebuilds ONLY if the desk actually
 * changed shape, reusing rearmCaptures() in mac.m rather than duplicating
 * it. Never wakes a display, never restarts the server or touches the
 * listener/auth. Closes the one gap the capture-liveness watchdog cannot -
 * see ARCHITECTURE.md § CaptureLiveness (FIX-D).
 */
void vncServerNoteDeskShapeMayHaveChanged(void);

/*
 * Return the TCP port the server is listening on.
 *
 * <= 0 means "not serving": -1 before a run has ever started or after a stop,
 * and 0 once vncServerCloseListeners() has freed the port for a successor.
 * Callers must test for > 0, never for != -1.
 */
int vncServerGetPort(void);

/*
 * Report the configuration the RUNNING server actually applied, so the UI can
 * never claim a restriction that is not in effect (saved defaults and env
 * overrides can differ from the live server until it is restarted).
 *
 * bindAddress receives the bound IPv4 address, or an empty string when the
 * server listens on all interfaces. Returns FALSE (and writes nothing) when
 * the server is not running.
 */
rfbBool vncServerCopyActiveBindAddress(char *bindAddress, size_t size);


/*
 * TRUE when the RUNNING server's effective policy admits every IPv4 client —
 * either an explicitly confirmed allow-all, or an allowlist that contains a /0
 * entry (which matches everyone). The UI must use this rather than inferring
 * "allowlist" from the mode, or it would report a restriction that is not real.
 */
rfbBool vncServerActivePolicyAllowsEveryone(void);

#if defined(MACVNC_ENABLE_TEST_HOOKS)
#include <stdbool.h>
/* Exposes the core's own capture decision so the "no permission, no capture"
   rule can be asserted without a real TCC grant. */
bool macVNCCaptureIsAllowedForTesting(void);

/* Number of times the core actually started the capture streams. Lets a test
   assert that a refused permission produces NO start, rather than only that the
   gate returned false. */
unsigned macVNCCaptureStartCountForTesting(void);

/* How many times the reconciler STOPPED captures (last client left). Pins the
   other half of "captures run iff vncConnectedClients > 0": without a witness
   for this direction, deleting the stop branch entirely leaves every target
   green with captures running forever after the last viewer disconnects. */
unsigned macVNCCaptureStopCountForTesting(void);
/* Override the keep-warm window (nanoseconds) for tests. */
void macVNCSetCaptureKeepWarmForTesting(uint64_t ns);

/* macVNCCaptureRearmCountForTesting/macVNCCaptureRearmFailureCountForTesting/
   macVNCCaptureGiveUpCountForTesting/macVNCLastFrameTimestampForTesting/
   macVNCSetCaptureLivenessLimitsForTesting/macVNCSetDeskShapeDebounceForTesting/
   macVNCDeskShapeRecheckCountForTesting/macVNCForceDeskShapeDifferentForTesting/
   macVNCDeskShapeRebuildCountForTesting/macVNCDeskShapeRebuildFailureCountForTesting
   moved to MacVNCCaptureSupervisor.h (.pi/plans/core-decomposition.md, step
   8) with the watchdog/desk-shape state they read - #include that header,
   not this one, for any of them. */

/*
 * Feeds one synthetic, correctly-sized (zeroed) frame for displayIndex
 * directly through the real compositeCapturedFrame, carrying generation -
 * bypassing ScreenCaptureKit entirely. This is the only way to prove the
 * generation-rejection rule deterministically: a genuinely retired-session
 * frame requires provoking an actual ScreenCaptureKit race, which is neither
 * reproducible on demand nor available at all without a Screen Recording
 * grant. Looks up displayIndex's real pixel size off the CURRENTLY
 * published layout itself, so a mismatched generation is the only reason a
 * test's frame can be rejected - never an incidental size mismatch. A no-op
 * (nothing observable happens) if displayIndex is not in the current layout.
 */
void macVNCCompositeSyntheticFrameForTesting(uint64_t generation, size_t displayIndex);

/* How many displays the CURRENTLY published layout has - lets a multi-display
   test SKIP honestly on a box that only has one. */
size_t macVNCCurrentDisplayLayoutCountForTesting(void);

/* F1 test hooks - see gPinnedDisplayID's own comment in mac.m. */
/* The CURRENTLY pinned display id (0 = not pinned yet, or displayNumber < 0
   never pins one), so a test can assert it is set exactly once per resolve
   and never silently replaced by a different physical display. */
uint32_t macVNCPinnedDisplayIDForTesting(void);
/* Forces the pinned-id lookup to genuinely MISS, as if the pinned display had
   just been unplugged, without physically removing a monitor - by
   substituting an impossible id into the value macVNCSelectDisplayByID()
   searches for, not by short-circuiting the search itself. */
void macVNCForcePinnedDisplayGoneForTesting(bool force);

void macVNCResetCaptureStateForTesting(void);
/* Runs the real start/stop reconciler for the current client count. */
void macVNCReconcileCaptureForTesting(void);

bool macVNCServerHasLifecycleResourcesForTesting(void);

/*
 * A synthetic client, for the ONE window that has no other way of being
 * observed: between "authenticated" and "receiving updates" there is a wait
 * of up to INITIAL_READINESS_TIMEOUT_NANOSECONDS, and what the two counters
 * do inside it is what curtain mode depends on. `-BeginClientForTesting(false)`
 * is a client still inside that wait; `-ReceivedFirstFrames` ends it; `-End`
 * is the disconnect - all three run the same bookkeeping the real client
 * paths run. Handle is opaque, freed by `-EndClientForTesting()`.
 */
void *macVNCBeginClientForTesting(bool receivingUpdates);
void macVNCClientReceivedFirstFramesForTesting(void *client);
void macVNCEndClientForTesting(void *client);
#endif
