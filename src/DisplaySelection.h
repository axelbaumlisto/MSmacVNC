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

/*
 * Picks the single entry in `available` whose displayID equals
 * `pinnedDisplayID`, regardless of where it sits in the list.
 *
 * A `displayNumber >= 0` selection is resolved by POSITION only once, the
 * first time a run sees the desk (macVNCSelectDisplays above); every later
 * re-resolution - a capture-liveness re-arm, mid-session - must follow the
 * DISPLAY IDENTITY that first resolution picked, not whatever now sits at
 * that same position, because a desk event (unplug/replug in a different
 * order, a new display enumerated ahead of an existing one) can reorder
 * CoreGraphics' list without the user ever touching the pinned setting.
 * Selecting by position on every re-arm would silently move a live capture
 * to a different physical monitor; this function is what makes "follow the
 * display, not the slot" possible to test without CoreGraphics.
 *
 * Never substitutes a different display: MACVNC_DISPLAY_SELECTION_NO_SUCH_DISPLAY
 * when `pinnedDisplayID` is not currently attached, exactly as a
 * caller-visible "the specific thing you asked to keep watching is gone"
 * rather than a silent switch to whatever else happens to be around.
 */
MacVNCDisplaySelectionResult
macVNCSelectDisplayByID(const MacVNCDisplayInput *available,
                        size_t availableCount,
                        uint32_t pinnedDisplayID,
                        MacVNCDisplayInput *selected,
                        size_t *selectedCount);
