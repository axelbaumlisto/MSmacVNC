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

    /* No displays (asleep screen) and more than the layout holds. */
    assert(macVNCSelectDisplays(available, 0, -1, MACVNC_DISPLAY_ALL,
                                selected, &count) ==
           MACVNC_DISPLAY_SELECTION_UNSUPPORTED_COUNT);
    assert(count == 0);
    assert(macVNCSelectDisplays(available, MACVNC_MAX_DISPLAYS + 1, 0,
                                MACVNC_DISPLAY_ALL, selected, &count) ==
           MACVNC_DISPLAY_SELECTION_UNSUPPORTED_COUNT);
    assert(count == 0);

    /* NULL arguments must not crash: this runs during server start-up. */
    assert(macVNCSelectDisplays(NULL, 3, 0, MACVNC_DISPLAY_ALL, selected, &count) ==
           MACVNC_DISPLAY_SELECTION_UNSUPPORTED_COUNT);
    assert(macVNCSelectDisplays(available, 3, 0, MACVNC_DISPLAY_ALL, NULL, &count) ==
           MACVNC_DISPLAY_SELECTION_UNSUPPORTED_COUNT);
    assert(macVNCSelectDisplays(available, 3, 0, MACVNC_DISPLAY_ALL, selected, NULL) ==
           MACVNC_DISPLAY_SELECTION_UNSUPPORTED_COUNT);

    printf("test_display_selection: all assertions passed\n");
    return 0;
}
