#include "NetworkCIDR.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #expr); exit(1); } } while (0)
#define CHECK_STR(actual, expected) do { if (strcmp((actual), (expected)) != 0) { fprintf(stderr, "FAIL %s:%d: got '%s' expected '%s'\n", __FILE__, __LINE__, (actual), (expected)); exit(1); } } while (0)

int main(void)
{
    char out[64];
    CHECK(macVNCNetworkCIDRFromAddressAndMask("192.168.100.87", "255.255.255.0", out, sizeof(out)));
    CHECK_STR(out, "192.168.100.0/24");
    CHECK(macVNCNetworkCIDRFromAddressAndMask("10.0.5.9", "255.255.0.0", out, sizeof(out)));
    CHECK_STR(out, "10.0.0.0/16");
    CHECK(macVNCNetworkCIDRFromAddressAndMask("100.70.214.41", "255.255.255.255", out, sizeof(out)));
    CHECK_STR(out, "100.70.214.41/32");
    CHECK(macVNCNetworkCIDRFromAddressAndMask("203.0.113.9", "0.0.0.0", out, sizeof(out)));
    CHECK_STR(out, "0.0.0.0/0");

    CHECK(!macVNCNetworkCIDRFromAddressAndMask("10.0.0.1", "255.0.255.0", out, sizeof(out)));
    CHECK(!macVNCNetworkCIDRFromAddressAndMask("host", "255.255.255.0", out, sizeof(out)));
    CHECK(!macVNCNetworkCIDRFromAddressAndMask("10.0.0.1", "bad", out, sizeof(out)));
    CHECK(!macVNCNetworkCIDRFromAddressAndMask("10.0.0.1", "255.255.255.0", out, 4));

    CHECK(macVNCIPv4IsCGNAT("100.64.0.0"));
    CHECK(macVNCIPv4IsCGNAT("100.70.214.41"));
    CHECK(macVNCIPv4IsCGNAT("100.127.255.254"));
    CHECK(!macVNCIPv4IsCGNAT("100.128.0.1"));
    CHECK(!macVNCIPv4IsCGNAT("192.168.1.1"));
    CHECK(!macVNCIPv4IsCGNAT("host"));

    puts("network cidr tests passed");
    return 0;
}
