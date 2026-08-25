#pragma once

#include <stdbool.h>
#include <stddef.h>

#include "DisplayLayout.h"

/*
 * Which of the attached displays a run should capture.
 *
 * Separated from the CoreGraphics enumeration around it so the decision is
 * testable: the selection rules (all / primary / one specific) are pure
 * arithmetic over a list, while discovering that list needs a live window
 * server and a display that is not asleep.
 */

/* Selector values carried in MacVNCServerConfig.displayNumber. */
#define MACVNC_DISPLAY_ALL      (-2)
#define MACVNC_DISPLAY_PRIMARY  (-1)

typedef enum {
    MACVNC_DISPLAY_SELECTION_OK = 0,
    /* No displays reported, or more than the layout can hold. */
    MACVNC_DISPLAY_SELECTION_UNSUPPORTED_COUNT,
    /* A specific display was requested and is not attached. */
    MACVNC_DISPLAY_SELECTION_NO_SUCH_DISPLAY,
} MacVNCDisplaySelectionResult;

/*
 * Picks entries from `available` (in order) into `selected`.
 *
 * `primaryIndex` is the index of the main display, or a negative value when it
 * is not among `available`; MACVNC_DISPLAY_PRIMARY then selects the first entry
 * rather than failing, because a run with displays attached must still capture
 * something.
 *
 * On anything but OK, `*selectedCount` is 0.
 */
MacVNCDisplaySelectionResult
macVNCSelectDisplays(const MacVNCDisplayInput *available,
                     size_t availableCount,
                     int primaryIndex,
                     int displayNumber,
                     MacVNCDisplayInput *selected,
                     size_t *selectedCount);
