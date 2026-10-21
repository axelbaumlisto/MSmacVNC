#pragma once

#include <stdbool.h>
#include <stddef.h>

bool macVNCNetworkCIDRFromAddressAndMask(const char *address,
                                         const char *netmask,
                                         char *out,
                                         size_t outSize);

bool macVNCIPv4IsCGNAT(const char *address);

/* RFC1918 (10/8, 172.16/12, 192.168/16). Point-to-point tunnels that use these
 * are WireGuard-family VPNs (AmneziaWG, WireGuard, OpenVPN tun), not ISP CGNAT. */
bool macVNCIPv4IsPrivate(const char *address);

/* The /24 that contains this address, e.g. "10.13.13.2" -> "10.13.13.0/24".
 * A tunnel hands the client a /32 while its peers share the tunnel subnet, so
 * the enclosing /24 is what an allowlist has to name. */
bool macVNCIPv4Surrounding24(const char *address, char *out, size_t outSize);
