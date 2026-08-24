#include "NetworkPolicyResolver.h"
#include "NetworkAccess.h"
#include "MacVNCListenModeNames.h"

#include <stdio.h>
#include <string.h>

static bool
isEmpty(const char *value)
{
    return !value || !*value;
}

static void
setError(MacVNCResolvedPolicy *out, const char *message)
{
    if (out)
        snprintf(out->error, sizeof(out->error), "%s", message ? message : "network policy error");
}

static bool
copyString(char *dest, size_t destSize, const char *source,
           MacVNCResolvedPolicy *out, const char *tooLongMessage)
{
    if (!source)
        source = "";
    size_t length = strlen(source);
    if (length >= destSize) {
        setError(out, tooLongMessage);
        return false;
    }
    memcpy(dest, source, length + 1);
    return true;
}

bool
macVNCResolveNetworkPolicy(const MacVNCPolicyInput *input,
                           const MacVNCPolicyEnv *env,
                           MacVNCResolvedPolicy *out)
{
    if (!input || !out)
        return false;
    memset(out, 0, sizeof(*out));
    out->accessMode = MACVNC_CLIENT_ACCESS_FAIL_CLOSED;

    const char *mode = input->listenMode;
    if (isEmpty(mode)) {
        setError(out, "listen mode is missing");
        return false;
    }

    const char *bind = "";
    if (strcmp(mode, MACVNC_LISTEN_MODE_ALL) == 0) {
        bind = "";
    } else if (strcmp(mode, MACVNC_LISTEN_MODE_LOCALHOST) == 0) {
        bind = MACVNC_LOOPBACK_IPV4;
    } else if (strcmp(mode, MACVNC_LISTEN_MODE_CUSTOM) == 0 ||
               strcmp(mode, MACVNC_LISTEN_MODE_SELECTED) == 0) {
        bind = input->listenAddress;
        if (isEmpty(bind)) {
            setError(out, "selected listen address is missing");
            return false;
        }
        if (!macVNCParseIPv4(bind, NULL)) {
            setError(out, "selected listen address is not IPv4");
            return false;
        }
    } else {
        setError(out, "unknown listen mode");
        return false;
    }

    if (env && !isEmpty(env->listenAddress)) {
        if (!macVNCParseIPv4(env->listenAddress, NULL)) {
            setError(out, "MACVNC_LISTEN is not IPv4");
            return false;
        }
        bind = env->listenAddress;
        out->envOverrideActive = true;
    }
    if (!copyString(out->bindAddress, sizeof(out->bindAddress), bind,
                    out, "listen address is too long"))
        return false;

    const char *allow = input->allowedClients;
    bool envAllowedPresent = env && env->hasAllowedClients;
    if (envAllowedPresent) {
        out->envOverrideActive = true;
        if (!isEmpty(env->allowedClients))
            allow = env->allowedClients;
        /* Empty env allowlist is ignored so it cannot clear GUI policy. */
    }

    MacVNCNetworkAccessList parsed;
    char parseError[128] = {0};
    if (!isEmpty(allow)) {
        if (!copyString(out->allowedClients, sizeof(out->allowedClients), allow,
                        out, "allowed clients list is too long"))
            return false;
        if (!macVNCParseAccessList(out->allowedClients, &parsed,
                                   parseError, sizeof(parseError))) {
            snprintf(out->error, sizeof(out->error), "invalid allowed clients: %s", parseError);
            return false;
        }
        if (parsed.count == 0) {
            setError(out, "allowed clients list is empty");
            return false;
        }
        out->accessMode = MACVNC_CLIENT_ACCESS_ALLOW_LIST;
        return true;
    }

    if (input->allowAllConfirmed) {
        out->allowedClients[0] = '\0';
        out->accessMode = MACVNC_CLIENT_ACCESS_ALLOW_ALL_CONFIRMED;
        return true;
    }

    setError(out, "allowed clients required unless allow-all is confirmed");
    return false;
}
