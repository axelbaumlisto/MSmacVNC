#pragma once

#include <stdbool.h>
#include <stddef.h>

#define MACVNC_POLICY_BIND_ADDRESS_MAX 64
#define MACVNC_POLICY_ALLOWED_CLIENTS_MAX 4096
#define MACVNC_POLICY_ERROR_MAX 192

typedef enum {
    MACVNC_CLIENT_ACCESS_FAIL_CLOSED = 0,
    MACVNC_CLIENT_ACCESS_ALLOW_LIST = 1,
    MACVNC_CLIENT_ACCESS_ALLOW_ALL_CONFIRMED = 2,
} MacVNCClientAccessMode;

typedef struct {
    const char *listenMode;       /* all | localhost | custom | selected */
    const char *listenAddress;    /* used by custom/selected */
    const char *allowedClients;   /* manual/resolved allowlist */
    bool allowAllConfirmed;
} MacVNCPolicyInput;

typedef struct {
    const char *listenAddress;          /* optional debug/headless override */
    const char *allowedClients;         /* optional debug/headless override */
    bool hasAllowedClients;             /* distinguishes absent from empty */
} MacVNCPolicyEnv;

typedef struct {
    char bindAddress[MACVNC_POLICY_BIND_ADDRESS_MAX];
    char allowedClients[MACVNC_POLICY_ALLOWED_CLIENTS_MAX];
    MacVNCClientAccessMode accessMode;
    bool envOverrideActive;
    char error[MACVNC_POLICY_ERROR_MAX];
} MacVNCResolvedPolicy;

bool macVNCResolveNetworkPolicy(const MacVNCPolicyInput *input,
                                const MacVNCPolicyEnv *env,
                                MacVNCResolvedPolicy *out);
