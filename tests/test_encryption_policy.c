/*
 * Who is let in. The failure modes here are asymmetric and both are bad: a
 * policy that wrongly admits leaks the screen over a plaintext socket, and a
 * policy that wrongly refuses locks the owner out of their own Mac.
 */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "MacVNCEncryptionPolicy.h"

int
main(void)
{
    MacVNCEncryptionPolicy policy;

    /* The whole decision, both policies, both kinds of client. */
    assert(macVNCEncryptionAdmits(MacVNCEncryptionOptional, true));
    assert(macVNCEncryptionAdmits(MacVNCEncryptionOptional, false));
    assert(macVNCEncryptionAdmits(MacVNCEncryptionRequired, true));
    assert(!macVNCEncryptionAdmits(MacVNCEncryptionRequired, false));

    /* Names round-trip: the popup stores a name and reads it back. */
    assert(macVNCParseEncryptionPolicy("optional", &policy));
    assert(policy == MacVNCEncryptionOptional);
    assert(!strcmp(macVNCEncryptionPolicyName(policy), "optional"));

    assert(macVNCParseEncryptionPolicy("required", &policy));
    assert(policy == MacVNCEncryptionRequired);
    assert(!strcmp(macVNCEncryptionPolicyName(policy), "required"));

    /* The shipped default is the compatible one, deliberately: making
       "required" the default would silently lock out every viewer without
       VeNCrypt support on an upgrade. */
    assert(macVNCParseEncryptionPolicy(MACVNC_ENCRYPTION_DEFAULT_NAME, &policy));
    assert(policy == MacVNCEncryptionOptional);

    /* A rejected name leaves the output UNTOUCHED, so a caller pre-loads its
       default and a typo cannot flip the policy in either direction. */
    MacVNCEncryptionPolicy preloaded = MacVNCEncryptionRequired;
    assert(!macVNCParseEncryptionPolicy("Required", &preloaded));
    assert(preloaded == MacVNCEncryptionRequired);
    assert(!macVNCParseEncryptionPolicy("", &preloaded));
    assert(preloaded == MacVNCEncryptionRequired);
    assert(!macVNCParseEncryptionPolicy("yes", &preloaded));
    assert(preloaded == MacVNCEncryptionRequired);
    assert(!macVNCParseEncryptionPolicy("tls", &preloaded));
    assert(preloaded == MacVNCEncryptionRequired);
    assert(!macVNCParseEncryptionPolicy(NULL, &preloaded));
    assert(!macVNCParseEncryptionPolicy("optional", NULL));

    /* An out-of-range policy value must not name itself unparsably. */
    assert(macVNCParseEncryptionPolicy(
               macVNCEncryptionPolicyName((MacVNCEncryptionPolicy)99), &policy));

    /* The ladder the UI offers: every entry parses, every entry has a title,
       and the default is on it exactly once. */
    size_t ladder = macVNCEncryptionLadderCount();
    assert(ladder == 2);
    assert(macVNCEncryptionLadderName(ladder) == NULL);
    assert(macVNCEncryptionLadderTitle(ladder) == NULL);

    int defaultsSeen = 0;
    for (size_t i = 0; i < ladder; ++i) {
        const char *name = macVNCEncryptionLadderName(i);
        const char *title = macVNCEncryptionLadderTitle(i);
        assert(name && title && *name && *title);
        assert(macVNCParseEncryptionPolicy(name, &policy));
        assert(!strcmp(macVNCEncryptionPolicyName(policy), name));
        if (!strcmp(name, MACVNC_ENCRYPTION_DEFAULT_NAME))
            ++defaultsSeen;
    }
    assert(defaultsSeen == 1);

    /* The compatible choice comes first, so the popup opens on the state that
       cannot lock anyone out. */
    assert(!strcmp(macVNCEncryptionLadderName(0), MACVNC_ENCRYPTION_DEFAULT_NAME));

    puts("test_encryption_policy: all assertions passed");
    return 0;
}
