#include "DisplaySelection.h"

MacVNCDisplaySelectionResult
macVNCSelectDisplays(const MacVNCDisplayInput *available,
                     size_t availableCount,
                     int primaryIndex,
                     int displayNumber,
                     MacVNCDisplayInput *selected,
                     size_t *selectedCount)
{
    if (!available || !selected || !selectedCount)
        return MACVNC_DISPLAY_SELECTION_UNSUPPORTED_COUNT;

    *selectedCount = 0;

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
