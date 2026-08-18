#pragma once

#include <rfb/rfb.h>
#include <stdatomic.h>
#include "NetworkPolicyResolver.h"

/* -----------------------------------------------------------------------
 * Globals that AppDelegate may read or write before calling vncServerStart().
 * ----------------------------------------------------------------------- */

/* When TRUE the server accepts connections but ignores all input events. */
extern rfbBool viewOnly;

/* Index of the display to share (-1 = primary). */
extern int displayNumber;

#define MACVNC_LISTEN_ADDRESS_MAX 64
#define MACVNC_ALLOWED_CLIENTS_MAX 4096

/* Optional IPv4 bind address. Empty means all interfaces. */
extern char macVNCListenAddress[MACVNC_LISTEN_ADDRESS_MAX];

/* Optional IPv4/CIDR client allowlist. Interpretation depends on access mode. */
extern char macVNCAllowedClients[MACVNC_ALLOWED_CLIENTS_MAX];
extern MacVNCClientAccessMode macVNCClientAccessMode;

/* -----------------------------------------------------------------------
 * Live statistics (updated atomically from LibVNCServer threads).
 * ----------------------------------------------------------------------- */

/* Number of VNC clients currently connected. */
extern _Atomic int vncConnectedClients;

/* -----------------------------------------------------------------------
 * Server lifecycle
 * ----------------------------------------------------------------------- */

/*
 * Initialise and start the VNC server.
 *
 * port     – TCP port to listen on (5900 is the VNC default).
 * password – Shared password string, or NULL to disable authentication.
 * captureFramesPerSecond – Validated immutable capture rate for every display.
 *
 * Returns TRUE on success. On failure the reason is printed via rfbLog().
 * Must not be called on the main thread because rfbInitServer() briefly
 * blocks while binding the listen socket.
 */
rfbBool vncServerStart(int port, const char *password, int captureFramesPerSecond);

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
