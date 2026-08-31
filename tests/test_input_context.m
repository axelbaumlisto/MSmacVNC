#import "MacVNCInput.h"
#import "DisplayLayout.h"

#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

/*
 * Lightweight test for MacVNCInput's injectable context + resource tracking.
 * We deliberately do NOT call macVNCInputStart() (it creates a CGEventSource
 * and reads the live keyboard layout, unavailable/undesirable in CI); we only
 * verify the pure state-management contract that has no side effects.
 */
int main(void)
{
    /* Before start, no resources are held. */
    assert(macVNCInputHasResources() == false);

    /* Building the KEYBOARD MAPS must not look like a running server.

       This one is a scar. The Text Input Source API aborts the process when it
       is called off the main thread, so the layout is now built at app launch
       instead of inside macVNCInputStart. The maps then counted as "input
       resources", serverHasLifecycleResourcesLocked() answered "a run is
       already live" in a brand new process, and the very first start request
       was refused with "VNC server is already running" - leaving the app
       listening on nothing. The maps describe the user's keyboard; only the
       event source describes a run. */
    macVNCInputRefreshKeyboardLayout();
    assert(macVNCInputHasResources() == false);

    /* Injecting a context must not allocate any input resource. */
    MacVNCDisplayLayout layout;
    memset(&layout, 0, sizeof(layout));
    layout.width = 1920;
    layout.height = 1080;
    macVNCInputSetContext(NULL, &layout);
    assert(macVNCInputHasResources() == false);

    /* Shutdown is idempotent and clears context without touching resources. */
    macVNCInputShutdown();
    assert(macVNCInputHasResources() == false);
    macVNCInputShutdown();
    assert(macVNCInputHasResources() == false);

    /* Every modifier in the keymap must be in the reset set, and nothing else.
       The set used to be a hand-written list of keycodes that went stale when a
       modifier was added - leaving that key stuck down for the LOCAL user. */
    unsigned short mods[32];
    size_t modCount = macVNCInputCopyModifierKeycodesForTesting(mods, 32);
    /* Shift, Control, Option(Meta), Command(Alt), AltGr-Option-R, Fn. */
    const unsigned short expected[] = {56, 59, 58, 55, 61, 63};
    const size_t expectedCount = sizeof(expected) / sizeof(expected[0]);
    if (modCount != expectedCount) {
        fprintf(stderr, "FAIL reset set has %zu keycodes, expected %zu\n",
                modCount, expectedCount);
        abort();
    }
    for (size_t i = 0; i < expectedCount; ++i) {
        bool found = false;
        for (size_t j = 0; j < modCount; ++j)
            if (mods[j] == expected[i]) { found = true; break; }
        if (!found) {
            fprintf(stderr, "FAIL modifier keycode %u missing from the reset set\n",
                    expected[i]);
            abort();
        }
    }
    /* No NON-modifier may be released: a stray key-up for Space or Return would
       be injected into the local session. */
    for (size_t j = 0; j < modCount; ++j) {
        if (mods[j] == 49 || mods[j] == 36) {
            fprintf(stderr, "FAIL non-modifier keycode %u in the reset set\n", mods[j]);
            abort();
        }
    }

    puts("input context tests passed");
    return 0;
}
