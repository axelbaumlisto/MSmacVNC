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
    bool cgnatLike;      /* the ADDRESS is CGNAT — says nothing about the preset */
    bool tailnetLike;    /* the broad tailnet preset was applied to this row */
    /* Point-to-point private tunnel (utunN /32): WireGuard-family VPN such as
     * AmneziaWG. Its peers live on the enclosing /24, not on this /32. */
    bool vpnLike;
} MacVNCNetworkInterfaceRow;

bool macVNCBuildNetworkInterfaceRow(const MacVNCNetworkInterfaceSnapshot *snapshot,
                                    MacVNCNetworkInterfaceRow *row);

#define MACVNC_NETWORK_ROW_LABEL_MAX 192

/* What the allowlist checkbox says for this row: the title and the one-line
   summary. Kept out of the Objective-C rows builder so a test can read the
   exact sentences the user will see - the flags were tested, the wording was
   not, and the wording is what tells a tailnet from a VPN from a LAN. */
bool macVNCNetworkRowAllowText(const MacVNCNetworkInterfaceRow *row,
                               char *title, size_t titleSize,
                               char *summary, size_t summarySize);
