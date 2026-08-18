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
    bool active;
    bool selectable;
    bool allowPresetVisible;
    bool cgnatLike;
} MacVNCNetworkInterfaceRow;

bool macVNCBuildNetworkInterfaceRow(const MacVNCNetworkInterfaceSnapshot *snapshot,
                                    MacVNCNetworkInterfaceRow *row);
