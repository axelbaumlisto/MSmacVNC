#include "NetworkRowText.h"

#include <stdio.h>

/* One place that spells out "format, and refuse rather than truncate". Written
   three times per branch before, once per buffer here. */
static bool
formatInto(char *dest, size_t destSize, const char *format, const char *a, const char *b)
{
    if (!dest || destSize == 0)
        return false;
    int written = snprintf(dest, destSize, format, a, b);
    return written >= 0 && (size_t)written < destSize;
}

bool
macVNCNetworkRowAllowText(const MacVNCNetworkInterfaceRow *row,
                          char *title, size_t titleSize,
                          char *summary, size_t summarySize)
{
    if (!row)
        return false;

    if (row->tailnetLike) {
        return formatInto(title, titleSize,
                          "Tailscale tailnet / CGNAT range — %s "
                          "(broad; use Tailscale ACLs)", row->suggestedAllowCIDR, NULL) &&
               formatInto(summary, summarySize, "Auto: Tailscale clients — %s",
                          row->suggestedAllowCIDR, NULL);
    }
    if (row->vpnLike) {
        return formatInto(title, titleSize, "VPN peers of %s — %s (this tunnel only)",
                          row->displayName, row->suggestedAllowCIDR) &&
               formatInto(summary, summarySize, "Auto: VPN clients — %s",
                          row->suggestedAllowCIDR, NULL);
    }
    return formatInto(title, titleSize, "Same network as %s — %s",
                      row->displayName, row->suggestedAllowCIDR) &&
           formatInto(summary, summarySize, "Auto: same network — %s",
                      row->suggestedAllowCIDR, NULL);
}
