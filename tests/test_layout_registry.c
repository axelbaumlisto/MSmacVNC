#include "MacVNCLayoutRegistry.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static void fillLayout(MacVNCDisplayLayout *layout, uint32_t id, int width, int height)
{
    memset(layout, 0, sizeof *layout);
    layout->count = 1;
    layout->width = width;
    layout->height = height;
    layout->displays[0].input.displayID = id;
    layout->displays[0].input.pixelWidth = width;
    layout->displays[0].input.pixelHeight = height;
}

int main(void)
{
    /* --- Publish/Current: no publish before the first Publish() --- */
    assert(macVNCLayoutRegistryCurrent() == NULL);

    /* --- Double-buffer: publish N+1 never writes into the slot Current()
       returned for publish N. --- */
    MacVNCDisplayLayout a, b, c;
    fillLayout(&a, 1, 100, 100);
    fillLayout(&b, 2, 200, 200);
    fillLayout(&c, 3, 300, 300);

    const MacVNCDisplayLayout *pubA = macVNCLayoutRegistryPublish(&a);
    assert(pubA != NULL);
    assert(pubA->displays[0].input.displayID == 1);
    /* Take a byte-identical snapshot of what N pointed at before publishing
       N+1, so a corrupted double-buffer (writing into the slot a live reader
       still holds) is caught even though `pubA` itself is a pointer into
       process memory that a broken implementation could still mutate. */
    MacVNCDisplayLayout snapshotA = *pubA;

    const MacVNCDisplayLayout *pubB = macVNCLayoutRegistryPublish(&b);
    assert(pubB != NULL);
    assert(pubB != pubA); /* the other slot, not the one just read */
    assert(pubB->displays[0].input.displayID == 2);
    assert(memcmp(&snapshotA, pubA, sizeof snapshotA) == 0); /* N untouched by N+1's publish */
    assert(macVNCLayoutRegistryCurrent() == pubB);

    MacVNCDisplayLayout snapshotB = *pubB;
    const MacVNCDisplayLayout *pubC = macVNCLayoutRegistryPublish(&c);
    assert(pubC == pubA); /* two slots: publish 3 reuses publish 1's retired slot */
    assert(pubC->displays[0].input.displayID == 3);
    assert(memcmp(&snapshotB, pubB, sizeof snapshotB) == 0); /* N=2 untouched by N+1's publish */
    assert(macVNCLayoutRegistryCurrent() == pubC);

    /* --- Session generation: strictly monotonic, first claimed value is 1,
       never reused, and there is no reset API - a "second server run in the
       same process" is simulated simply by calling Next() again with no call
       in between that could plausibly reset it; the absence of any such
       call in this whole test file is itself the proof there is nothing to
       call. --- */
    assert(macVNCLayoutRegistryCurrentSessionGeneration() == 0); /* sentinel, never claimed */
    uint64_t g1 = macVNCLayoutRegistryNextSessionGeneration();
    assert(g1 == 1);
    assert(macVNCLayoutRegistryCurrentSessionGeneration() == 1);
    uint64_t previous = g1;
    for (int i = 0; i < 1000; ++i) {
        uint64_t next = macVNCLayoutRegistryNextSessionGeneration();
        assert(next == previous + 1);
        assert(macVNCLayoutRegistryCurrentSessionGeneration() == next);
        previous = next;
    }
    /* "Simulated second server run": more Next() calls, no reset in
       between - generation keeps climbing past where a naive per-run
       counter would have gone back to 1. */
    uint64_t afterManyRuns = macVNCLayoutRegistryNextSessionGeneration();
    assert(afterManyRuns == previous + 1);
    assert(afterManyRuns == 1002); /* g1=1, +1000 loop iterations, +1 more call */

    /* --- Pin: last-write-wins at the registry level (set-once is the
       caller's rule in mac.m, not this layer's - see the header). --- */
    assert(macVNCLayoutRegistryPinnedDisplay() == 0); /* not yet pinned */
    macVNCLayoutRegistryPinDisplay(42);
    assert(macVNCLayoutRegistryPinnedDisplay() == 42);
    macVNCLayoutRegistryPinDisplay(7); /* last-write-wins: registry does not refuse a second Pin */
    assert(macVNCLayoutRegistryPinnedDisplay() == 7);
    macVNCLayoutRegistryResetPin();
    assert(macVNCLayoutRegistryPinnedDisplay() == 0);
    macVNCLayoutRegistryPinDisplay(99);
    assert(macVNCLayoutRegistryPinnedDisplay() == 99);

    printf("layout registry: all assertions passed\n");
    return 0;
}
