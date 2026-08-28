#include "MacVNCImageProfile.h"

#include <stdio.h>
#include <string.h>

MacVNCImageProfile
macVNCDefaultImageProfile(void)
{
    MacVNCImageProfile profile = { MacVNCImageProfileJPEG,
                                   MACVNC_IMAGE_QUALITY_DEFAULT };
    return profile;
}

bool
macVNCParseImageProfile(const char *name, MacVNCImageProfile *profile)
{
    if (!name || !profile)
        return false;

    if (!strcmp(name, "viewer")) {
        profile->kind = MacVNCImageProfileFollowViewer;
        profile->qualityLevel = 0;
        return true;
    }
    if (!strcmp(name, "lossless")) {
        profile->kind = MacVNCImageProfileLossless;
        profile->qualityLevel = 0;
        return true;
    }

    /* Exactly one digit: "05" or "5 " are not names we write, and accepting
       them would mean two spellings of one setting. */
    if (name[0] < '0' || name[0] > '9' || name[1] != '\0')
        return false;

    int level = name[0] - '0';
    if (level < MACVNC_IMAGE_QUALITY_MIN || level > MACVNC_IMAGE_QUALITY_MAX)
        return false; /* 8 and 9 are dominated by lossless - see the header */

    profile->kind = MacVNCImageProfileJPEG;
    profile->qualityLevel = level;
    return true;
}

const char *
macVNCImageProfileName(MacVNCImageProfile profile)
{
    switch (profile.kind) {
        case MacVNCImageProfileFollowViewer:
            return "viewer";
        case MacVNCImageProfileLossless:
            return "lossless";
        case MacVNCImageProfileJPEG:
            break;
    }

    if (profile.qualityLevel < MACVNC_IMAGE_QUALITY_MIN ||
        profile.qualityLevel > MACVNC_IMAGE_QUALITY_MAX)
        return "5"; /* never name a level we refuse to parse back */

    /* One static name per level: the table makes the round trip obvious and
       avoids handing out a pointer to a buffer the caller might outlive. */
    static const char *const names[] = { "0", "1", "2", "3", "4", "5", "6", "7" };
    return names[profile.qualityLevel];
}
