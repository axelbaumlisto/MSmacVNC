#pragma once

/*
 * Canonical listen-mode string values, as plain C string literals so BOTH the
 * C policy resolver and the Objective-C UI layer share one source of truth.
 * The Objective-C NSString constants (MacVNCListenMode.h) are defined from
 * these, and NetworkPolicyResolver compares against these directly.
 */
#define MACVNC_LISTEN_MODE_LOCALHOST "localhost"
#define MACVNC_LISTEN_MODE_ALL       "all"
#define MACVNC_LISTEN_MODE_CUSTOM    "custom"
#define MACVNC_LISTEN_MODE_SELECTED  "selected"

/* Shared localhost bind address (single source for C and ObjC). */
#define MACVNC_LOOPBACK_IPV4 "127.0.0.1"
