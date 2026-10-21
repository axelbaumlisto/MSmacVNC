#pragma once

#include "NetworkInventory.h"

#include <stdbool.h>
#include <stddef.h>

#define MACVNC_NETWORK_ROW_LABEL_MAX 192

/*
 * The wording the allowlist checkbox shows for a row - a presentation concern,
 * kept out of NetworkInventory, which decides what a row IS.
 *
 * It lives in C rather than in the Objective-C rows builder for one reason: the
 * sentences are what tells a tailnet from a VPN from a LAN, and a sentence built
 * inside a UI callback cannot be read by a test.
 */
bool macVNCNetworkRowAllowText(const MacVNCNetworkInterfaceRow *row,
                               char *title, size_t titleSize,
                               char *summary, size_t summarySize);
