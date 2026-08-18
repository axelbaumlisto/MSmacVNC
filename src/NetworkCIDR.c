#include "NetworkCIDR.h"
#include "NetworkAccess.h"

#include <stdio.h>

static bool
maskPrefixLength(uint32_t mask, unsigned *prefixLength)
{
    bool sawZero = false;
    unsigned prefix = 0;
    for (int bit = 31; bit >= 0; --bit) {
        bool one = (mask & (1u << bit)) != 0;
        if (one) {
            if (sawZero)
                return false;
            ++prefix;
        } else {
            sawZero = true;
        }
    }
    if (prefixLength)
        *prefixLength = prefix;
    return true;
}

bool
macVNCNetworkCIDRFromAddressAndMask(const char *address,
                                    const char *netmask,
                                    char *out,
                                    size_t outSize)
{
    uint32_t ip = 0;
    uint32_t mask = 0;
    unsigned prefix = 0;
    if (!out || outSize == 0)
        return false;
    out[0] = '\0';
    if (!macVNCParseIPv4(address, &ip) || !macVNCParseIPv4(netmask, &mask))
        return false;
    if (!maskPrefixLength(mask, &prefix))
        return false;

    uint32_t network = ip & mask;
    unsigned a = (network >> 24) & 0xffu;
    unsigned b = (network >> 16) & 0xffu;
    unsigned c = (network >> 8) & 0xffu;
    unsigned d = network & 0xffu;
    int written = snprintf(out, outSize, "%u.%u.%u.%u/%u", a, b, c, d, prefix);
    return written > 0 && (size_t)written < outSize;
}

bool
macVNCIPv4IsCGNAT(const char *address)
{
    uint32_t ip = 0;
    if (!macVNCParseIPv4(address, &ip))
        return false;
    return (ip & 0xffc00000u) == 0x64400000u; /* 100.64.0.0/10 */
}
