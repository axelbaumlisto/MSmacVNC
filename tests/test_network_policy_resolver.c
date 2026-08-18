#include "NetworkPolicyResolver.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #expr); exit(1); } } while (0)
#define CHECK_STR(actual, expected) do { if (strcmp((actual), (expected)) != 0) { fprintf(stderr, "FAIL %s:%d: got '%s' expected '%s'\n", __FILE__, __LINE__, (actual), (expected)); exit(1); } } while (0)

static MacVNCResolvedPolicy resolveOK(MacVNCPolicyInput input, MacVNCPolicyEnv env)
{
    MacVNCResolvedPolicy out;
    CHECK(macVNCResolveNetworkPolicy(&input, &env, &out));
    CHECK(out.error[0] == '\0');
    return out;
}

static void resolveBad(MacVNCPolicyInput input, MacVNCPolicyEnv env)
{
    MacVNCResolvedPolicy out;
    CHECK(!macVNCResolveNetworkPolicy(&input, &env, &out));
    CHECK(out.error[0] != '\0');
}

int main(void)
{
    MacVNCPolicyEnv noEnv = {0};
    MacVNCResolvedPolicy out;

    out = resolveOK((MacVNCPolicyInput){"localhost", "", "127.0.0.1", false}, noEnv);
    CHECK_STR(out.bindAddress, "127.0.0.1");
    CHECK_STR(out.allowedClients, "127.0.0.1");
    CHECK(out.accessMode == MACVNC_CLIENT_ACCESS_ALLOW_LIST);

    out = resolveOK((MacVNCPolicyInput){"custom", "100.70.214.41", "100.64.0.0/10", false}, noEnv);
    CHECK_STR(out.bindAddress, "100.70.214.41");
    CHECK_STR(out.allowedClients, "100.64.0.0/10");

    out = resolveOK((MacVNCPolicyInput){"all", "", "", true}, noEnv);
    CHECK_STR(out.bindAddress, "");
    CHECK_STR(out.allowedClients, "");
    CHECK(out.accessMode == MACVNC_CLIENT_ACCESS_ALLOW_ALL_CONFIRMED);

    resolveBad((MacVNCPolicyInput){"all", "", "", false}, noEnv);
    resolveBad((MacVNCPolicyInput){"unknown", "", "127.0.0.1", false}, noEnv);
    resolveBad((MacVNCPolicyInput){"custom", "", "127.0.0.1", false}, noEnv);
    resolveBad((MacVNCPolicyInput){"custom", "host", "127.0.0.1", false}, noEnv);
    resolveBad((MacVNCPolicyInput){"localhost", "", "bad-cidr", false}, noEnv);

    out = resolveOK((MacVNCPolicyInput){"localhost", "", "192.168.1.0/24", false},
                    (MacVNCPolicyEnv){"100.70.214.41", NULL, false});
    CHECK(out.envOverrideActive);
    CHECK_STR(out.bindAddress, "100.70.214.41");
    CHECK_STR(out.allowedClients, "192.168.1.0/24");

    out = resolveOK((MacVNCPolicyInput){"localhost", "", "192.168.1.0/24", false},
                    (MacVNCPolicyEnv){NULL, "100.64.0.0/10", true});
    CHECK(out.envOverrideActive);
    CHECK_STR(out.allowedClients, "100.64.0.0/10");

    out = resolveOK((MacVNCPolicyInput){"localhost", "", "192.168.1.0/24", false},
                    (MacVNCPolicyEnv){NULL, "", true});
    CHECK(out.envOverrideActive);
    CHECK_STR(out.allowedClients, "192.168.1.0/24");

    resolveBad((MacVNCPolicyInput){"localhost", "", "192.168.1.0/24", false},
               (MacVNCPolicyEnv){"bad", NULL, false});
    resolveBad((MacVNCPolicyInput){"localhost", "", "192.168.1.0/24", false},
               (MacVNCPolicyEnv){NULL, "bad", true});

    char longAddress[MACVNC_POLICY_BIND_ADDRESS_MAX + 8];
    memset(longAddress, '1', sizeof(longAddress) - 1);
    longAddress[sizeof(longAddress) - 1] = '\0';
    resolveBad((MacVNCPolicyInput){"custom", longAddress, "127.0.0.1", false}, noEnv);

    puts("network policy resolver tests passed");
    return 0;
}
