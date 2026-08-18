#include "NetworkAccess.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #expr); exit(1); } } while (0)

static void assert_parse_ok(const char *text, const char *allowed, const char *denied)
{
    MacVNCNetworkAccessList list;
    char error[128] = {0};
    CHECK(macVNCParseAccessList(text, &list, error, sizeof(error)));
    CHECK(error[0] == '\0');
    if (allowed)
        CHECK(macVNCNetworkAccessAllows(&list, allowed));
    if (denied)
        CHECK(!macVNCNetworkAccessAllows(&list, denied));
}

static void assert_parse_bad(const char *text)
{
    MacVNCNetworkAccessList list;
    char error[128] = {0};
    CHECK(!macVNCParseAccessList(text, &list, error, sizeof(error)));
    CHECK(error[0] != '\0');
}

int main(void)
{
    uint32_t ip = 0;
    CHECK(macVNCParseIPv4("100.70.214.41", &ip));
    CHECK(macVNCParseIPv4("0.0.0.0", &ip));
    CHECK(macVNCParseIPv4("255.255.255.255", &ip));
    CHECK(!macVNCParseIPv4("100.70.214", &ip));
    CHECK(!macVNCParseIPv4("999.1.1.1", &ip));
    CHECK(!macVNCParseIPv4("host.local", &ip));

    MacVNCIPv4CIDR cidr;
    CHECK(macVNCParseCIDR("100.70.214.41", &cidr));
    CHECK(cidr.prefixLength == 32);
    CHECK(macVNCParseCIDR("100.64.0.0/10", &cidr));
    CHECK(cidr.prefixLength == 10);
    CHECK(macVNCParseCIDR("0.0.0.0/0", &cidr));
    CHECK(cidr.prefixLength == 0);
    CHECK(macVNCParseCIDR("100.100.242.110/10", &cidr));
    CHECK(cidr.network == 0x64400000u);
    CHECK(!macVNCParseCIDR("100.64.0.0/33", &cidr));
    CHECK(!macVNCParseCIDR("100.64.0.0/-1", &cidr));
    CHECK(!macVNCParseCIDR("100.64.0.0/10/1", &cidr));
    CHECK(!macVNCParseCIDR("tailnet-device", &cidr));

    MacVNCNetworkAccessList empty;
    char error[128] = {0};
    CHECK(macVNCParseAccessList("  \n,\t ", &empty, error, sizeof(error)));
    CHECK(empty.count == 0);
    CHECK(macVNCNetworkAccessAllows(&empty, "203.0.113.10"));
    CHECK(macVNCNetworkAccessAllows(NULL, "203.0.113.10"));

    assert_parse_ok("100.64.0.0/10", "100.64.0.1", "100.128.0.1");
    assert_parse_ok("100.64.0.0/10", "100.100.242.110", "192.168.1.10");
    assert_parse_ok("100.64.0.0/10", "100.127.255.254", "100.128.0.1");
    assert_parse_ok("127.0.0.1", "127.0.0.1", "127.0.0.2");
    assert_parse_ok("100.64.0.0/10\n192.168.1.0/24, 127.0.0.1",
                    "192.168.1.42", "10.0.0.1");

    MacVNCNetworkAccessList broad;
    CHECK(macVNCParseAccessList("0.0.0.0/0", &broad, error, sizeof(error)));
    CHECK(macVNCNetworkAccessContainsAllowAll(&broad));
    CHECK(macVNCNetworkAccessAllows(&broad, "8.8.8.8"));
    CHECK(!macVNCNetworkAccessContainsAllowAll(&empty));

    assert_parse_bad("999.1.1.1");
    assert_parse_bad("100.64.0.0/33");
    assert_parse_bad("hostname.local");

    char many[2048] = {0};
    for (int i = 0; i < MACVNC_NETWORK_ACCESS_MAX_ENTRIES + 1; ++i) {
        char token[32];
        snprintf(token, sizeof(token), "10.0.0.%d ", i + 1);
        strncat(many, token, sizeof(many) - strlen(many) - 1);
    }
    assert_parse_bad(many);

    puts("network access tests passed");
    return 0;
}
