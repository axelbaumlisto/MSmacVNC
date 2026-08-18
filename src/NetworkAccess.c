#include "NetworkAccess.h"

#include <arpa/inet.h>
#include <ctype.h>
#include <stdio.h>
#include <string.h>

static void
setError(char *error, size_t errorSize, const char *message, const char *token)
{
    if (!error || errorSize == 0)
        return;
    if (token)
        snprintf(error, errorSize, "%s: %s", message, token);
    else
        snprintf(error, errorSize, "%s", message);
}

bool
macVNCParseIPv4(const char *text, uint32_t *outHostOrder)
{
    if (!text || !*text)
        return false;

    struct in_addr address;
    if (inet_pton(AF_INET, text, &address) != 1)
        return false;

    if (outHostOrder)
        *outHostOrder = ntohl(address.s_addr);
    return true;
}

bool
macVNCParseCIDR(const char *text, MacVNCIPv4CIDR *out)
{
    if (!text || !*text || !out)
        return false;

    char buffer[64];
    size_t length = strlen(text);
    if (length == 0 || length >= sizeof(buffer))
        return false;
    memcpy(buffer, text, length + 1);

    char *slash = strchr(buffer, '/');
    unsigned prefixLength = 32;
    if (slash) {
        *slash = '\0';
        const char *prefix = slash + 1;
        if (!*prefix)
            return false;
        unsigned value = 0;
        for (const unsigned char *cursor = (const unsigned char *)prefix;
             *cursor; ++cursor) {
            if (!isdigit(*cursor))
                return false;
            value = value * 10u + (unsigned)(*cursor - '0');
            if (value > 32u)
                return false;
        }
        prefixLength = value;
    }

    uint32_t ip = 0;
    if (!macVNCParseIPv4(buffer, &ip))
        return false;

    uint32_t mask = prefixLength == 0
        ? 0u
        : (uint32_t)(0xffffffffu << (32u - prefixLength));
    out->mask = mask;
    out->network = ip & mask;
    out->prefixLength = prefixLength;
    return true;
}

bool
macVNCParseAccessList(const char *text,
                      MacVNCNetworkAccessList *out,
                      char *error,
                      size_t errorSize)
{
    if (!out) {
        setError(error, errorSize, "missing output access list", NULL);
        return false;
    }
    out->count = 0;
    if (error && errorSize > 0)
        error[0] = '\0';
    if (!text || !*text)
        return true;

    const char *cursor = text;
    while (*cursor) {
        while (*cursor && (isspace((unsigned char)*cursor) || *cursor == ','))
            ++cursor;
        if (!*cursor)
            break;

        const char *start = cursor;
        while (*cursor && !isspace((unsigned char)*cursor) && *cursor != ',')
            ++cursor;
        size_t length = (size_t)(cursor - start);
        if (length == 0)
            continue;
        if (length >= 64) {
            setError(error, errorSize, "network token is too long", start);
            return false;
        }

        if (out->count >= MACVNC_NETWORK_ACCESS_MAX_ENTRIES) {
            setError(error, errorSize, "too many allowed-client entries", start);
            return false;
        }

        char token[64];
        memcpy(token, start, length);
        token[length] = '\0';
        MacVNCIPv4CIDR cidr;
        if (!macVNCParseCIDR(token, &cidr)) {
            setError(error, errorSize, "invalid IPv4/CIDR entry", token);
            return false;
        }
        out->entries[out->count++] = cidr;
    }
    return true;
}

bool
macVNCNetworkAccessAllows(const MacVNCNetworkAccessList *list,
                          const char *clientHost)
{
    if (!list || list->count == 0)
        return true;

    uint32_t ip = 0;
    if (!macVNCParseIPv4(clientHost, &ip))
        return false;

    for (size_t i = 0; i < list->count; ++i) {
        const MacVNCIPv4CIDR *entry = &list->entries[i];
        if ((ip & entry->mask) == entry->network)
            return true;
    }
    return false;
}

bool
macVNCNetworkAccessContainsAllowAll(const MacVNCNetworkAccessList *list)
{
    if (!list)
        return false;
    for (size_t i = 0; i < list->count; ++i) {
        if (list->entries[i].prefixLength == 0)
            return true;
    }
    return false;
}
