#pragma once

#include <stdbool.h>
#include <stddef.h>

bool macVNCNetworkCIDRFromAddressAndMask(const char *address,
                                         const char *netmask,
                                         char *out,
                                         size_t outSize);

bool macVNCIPv4IsCGNAT(const char *address);
