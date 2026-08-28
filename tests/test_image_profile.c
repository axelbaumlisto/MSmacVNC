/*
 * The image profile decides what a viewer sees, so an unparsable setting must
 * never reach the encoder as an undefined level, and the names must round-trip:
 * the Preferences popup stores a name and reads it back.
 */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "MacVNCImageProfile.h"

int
main(void)
{
    MacVNCImageProfile profile;

    /* The measured default is JPEG quality 5. */
    MacVNCImageProfile fallback = macVNCDefaultImageProfile();
    assert(fallback.kind == MacVNCImageProfileJPEG);
    assert(fallback.qualityLevel == 5);
    assert(!strcmp(macVNCImageProfileName(fallback), "5"));

    /* Delegation to the viewer is a real choice, not the absence of one. */
    assert(macVNCParseImageProfile("viewer", &profile));
    assert(profile.kind == MacVNCImageProfileFollowViewer);
    assert(!strcmp(macVNCImageProfileName(profile), "viewer"));

    /* Lossless is the top of the ladder, not a hidden mode. */
    assert(macVNCParseImageProfile("lossless", &profile));
    assert(profile.kind == MacVNCImageProfileLossless);
    assert(!strcmp(macVNCImageProfileName(profile), "lossless"));

    /* Every offered level parses, keeps its number, and names itself back. */
    for (int level = MACVNC_IMAGE_QUALITY_MIN;
         level <= MACVNC_IMAGE_QUALITY_MAX; ++level) {
        char name[2] = { (char)('0' + level), '\0' };
        assert(macVNCParseImageProfile(name, &profile));
        assert(profile.kind == MacVNCImageProfileJPEG);
        assert(profile.qualityLevel == level);
        assert(!strcmp(macVNCImageProfileName(profile), name));
    }

    /* Levels 8 and 9 exist in the protocol and are REFUSED on purpose: both
       cost more bytes than lossless while being worse than lossless. */
    assert(!macVNCParseImageProfile("8", &profile));
    assert(!macVNCParseImageProfile("9", &profile));

    /* Anything unparsable must be refused rather than half-applied, so the
       caller falls back to the default instead of encoding at level -1. */
    assert(!macVNCParseImageProfile("", &profile));
    assert(!macVNCParseImageProfile("05", &profile));
    assert(!macVNCParseImageProfile("5 ", &profile));
    assert(!macVNCParseImageProfile(" 5", &profile));
    assert(!macVNCParseImageProfile("balanced", &profile));
    assert(!macVNCParseImageProfile("-1", &profile));
    assert(!macVNCParseImageProfile("10", &profile));
    assert(!macVNCParseImageProfile("VIEWER", &profile));
    assert(!macVNCParseImageProfile(NULL, &profile));
    assert(!macVNCParseImageProfile("5", NULL));

    /* A rejected name must not touch the output - callers pre-load the default
       and rely on it surviving. */
    MacVNCImageProfile preloaded = { MacVNCImageProfileLossless, 3 };
    assert(!macVNCParseImageProfile("9", &preloaded));
    assert(preloaded.kind == MacVNCImageProfileLossless && preloaded.qualityLevel == 3);
    assert(!macVNCParseImageProfile("nonsense", &preloaded));
    assert(preloaded.kind == MacVNCImageProfileLossless && preloaded.qualityLevel == 3);

    /* A profile carrying a level outside the offered range must not name
       itself as something that cannot be parsed back. */
    MacVNCImageProfile bogus = { MacVNCImageProfileJPEG, 9 };
    assert(macVNCParseImageProfile(macVNCImageProfileName(bogus), &profile));

    /* The compression level is fixed, and the header explains why: levels 1-9
       are byte-identical, 0 is 4.3x larger. Pin the value so nobody "restores"
       0 and quadruples the traffic. */
    assert(MACVNC_IMAGE_COMPRESS_LEVEL >= 1 &&
           MACVNC_IMAGE_COMPRESS_LEVEL <= 9);

    /* The ladder is what Preferences shows AND what it stores, so every entry
       must parse, and the stored name must survive the round trip. The list
       used to exist twice in the UI file; these assertions are what make one
       copy enough. */
    size_t ladder = macVNCImageProfileLadderCount();
    assert(ladder == 10);
    assert(macVNCImageProfileLadderName(ladder) == NULL);
    assert(macVNCImageProfileLadderTitle(ladder) == NULL);

    int defaultsSeen = 0;
    for (size_t i = 0; i < ladder; ++i) {
        const char *name = macVNCImageProfileLadderName(i);
        const char *title = macVNCImageProfileLadderTitle(i);
        assert(name && title && *name && *title);
        assert(macVNCParseImageProfile(name, &profile));
        assert(!strcmp(macVNCImageProfileName(profile), name));
        if (profile.kind == MacVNCImageProfileJPEG &&
            profile.qualityLevel == MACVNC_IMAGE_QUALITY_DEFAULT)
            ++defaultsSeen;
    }
    /* Exactly one entry is the default, so the popup always has something
       to preselect and never two candidates. */
    assert(defaultsSeen == 1);

    /* Ordering matters: delegation first, best picture second - the UI relies
       on it, and a reshuffle would silently change what "recommended" means. */
    assert(!strcmp(macVNCImageProfileLadderName(0), "viewer"));
    assert(!strcmp(macVNCImageProfileLadderName(1), "lossless"));

    puts("test_image_profile: all assertions passed");
    return 0;
}
