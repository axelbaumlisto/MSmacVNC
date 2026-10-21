#include "NetworkInventory.h"
#include "NetworkCIDR.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #expr); exit(1); } } while (0)
#define CHECK_STR(actual, expected) do { if (strcmp((actual), (expected)) != 0) { fprintf(stderr, "FAIL %s:%d: got '%s' expected '%s'\n", __FILE__, __LINE__, (actual), (expected)); exit(1); } } while (0)

int main(void)
{
    MacVNCNetworkInterfaceRow row;
    CHECK(macVNCBuildNetworkInterfaceRow(&(MacVNCNetworkInterfaceSnapshot){"en0", true, "192.168.1.87", "255.255.255.0"}, &row));
    CHECK(row.active);
    CHECK(row.selectable);
    CHECK(row.allowPresetVisible);
    CHECK(!row.cgnatLike);
    CHECK_STR(row.name, "en0");
    CHECK_STR(row.address, "192.168.1.87");
    CHECK_STR(row.cidr, "192.168.1.0/24");
    CHECK_STR(row.suggestedAllowCIDR, "192.168.1.0/24");
    CHECK_STR(row.displayName, "en0");

    CHECK(macVNCBuildNetworkInterfaceRow(&(MacVNCNetworkInterfaceSnapshot){"utun4", true, "100.101.102.103", "255.255.255.255"}, &row));
    CHECK(row.selectable);
    CHECK(row.allowPresetVisible);
    CHECK(row.cgnatLike);
    CHECK_STR(row.cidr, "100.101.102.103/32");
    CHECK_STR(row.suggestedAllowCIDR, MACVNC_TAILNET_ALLOW_CIDR);
    CHECK(row.tailnetLike);
    CHECK_STR(row.displayName, "Tailscale-like (utun4)");

    /* A CGNAT address on a normal broadcast interface (carrier/campus CGNAT LAN)
       must keep its real subnet, NOT be widened to the 100.64.0.0/10 tailnet
       preset, and must not be labelled as a tailnet. */
    CHECK(macVNCBuildNetworkInterfaceRow(&(MacVNCNetworkInterfaceSnapshot){"en0", true, "100.92.13.7", "255.255.255.0"}, &row));
    CHECK(row.selectable);
    CHECK(row.cgnatLike);
    CHECK_STR(row.cidr, "100.92.13.0/24");
    CHECK_STR(row.suggestedAllowCIDR, "100.92.13.0/24");
    CHECK(!row.tailnetLike);   /* CGNAT address, but no broad preset: label stays neutral */
    CHECK_STR(row.displayName, "en0");

    CHECK(macVNCBuildNetworkInterfaceRow(&(MacVNCNetworkInterfaceSnapshot){"lo0", true, "127.0.0.1", "255.0.0.0"}, &row));
    CHECK(row.selectable);
    CHECK(!row.allowPresetVisible);
    CHECK_STR(row.suggestedAllowCIDR, "127.0.0.1/32");

    CHECK(macVNCBuildNetworkInterfaceRow(&(MacVNCNetworkInterfaceSnapshot){"bridge100", true, "192.168.139.3", "255.255.255.0"}, &row));
    CHECK(row.selectable);
    CHECK(!row.allowPresetVisible);

    /* AmneziaWG/WireGuard: the client gets a private /32 while the peers share
       the tunnel subnet, so the preset must name the enclosing /24 rather than
       the single address. */
    CHECK(macVNCBuildNetworkInterfaceRow(&(MacVNCNetworkInterfaceSnapshot){"utun6", true, "10.13.13.3", "255.255.255.255"}, &row));
    CHECK(row.selectable);
    CHECK(row.vpnLike);
    CHECK(!row.tailnetLike);
    CHECK(row.allowPresetVisible);
    CHECK_STR(row.suggestedAllowCIDR, "10.13.13.0/24");
    CHECK_STR(row.displayName, "WireGuard-like (utun6)");

    CHECK(macVNCBuildNetworkInterfaceRow(&(MacVNCNetworkInterfaceSnapshot){"utun7", true, "192.168.77.4", "255.255.255.255"}, &row));
    CHECK(row.vpnLike);
    CHECK(row.allowPresetVisible);
    CHECK_STR(row.suggestedAllowCIDR, "192.168.77.0/24");

    /* A public /32 tunnel is not a VPN subnet: keep the single address and hide
       the preset, exactly as before. */
    CHECK(macVNCBuildNetworkInterfaceRow(&(MacVNCNetworkInterfaceSnapshot){"utun8", true, "203.0.113.9", "255.255.255.255"}, &row));
    CHECK(!row.vpnLike);
    CHECK(!row.allowPresetVisible);
    CHECK_STR(row.suggestedAllowCIDR, "203.0.113.9/32");

    /* A private /32 on a NON-tunnel interface (no utun prefix) must not be
       widened: only the tunnel shape implies shared peers. */
    CHECK(macVNCBuildNetworkInterfaceRow(&(MacVNCNetworkInterfaceSnapshot){"en5", true, "10.13.13.3", "255.255.255.255"}, &row));
    CHECK(!row.vpnLike);
    CHECK(!row.allowPresetVisible);

    CHECK(macVNCBuildNetworkInterfaceRow(&(MacVNCNetworkInterfaceSnapshot){"en7", true, "169.254.10.1", "255.255.0.0"}, &row));
    CHECK(row.selectable);
    CHECK(!row.allowPresetVisible);

    CHECK(macVNCBuildNetworkInterfaceRow(&(MacVNCNetworkInterfaceSnapshot){"en9", false, NULL, NULL}, &row));
    CHECK(!row.active);
    CHECK(!row.selectable);
    CHECK(!row.allowPresetVisible);
    CHECK_STR(row.name, "en9");

    CHECK(macVNCBuildNetworkInterfaceRow(&(MacVNCNetworkInterfaceSnapshot){"bad", true, "10.0.0.1", "255.0.255.0"}, &row));
    CHECK(row.active);
    CHECK(!row.selectable);
    CHECK(!row.allowPresetVisible);
    CHECK_STR(row.cidr, "");

    puts("network inventory tests passed");
    return 0;
}
