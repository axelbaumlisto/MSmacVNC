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
 * The narrower count: authenticated clients that are past the first-frame wait
 * and therefore RECEIVING UPDATES.
 *
 * Two counters exist because the two answers are wanted at different moments.
 * `vncConnectedClients` moves the instant a password is accepted, because that
 * is what has to start the captures that produce the first frame. This one
 * moves only after the first-frame wait has ENDED, which is the only count
 * curtain mode may act on: a curtain raised on the earlier number would hide
 * the local screen for up to the readiness timeout while the remote viewer was
 * still looking at a placeholder.
 *
 * "ENDED", NOT "SUCCEEDED", AND THAT IS A DECISION. When the wait times out
 * (INITIAL_READINESS_TIMEOUT_NANOSECONDS, currently 8 s) the client is counted
 * anyway, so a curtain can go up over a viewer that is still holding a
 * placeholder - the same failure shape as counting at password-accept time,
 * bounded to that timeout. The alternative was worse: gating on success would
 * silently disable curtain mode for every viewer whose displays are merely
 * SLOW rather than broken, and the timeout is a ceiling that a healthy warm
 * reconnect never reaches. The genuinely broken case is covered from the other
 * side - the controller re-checks that a capture stream is live on every
 * event and on its heartbeat, and lifts when it is not.
 *
 * Read it rather than the notification below when the question is "is anybody
 * watching right now": the reader is level-triggered, so the notification is
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
 * may have changed: after a client's first frames are ready (not merely after
 * its password was accepted), after one disconnects, and after a stop zeroes
 * the count.
 *
 * It carries no count on purpose. Notifications are raised on client threads
 * and the handler is expected to hop to its own queue, where two of them could
 * otherwise arrive in the opposite order to the events that raised them and
 * invent a connect that never happened. `vncAuthenticatedClientsReceivingUpdates`
 * is atomic and is the authoritative answer at the moment the handler reads
 * it, so the notification says only "look again".
 *
 * THREAD: any, including with the server lifecycle lock held. The handler must
 * therefore not block and must not call back into the server core.
 */
extern void (*macVNCAuthenticatedClientsChangedHandler)(void);

/*
 * The password the RUNNING server actually authenticates against, whatever it
 * was configured from - Preferences or MACVNC_PASSWORD_FILE.
 *
 * Exists because curtain mode's way back in must be armed with THAT secret and
 * no other: a curtain raised against one password and unlockable with another
 * is a lockout, and only the core knows which one is installed right now.
 *
 * Writes the password into `buffer` NUL-terminated and returns its length. A
 * server that is not running has none (0). A password that would not fit is
 * refused with 0 rather than truncated, because a truncated secret is a
 * DIFFERENT secret and would arm an escape hatch that does not open.
 */
size_t vncServerCopyPassword(char *buffer, size_t size);


/*
 * Answers "may we touch screen capture right now?".
 *
 * Injected by the owner of permission policy (AppDelegate) so the server core
 * holds no opinion about TCC: the core must never be the thing that asks macOS
 * for a permission, because touching capture without it is exactly what makes
 * the system raise its own "macVNC wants to record this screen" dialog - the
 * one dialog this app must never cause.
 *
 * Must not prompt and must be safe to call from a client thread. NULL means
 * "unrestricted", which is what unit tests and any embedder without a
 * permission model want.
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
 * Close the listening sockets without a full stop, freeing the port.
 *
 * Used immediately before relaunching: the successor inherits descriptors, and
 * a still-open listener makes its bind() fail. Both the IPv4 and IPv6 listeners
 * are closed and the published port is zeroed, so the UI stops advertising a
 * dead socket.
 *
 * Deliberately NOT vncServerStop(): that joins client threads and waits for
 * in-flight capture work, which can sit behind a system prompt and would freeze
 * the menu bar at the moment the user pressed Restart.
 *
 * Takes the lifecycle lock with a bounded retry, never a blocking wait, and
 * logs if it cannot get it — a concurrent start would otherwise reopen the
 * listener after this returns.
 */
void vncServerCloseListeners(void);

/*
 * Told that macOS posted NSApplicationDidChangeScreenParametersNotification -
 * call this from AppDelegate's observer, unconditionally, on any thread
 * (main, per the notification's own delivery).
 *
 * A no-op unless a client is currently connected: a change while idle is
 * already covered by the next connect reading the desk fresh. Otherwise
 * debounces (real reconfigurations fire this several times as the desk
 * settles) and, once settled, rebuilds the composite canvas ONLY if the
 * desk actually changed shape - see rearmCaptures() in mac.m, which this
 * reuses rather than duplicating. Never wakes a display, never restarts the
 * server, never touches the listener or auth: on failure the existing
 * capture-failure path (reportCaptureFailure) is what runs, same as every
 * other re-arm trigger.
 *
 * Closes the one gap the capture-liveness watchdog cannot: a display that is
 * RESIZED rather than silenced keeps delivering frames (SCStreamConfiguration
 * pins width/height at Build time), so nothing about a mid-session
 * reconfiguration looks like silence - measured on the installed build,
 * where it produced zero re-arms and a canvas stuck at the pre-change size
 * while frames kept flowing. See .pi/plans/capture-liveness.md (FIX-D).
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

/* How many times the liveness watchdog re-armed a silently dead capture
   stream - one that stopped delivering frames without an SCStream error to
   react to. See CaptureLiveness.h for why silence itself is the signal. */
unsigned macVNCCaptureRearmCountForTesting(void);

/* How many times a re-arm ATTEMPT failed (rearmCaptures() itself returned
   false) - as opposed to macVNCCaptureRearmCountForTesting(), which only
   counts successes. A post-audit fix ("FIX-A"/F1) made a failed attempt count
   toward maxRearms too, so GiveUp is reachable instead of retrying at 1Hz
   forever; this is the witness that the FAILURE branch's bookkeeping actually
   runs, not just the success branch's. */
unsigned macVNCCaptureRearmFailureCountForTesting(void);

/* How many times the watchdog resolved GiveUp (maxRearms failed attempts with
   no recovering frame) and reported a capture failure because of it. Without
   this a test can only infer GiveUp happened by an absence (no further
   re-arms), which is indistinguishable from "the test did not wait long
   enough". */
unsigned macVNCCaptureGiveUpCountForTesting(void);

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

/* The CURRENT capture-session generation, so a test can compute the prior
   generation without reaching into a private counter by name. */
uint64_t macVNCCurrentCaptureGenerationForTesting(void);

/* The per-display liveness timestamp gLastFrameNs holds, so a test can prove
   a rejected synthetic frame left it untouched rather than merely hoping a
   non-observable return value implies it. 0 = never stamped, same sentinel
   convention as the production field this reads. */
uint64_t macVNCLastFrameTimestampForTesting(size_t displayIndex);
/* How many displays the CURRENTLY published layout has - lets a multi-display
   test SKIP honestly on a box that only has one. */
size_t macVNCCurrentDisplayLayoutCountForTesting(void);
/* Shrinks the watchdog's grace/silence/cooldown windows (nanoseconds; 0 keeps
   the shipped default) so an e2e run can force a re-arm in seconds instead of
   the shipped ~35s. maxRearms is not overridable - see the definition site. */
void macVNCSetCaptureLivenessLimitsForTesting(uint64_t graceNs, uint64_t silenceNs,
                                              uint64_t cooldownNs);

/* FIX-D test hooks - see vncServerNoteDeskShapeMayHaveChanged() above. */
/* Overrides the debounce window (nanoseconds; 0 keeps the shipped 500ms), so
   a test can observe a SECOND, separate firing within a bounded budget. */
void macVNCSetDeskShapeDebounceForTesting(uint64_t ns);
/* How many times the debounced recheck actually ran, regardless of what it
   decided - the number that lets a test tell "a burst of N notifications
   produced ONE evaluation" from "produced N". */
unsigned macVNCDeskShapeRecheckCountForTesting(void);
/* Forces the next recheck(s) to treat the freshly re-read desk as different
   from the published layout, without needing to fake a MacVNCDisplayLayout
   or physically reconfigure a display - the rebuild that follows is still a
   real, unmocked rearmCaptures() call. */
void macVNCForceDeskShapeDifferentForTesting(bool force);
/* How many times a shape-driven rearm SUCCEEDED / FAILED, counted separately
   from macVNCCaptureRearmCountForTesting() - see evaluateDeskShapeForRearm's
   comment in mac.m for why the two triggers do not share a counter. */
unsigned macVNCDeskShapeRebuildCountForTesting(void);
unsigned macVNCDeskShapeRebuildFailureCountForTesting(void);

/* F1 test hooks - see gPinnedDisplayID's own comment in mac.m. */
/* The CURRENTLY pinned display id (0 = not pinned yet, or displayNumber < 0
   never pins one), so a test can assert it is set exactly once per resolve
   and never silently replaced by a different physical display. */
uint32_t macVNCPinnedDisplayIDForTesting(void);
/* Forces the pinned-id lookup to fail as if the pinned display had just been
   unplugged, without physically removing a monitor. */
void macVNCForcePinnedDisplayGoneForTesting(bool force);

void macVNCResetCaptureStateForTesting(void);
/* Runs the real start/stop reconciler for the current client count. */
void macVNCReconcileCaptureForTesting(void);

bool macVNCServerHasLifecycleResourcesForTesting(void);

/*
 * A synthetic client, for the ONE window that has no other way of being
 * observed: between "this client authenticated" and "this client is receiving
 * updates" there is a wait of up to INITIAL_READINESS_TIMEOUT_NANOSECONDS, and
 * what the two counters do inside it is exactly what curtain mode depends on.
 *
 * `macVNCBeginClientForTesting(false)` is a client still inside that wait;
 * -ReceivedFirstFrames ends it; -End is the disconnect. All three run the same
 * bookkeeping the real client paths run, so deleting a rule there cannot leave
 * a test asserting against a private copy of it.
 *
 * The returned handle is opaque and is freed by macVNCEndClientForTesting().
 * No capture reconciliation happens, so none of this needs a display.
 */
void *macVNCBeginClientForTesting(bool receivingUpdates);
void macVNCClientReceivedFirstFramesForTesting(void *client);
void macVNCEndClientForTesting(void *client);
#endif
