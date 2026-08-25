#include "DisplaySelection.h"

MacVNCDisplaySelectionResult
macVNCSelectDisplays(const MacVNCDisplayInput *available,
                     size_t availableCount,
                     int primaryIndex,
                     int displayNumber,
                     MacVNCDisplayInput *selected,
                     size_t *selectedCount)
{
    /* Zero the count BEFORE any early return: the header promises it is 0 on
       every non-OK result, and a caller that trusts that while the value is
       untouched garbage would build a layout from uninitialised displays. */
    if (selectedCount)
        *selectedCount = 0;
    if (!available || !selected || !selectedCount)
        return MACVNC_DISPLAY_SELECTION_UNSUPPORTED_COUNT;

    if (availableCount == 0 || availableCount > MACVNC_MAX_DISPLAYS)
        return MACVNC_DISPLAY_SELECTION_UNSUPPORTED_COUNT;

    if (displayNumber == MACVNC_DISPLAY_ALL) {
        for (size_t i = 0; i < availableCount; ++i)
            selected[i] = available[i];
        *selectedCount = availableCount;
        return MACVNC_DISPLAY_SELECTION_OK;
    }

    size_t index;
    if (displayNumber == MACVNC_DISPLAY_PRIMARY) {
        /* Fall back to the first display when the main one is not in the list:
           refusing to start would leave the user with no screen at all. */
        index = (primaryIndex >= 0 && (size_t)primaryIndex < availableCount)
                    ? (size_t)primaryIndex
                    : 0;
    } else if (displayNumber >= 0 && (size_t)displayNumber < availableCount) {
        index = (size_t)displayNumber;
    } else {
        return MACVNC_DISPLAY_SELECTION_NO_SUCH_DISPLAY;
    }

    selected[0] = available[index];
    *selectedCount = 1;
    return MACVNC_DISPLAY_SELECTION_OK;
}
