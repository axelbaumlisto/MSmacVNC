#pragma once

#include <stdbool.h>
#include <stddef.h>

/*
 * Whether a viewer may connect without encryption.
 *
 * The server advertises BOTH classic VNC auth (type 2) and VeNCrypt/TLS
 * (type 19), and the CLIENT picks. It always picks the plain one, and that is
 * not a bug we can fix by reordering: LibVNCServer inserts each security
 * handler at the HEAD of its list and sends the list from the head
 * (auth.c:58-69 and :224), while registering its own VncAuth handler lazily on
 * the FIRST connection - that is, after ours. So plain ends up first no matter
 * when we register, and the only reliable lever is refusing it.
 *
 * Refusing is a policy, and this module is the policy: pure, so "who is
 * admitted" is decided and tested without a socket.
 */

typedef enum {
    /* Both paths accepted; the viewer decides. Compatible with viewers that
       have no VeNCrypt support at all. */
    MacVNCEncryptionOptional = 0,
    /* Unencrypted clients are refused. */
    MacVNCEncryptionRequired = 1,
} MacVNCEncryptionPolicy;

#define MACVNC_ENCRYPTION_DEFAULT_NAME "optional"

/*
 * The single question this module answers.
 *
 * `clientIsEncrypted` is a fact about the connection, not an intention: the
 * caller passes what the transport actually did.
 */
bool macVNCEncryptionAdmits(MacVNCEncryptionPolicy policy,
                            bool clientIsEncrypted);

/*
 * Parse a stored setting name: "optional" or "required".
 *
 * Returns false for anything else, leaving the output UNTOUCHED so a caller can
 * pre-load its default. A misspelled setting must never be read as "required"
 * (locking the owner out) nor silently as "optional" without saying so.
 */
bool macVNCParseEncryptionPolicy(const char *name, MacVNCEncryptionPolicy *policy);

/** Stable name, suitable for storing and logging. */
const char *macVNCEncryptionPolicyName(MacVNCEncryptionPolicy policy);

/* The choices the settings UI offers, in order. Here rather than in the UI so a
   test can assert every entry parses and the shipped default is among them. */
size_t macVNCEncryptionLadderCount(void);
const char *macVNCEncryptionLadderName(size_t index);
const char *macVNCEncryptionLadderTitle(size_t index);
