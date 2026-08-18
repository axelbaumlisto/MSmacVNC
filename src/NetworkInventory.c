#include "NetworkInventory.h"
#include "NetworkCIDR.h"

#include <stdio.h>
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
    if (row->cgnatLike) {
        snprintf(row->displayName, sizeof(row->displayName),
                 "Tailscale-like (%s)", snapshot->name ? snapshot->name : "network");
        copyText(row->suggestedAllowCIDR, sizeof(row->suggestedAllowCIDR), "100.64.0.0/10");
    } else if (strcmp(snapshot->name ? snapshot->name : "", "lo0") == 0) {
        copyText(row->suggestedAllowCIDR, sizeof(row->suggestedAllowCIDR), "127.0.0.1/32");
    } else {
        copyText(row->suggestedAllowCIDR, sizeof(row->suggestedAllowCIDR), row->cidr);
    }
    row->allowPresetVisible = !isHiddenAllowPresetInterface(snapshot->name);
    return true;
}
