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

bool
macVNCIPv4IsPrivate(const char *address)
{
    uint32_t ip = 0;
    if (!macVNCParseIPv4(address, &ip))
        return false;
    if ((ip & 0xff000000u) == 0x0a000000u)   /* 10.0.0.0/8     */
        return true;
    if ((ip & 0xfff00000u) == 0xac100000u)   /* 172.16.0.0/12  */
        return true;
    if ((ip & 0xffff0000u) == 0xc0a80000u)   /* 192.168.0.0/16 */
        return true;
    return false;
}

bool
macVNCIPv4Surrounding24(const char *address, char *out, size_t outSize)
{
    uint32_t ip = 0;
    if (!address || !out || outSize == 0 || !macVNCParseIPv4(address, &ip))
        return false;
    uint32_t network = ip & 0xffffff00u;
    int written = snprintf(out, outSize, "%u.%u.%u.0/24",
                           (network >> 24) & 0xffu, (network >> 16) & 0xffu,
                           (network >> 8) & 0xffu);
    return written > 0 && (size_t)written < outSize;
}
