#pragma once

#include <rfb/rfb.h>
#include <stdatomic.h>
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
    int captureFramesPerSecond;  /* Validated capture rate for every display. */
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

/* Optional handler invoked (on the main queue) when ScreenCaptureKit fails at
 * runtime, e.g. Screen Recording permission is not effectively granted. The
 * server does not show any UI itself; AppDelegate owns the permission popup. */
/* likelyPermissionDenial is TRUE only when the underlying error is consistent
 * with a TCC/Screen-Recording denial. Other capture failures (display removed,
 * stream stopped for unrelated reasons) pass FALSE so the caller does not latch
 * a permanent "permission missing" state on a transient/topology error. */
extern void (*macVNCScreenCaptureFailureHandler)(bool likelyPermissionDenial);

/* -----------------------------------------------------------------------
 * Server lifecycle
 * ----------------------------------------------------------------------- */

/*
 * Initialise and start the VNC server from an immutable configuration.
 * config->password must be non-empty (authentication is mandatory); a NULL
 * or empty password makes this fail.
 *
 * Returns TRUE on success. On failure the reason is printed via rfbLog().
 * Must not be called on the main thread because rfbInitServer() briefly
 * blocks while binding the listen socket.
 */
rfbBool vncServerStart(const MacVNCServerConfig *config);

/*
 * Disconnect all clients, stop the server and free all resources.
 * Safe to call from any thread.
 */
void vncServerStop(void);

/*
 * Return the TCP port the server is listening on, or -1 if not started.
 */
int vncServerGetPort(void);

#if defined(MACVNC_ENABLE_TEST_HOOKS)
#include <stdbool.h>
bool macVNCServerHasLifecycleResourcesForTesting(void);
#endif
