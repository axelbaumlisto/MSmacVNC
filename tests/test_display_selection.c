#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "DisplaySelection.h"

static MacVNCDisplayInput makeDisplay(uint32_t id, double x, int pixels)
{
    MacVNCDisplayInput input;
    memset(&input, 0, sizeof(input));
    input.displayID = id;
    input.logicalX = x;
    input.logicalWidth = pixels;
    input.logicalHeight = pixels;
    input.pixelWidth = pixels;
    input.pixelHeight = pixels;
    return input;
}

int main(void)
{
    MacVNCDisplayInput available[3] = {
        makeDisplay(11, 0, 1920),
        makeDisplay(22, 1920, 2560),
        makeDisplay(33, 4480, 1280),
    };
    MacVNCDisplayInput selected[MACVNC_MAX_DISPLAYS];
    size_t count = 999;

    /* ALL keeps every display, in order: the composite framebuffer depends on
       this order matching the layout the caller then builds. */
    assert(macVNCSelectDisplays(available, 3, 1, MACVNC_DISPLAY_ALL,
                                selected, &count) == MACVNC_DISPLAY_SELECTION_OK);
    assert(count == 3);
    assert(selected[0].displayID == 11);
    assert(selected[1].displayID == 22);
    assert(selected[2].displayID == 33);

    /* PRIMARY takes the main display, which need not be index 0. */
    assert(macVNCSelectDisplays(available, 3, 1, MACVNC_DISPLAY_PRIMARY,
                                selected, &count) == MACVNC_DISPLAY_SELECTION_OK);
    assert(count == 1);
    assert(selected[0].displayID == 22);

    /* Main display not in the list: fall back to the first rather than fail,
       otherwise a run with displays attached would capture nothing. */
    assert(macVNCSelectDisplays(available, 3, -1, MACVNC_DISPLAY_PRIMARY,
                                selected, &count) == MACVNC_DISPLAY_SELECTION_OK);
    assert(count == 1);
    assert(selected[0].displayID == 11);

    /* A specific index. */
    assert(macVNCSelectDisplays(available, 3, 0, 2,
                                selected, &count) == MACVNC_DISPLAY_SELECTION_OK);
    assert(count == 1);
    assert(selected[0].displayID == 33);

    /* Out of range must be refused, not silently clamped to a display the user
       did not ask to expose. */
    assert(macVNCSelectDisplays(available, 3, 0, 3, selected, &count) ==
           MACVNC_DISPLAY_SELECTION_NO_SUCH_DISPLAY);
    assert(count == 0);
    assert(macVNCSelectDisplays(available, 3, 0, 99, selected, &count) ==
           MACVNC_DISPLAY_SELECTION_NO_SUCH_DISPLAY);
    assert(count == 0);

    /* No displays (asleep screen). Count is re-poisoned before each call so the
       "*selectedCount is 0" promise is actually tested, not inherited from a
       previous assertion that already left it at 0. */
    count = 999;
    assert(macVNCSelectDisplays(available, 0, -1, MACVNC_DISPLAY_ALL,
                                selected, &count) ==
           MACVNC_DISPLAY_SELECTION_UNSUPPORTED_COUNT);
    assert(count == 0);

    /* More displays than the layout holds. The array really has that many
       entries: passing a bogus count with a short array would be reading out of
       bounds if a future edit validated after the first read. */
    MacVNCDisplayInput overflow[MACVNC_MAX_DISPLAYS + 1];
    for (size_t i = 0; i < MACVNC_MAX_DISPLAYS + 1; ++i)
        overflow[i] = makeDisplay((uint32_t)(100 + i), (double)i * 100, 800);
    count = 999;
    assert(macVNCSelectDisplays(overflow, MACVNC_MAX_DISPLAYS + 1, 0,
                                MACVNC_DISPLAY_ALL, selected, &count) ==
           MACVNC_DISPLAY_SELECTION_UNSUPPORTED_COUNT);
    assert(count == 0);

    /* NULL arguments must not crash, and must still honour the count promise:
       this runs during server start-up. */
    count = 999;
    assert(macVNCSelectDisplays(NULL, 3, 0, MACVNC_DISPLAY_ALL, selected, &count) ==
           MACVNC_DISPLAY_SELECTION_UNSUPPORTED_COUNT);
    assert(count == 0);
    count = 999;
    assert(macVNCSelectDisplays(available, 3, 0, MACVNC_DISPLAY_ALL, NULL, &count) ==
           MACVNC_DISPLAY_SELECTION_UNSUPPORTED_COUNT);
    assert(count == 0);
    /* A NULL count pointer must not be dereferenced. */
    assert(macVNCSelectDisplays(available, 3, 0, MACVNC_DISPLAY_ALL, selected, NULL) ==
           MACVNC_DISPLAY_SELECTION_UNSUPPORTED_COUNT);

    /* --- macVNCSelectDisplayByID: pinned-identity re-resolution --- */

    /* Pinned id present: found regardless of primaryIndex, which this
       function does not even take - identity, not "is it main", is the whole
       point. */
    count = 999;
    assert(macVNCSelectDisplayByID(available, 3, 22, selected, &count) ==
           MACVNC_DISPLAY_SELECTION_OK);
    assert(count == 1);
    assert(selected[0].displayID == 22);

    /* Pinned id absent: refused, never silently substituting a different
       physical display for the one that vanished. */
    count = 999;
    assert(macVNCSelectDisplayByID(available, 3, 44, selected, &count) ==
           MACVNC_DISPLAY_SELECTION_NO_SUCH_DISPLAY);
    assert(count == 0);

    /* Id present but at a DIFFERENT index than before - the exact reordering
       a hot-unplug/replug produces. Same three ids, ids 22 and 33 swapped
       position: the pinned id 33 used to sit at index 2 and now sits at
       index 1, and must still resolve to display 33, not to whatever now
       occupies index 2. */
    MacVNCDisplayInput reordered[3] = {
        available[0],
        available[2],
        available[1],
    };
    count = 999;
    assert(macVNCSelectDisplayByID(reordered, 3, 33, selected, &count) ==
           MACVNC_DISPLAY_SELECTION_OK);
    assert(count == 1);
    assert(selected[0].displayID == 33);

    /* No displays attached (count poisoned first, per the header's promise). */
    count = 999;
    assert(macVNCSelectDisplayByID(available, 0, 22, selected, &count) ==
           MACVNC_DISPLAY_SELECTION_UNSUPPORTED_COUNT);
    assert(count == 0);

    /* NULL arguments must not crash. */
    count = 999;
    assert(macVNCSelectDisplayByID(NULL, 3, 22, selected, &count) ==
           MACVNC_DISPLAY_SELECTION_UNSUPPORTED_COUNT);
    assert(count == 0);
    count = 999;
    assert(macVNCSelectDisplayByID(available, 3, 22, NULL, &count) ==
           MACVNC_DISPLAY_SELECTION_UNSUPPORTED_COUNT);
    assert(count == 0);
    assert(macVNCSelectDisplayByID(available, 3, 22, selected, NULL) ==
           MACVNC_DISPLAY_SELECTION_UNSUPPORTED_COUNT);

    printf("test_display_selection: all assertions passed\n");
    return 0;
}
