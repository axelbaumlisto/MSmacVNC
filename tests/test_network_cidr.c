#include "NetworkCIDR.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #expr); exit(1); } } while (0)
#define CHECK_STR(actual, expected) do { if (strcmp((actual), (expected)) != 0) { fprintf(stderr, "FAIL %s:%d: got '%s' expected '%s'\n", __FILE__, __LINE__, (actual), (expected)); exit(1); } } while (0)

int main(void)
{
    char out[64];
    CHECK(macVNCNetworkCIDRFromAddressAndMask("192.168.1.87", "255.255.255.0", out, sizeof(out)));
    CHECK_STR(out, "192.168.100.0/24");
    CHECK(macVNCNetworkCIDRFromAddressAndMask("10.0.5.9", "255.255.0.0", out, sizeof(out)));
    CHECK_STR(out, "10.0.0.0/16");
    CHECK(macVNCNetworkCIDRFromAddressAndMask("100.101.102.103", "255.255.255.255", out, sizeof(out)));
    CHECK_STR(out, "100.101.102.103/32");
    CHECK(macVNCNetworkCIDRFromAddressAndMask("203.0.113.9", "0.0.0.0", out, sizeof(out)));
    CHECK_STR(out, "0.0.0.0/0");

    CHECK(!macVNCNetworkCIDRFromAddressAndMask("10.0.0.1", "255.0.255.0", out, sizeof(out)));
    CHECK(!macVNCNetworkCIDRFromAddressAndMask("host", "255.255.255.0", out, sizeof(out)));
    CHECK(!macVNCNetworkCIDRFromAddressAndMask("10.0.0.1", "bad", out, sizeof(out)));
    CHECK(!macVNCNetworkCIDRFromAddressAndMask("10.0.0.1", "255.255.255.0", out, 4));

    CHECK(macVNCIPv4IsCGNAT("100.64.0.0"));
    CHECK(macVNCIPv4IsCGNAT("100.101.102.103"));
    CHECK(macVNCIPv4IsCGNAT("100.127.255.254"));
    CHECK(!macVNCIPv4IsCGNAT("100.128.0.1"));
    CHECK(!macVNCIPv4IsCGNAT("192.168.1.1"));
    CHECK(!macVNCIPv4IsCGNAT("host"));

    /* private ranges and the enclosing /24 used by the VPN preset */
    CHECK(macVNCIPv4IsPrivate("10.13.13.3"));
    CHECK(macVNCIPv4IsPrivate("172.16.5.1"));
    CHECK(macVNCIPv4IsPrivate("172.31.255.254"));
    CHECK(!macVNCIPv4IsPrivate("172.32.0.1"));
    CHECK(macVNCIPv4IsPrivate("192.168.1.53"));
    CHECK(!macVNCIPv4IsPrivate("100.101.102.103"));
    CHECK(!macVNCIPv4IsPrivate("203.0.113.9"));

    char net24[24] = {0};
    CHECK(macVNCIPv4Surrounding24("10.13.13.2", net24, sizeof(net24)));
    CHECK_STR(net24, "10.13.13.0/24");
    CHECK(macVNCIPv4Surrounding24("192.168.1.255", net24, sizeof(net24)));
    CHECK_STR(net24, "192.168.1.0/24");
    CHECK(!macVNCIPv4Surrounding24("not-an-ip", net24, sizeof(net24)));
    char tight[8] = {0};
    CHECK(!macVNCIPv4Surrounding24("10.13.13.2", tight, sizeof(tight)));

    puts("network cidr tests passed");
    return 0;
}
