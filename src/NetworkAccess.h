#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define MACVNC_NETWORK_ACCESS_MAX_ENTRIES 64

typedef struct {
    uint32_t network;
    uint32_t mask;
    unsigned prefixLength;
} MacVNCIPv4CIDR;

typedef struct {
    MacVNCIPv4CIDR entries[MACVNC_NETWORK_ACCESS_MAX_ENTRIES];
    size_t count;
} MacVNCNetworkAccessList;

bool macVNCParseIPv4(const char *text, uint32_t *outHostOrder);
bool macVNCParseCIDR(const char *text, MacVNCIPv4CIDR *out);
bool macVNCParseAccessList(const char *text,
                           MacVNCNetworkAccessList *out,
                           char *error,
                           size_t errorSize);
bool macVNCNetworkAccessAllows(const MacVNCNetworkAccessList *list,
                               const char *clientHost);

bool macVNCNetworkAccessContainsAllowAll(const MacVNCNetworkAccessList *list);

/* Is this IPv4 address currently assigned to one of our interfaces?
 * The single implementation of that question: a syntactically valid address
 * whose network is gone (Wi-Fi off, VPN down, DHCP change) would otherwise
 * surface later as a generic bind failure phrased like a port collision. */
bool macVNCIPv4IsAssignedToInterface(uint32_t hostOrderAddress);
