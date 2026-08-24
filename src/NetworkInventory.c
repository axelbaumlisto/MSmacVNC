#include "NetworkInventory.h"
#include "NetworkCIDR.h"
#include "NetworkAccess.h"
#include "MacVNCListenModeNames.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void
copyText(char *dest, size_t destSize, const char *source)
{
    if (!source)
        source = "";
    snprintf(dest, destSize, "%s", source);
}

static bool
isHiddenAllowPresetInterface(const char *name)
{
    return !name ||
           strcmp(name, "lo0") == 0 ||
           strncmp(name, "bridge", 6) == 0 ||
           strncmp(name, "awdl", 4) == 0 ||
           strncmp(name, "llw", 3) == 0;
}

static bool
isLinkLocalIPv4(const char *address)
{
    uint32_t ip = 0;
    return macVNCParseIPv4(address, &ip) && (ip & 0xffff0000u) == 0xa9fe0000u;
}

bool
macVNCBuildNetworkInterfaceRow(const MacVNCNetworkInterfaceSnapshot *snapshot,
                               MacVNCNetworkInterfaceRow *row)
{
    if (!snapshot || !row)
        return false;
    memset(row, 0, sizeof(*row));
    copyText(row->name, sizeof(row->name), snapshot->name);
    copyText(row->displayName, sizeof(row->displayName), snapshot->name);
    row->active = snapshot->active;

    if (!snapshot->active || !snapshot->address || !snapshot->netmask ||
        !*snapshot->address || !*snapshot->netmask) {
        row->selectable = false;
        return true;
    }

    copyText(row->address, sizeof(row->address), snapshot->address);
    if (!macVNCNetworkCIDRFromAddressAndMask(snapshot->address,
                                             snapshot->netmask,
                                             row->cidr,
                                             sizeof(row->cidr))) {
        row->selectable = false;
        row->cidr[0] = '\0';
        return true;
    }
    row->selectable = true;
    row->cgnatLike = macVNCIPv4IsCGNAT(snapshot->address);
    const char *slash = strrchr(row->cidr, '/');
    row->prefixLength = slash ? (unsigned)atoi(slash + 1) : 32;

    if (row->cgnatLike) {
        snprintf(row->displayName, sizeof(row->displayName),
                 "Tailscale-like (%s)", snapshot->name ? snapshot->name : "network");
        copyText(row->suggestedAllowCIDR, sizeof(row->suggestedAllowCIDR), "100.64.0.0/10");
    } else if (strcmp(snapshot->name ? snapshot->name : "", "lo0") == 0) {
        copyText(row->suggestedAllowCIDR, sizeof(row->suggestedAllowCIDR), MACVNC_LOOPBACK_IPV4 "/32");
    } else {
        copyText(row->suggestedAllowCIDR, sizeof(row->suggestedAllowCIDR), row->cidr);
    }
    row->allowPresetVisible = !isHiddenAllowPresetInterface(snapshot->name) &&
                              !isLinkLocalIPv4(snapshot->address) &&
                              (row->cgnatLike || row->prefixLength < 32);
    return true;
}
