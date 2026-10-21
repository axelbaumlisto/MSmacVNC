#pragma once

#include <stdbool.h>
#include <stddef.h>

#define MACVNC_NETWORK_ROW_TEXT_MAX 64

typedef struct {
    const char *name;
    bool active;
    const char *address;
    const char *netmask;
} MacVNCNetworkInterfaceSnapshot;

typedef struct {
    char name[MACVNC_NETWORK_ROW_TEXT_MAX];
    char address[MACVNC_NETWORK_ROW_TEXT_MAX];
    char cidr[MACVNC_NETWORK_ROW_TEXT_MAX];
    char suggestedAllowCIDR[MACVNC_NETWORK_ROW_TEXT_MAX];
    char displayName[MACVNC_NETWORK_ROW_TEXT_MAX];
    unsigned prefixLength;
    bool active;
    bool selectable;
    bool allowPresetVisible;
    bool cgnatLike;
    /* Point-to-point private tunnel (utunN /32): WireGuard-family VPN such as
     * AmneziaWG. Its peers live on the enclosing /24, not on this /32. */
    bool vpnLike;
} MacVNCNetworkInterfaceRow;

bool macVNCBuildNetworkInterfaceRow(const MacVNCNetworkInterfaceSnapshot *snapshot,
                                    MacVNCNetworkInterfaceRow *row);
