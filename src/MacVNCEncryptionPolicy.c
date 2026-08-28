#include "MacVNCEncryptionPolicy.h"

#include <string.h>

/* One table: what the UI shows and what gets stored cannot drift apart. */
static const struct {
    const char *name;
    const char *title;
    MacVNCEncryptionPolicy policy;
} kLadder[] = {
    { "optional", "Allow unencrypted connections (compatible)",
      MacVNCEncryptionOptional },
    { "required", "Require encryption (TLS) - refuses viewers without it",
      MacVNCEncryptionRequired },
};

bool
macVNCEncryptionAdmits(MacVNCEncryptionPolicy policy, bool clientIsEncrypted)
{
    /* Encrypted clients are admitted under every policy; the only decision is
       what to do with an unencrypted one. */
    return clientIsEncrypted || policy != MacVNCEncryptionRequired;
}

bool
macVNCParseEncryptionPolicy(const char *name, MacVNCEncryptionPolicy *policy)
{
    if (!name || !policy)
        return false;

    for (size_t i = 0; i < macVNCEncryptionLadderCount(); ++i)
        if (!strcmp(name, kLadder[i].name)) {
            *policy = kLadder[i].policy;
            return true;
        }
    return false;
}

const char *
macVNCEncryptionPolicyName(MacVNCEncryptionPolicy policy)
{
    for (size_t i = 0; i < macVNCEncryptionLadderCount(); ++i)
        if (kLadder[i].policy == policy)
            return kLadder[i].name;
    /* Never name a policy that cannot be parsed back. */
    return MACVNC_ENCRYPTION_DEFAULT_NAME;
}

size_t
macVNCEncryptionLadderCount(void)
{
    return sizeof(kLadder) / sizeof(kLadder[0]);
}

const char *
macVNCEncryptionLadderName(size_t index)
{
    return index < macVNCEncryptionLadderCount() ? kLadder[index].name : NULL;
}

const char *
macVNCEncryptionLadderTitle(size_t index)
{
    return index < macVNCEncryptionLadderCount() ? kLadder[index].title : NULL;
}
