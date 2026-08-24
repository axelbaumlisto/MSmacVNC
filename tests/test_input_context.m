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

    puts("input context tests passed");
    return 0;
}
