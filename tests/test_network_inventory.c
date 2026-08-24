#include "NetworkInventory.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #expr); exit(1); } } while (0)
#define CHECK_STR(actual, expected) do { if (strcmp((actual), (expected)) != 0) { fprintf(stderr, "FAIL %s:%d: got '%s' expected '%s'\n", __FILE__, __LINE__, (actual), (expected)); exit(1); } } while (0)

int main(void)
{
    MacVNCNetworkInterfaceRow row;
    CHECK(macVNCBuildNetworkInterfaceRow(&(MacVNCNetworkInterfaceSnapshot){"en0", true, "192.168.100.87", "255.255.255.0"}, &row));
    CHECK(row.active);
    CHECK(row.selectable);
    CHECK(row.allowPresetVisible);
    CHECK(!row.cgnatLike);
    CHECK_STR(row.name, "en0");
    CHECK_STR(row.address, "192.168.100.87");
    CHECK_STR(row.cidr, "192.168.100.0/24");
    CHECK_STR(row.suggestedAllowCIDR, "192.168.100.0/24");
    CHECK_STR(row.displayName, "en0");

    CHECK(macVNCBuildNetworkInterfaceRow(&(MacVNCNetworkInterfaceSnapshot){"utun4", true, "100.70.214.41", "255.255.255.255"}, &row));
    CHECK(row.selectable);
    CHECK(row.allowPresetVisible);
    CHECK(row.cgnatLike);
    CHECK_STR(row.cidr, "100.70.214.41/32");
    CHECK_STR(row.suggestedAllowCIDR, "100.64.0.0/10");
    CHECK_STR(row.displayName, "Tailscale-like (utun4)");

    /* A CGNAT address on a normal broadcast interface (carrier/campus CGNAT LAN)
       must keep its real subnet, NOT be widened to the 100.64.0.0/10 tailnet
       preset, and must not be labelled as a tailnet. */
    CHECK(macVNCBuildNetworkInterfaceRow(&(MacVNCNetworkInterfaceSnapshot){"en0", true, "100.92.13.7", "255.255.255.0"}, &row));
    CHECK(row.selectable);
    CHECK(row.cgnatLike);
    CHECK_STR(row.cidr, "100.92.13.0/24");
    CHECK_STR(row.suggestedAllowCIDR, "100.92.13.0/24");
    CHECK_STR(row.displayName, "en0");

    CHECK(macVNCBuildNetworkInterfaceRow(&(MacVNCNetworkInterfaceSnapshot){"lo0", true, "127.0.0.1", "255.0.0.0"}, &row));
    CHECK(row.selectable);
    CHECK(!row.allowPresetVisible);
    CHECK_STR(row.suggestedAllowCIDR, "127.0.0.1/32");

    CHECK(macVNCBuildNetworkInterfaceRow(&(MacVNCNetworkInterfaceSnapshot){"bridge100", true, "192.168.139.3", "255.255.255.0"}, &row));
    CHECK(row.selectable);
    CHECK(!row.allowPresetVisible);

    CHECK(macVNCBuildNetworkInterfaceRow(&(MacVNCNetworkInterfaceSnapshot){"utun6", true, "10.13.13.3", "255.255.255.255"}, &row));
    CHECK(row.selectable);
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
