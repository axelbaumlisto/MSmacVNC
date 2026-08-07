#include "PointerState.h"

#include <assert.h>

int main(void)
{
    MacVNCPointerState state = {0};
    double x = 0, y = 0;

    assert(macVNCResolvePointerEvent(&state, true, 10, 20, 1, &x, &y));
    assert(x == 10 && y == 20 && state.buttonMask == 1);

    /* Drag movement in a black gap is ignored. */
    assert(!macVNCResolvePointerEvent(&state, false, 0, 0, 1, &x, &y));

    /* Release in a gap is posted at the last valid position. */
    assert(macVNCResolvePointerEvent(&state, false, 0, 0, 0, &x, &y));
    assert(x == 10 && y == 20 && state.buttonMask == 0);

    /* A click initiated in a gap is ignored. */
    MacVNCPointerState fresh = {0};
    assert(!macVNCResolvePointerEvent(&fresh, false, 0, 0, 1, &x, &y));
    assert(!macVNCResolvePointerEvent(&fresh, false, 0, 0, 0, &x, &y));

    assert(macVNCResolvePointerEvent(&fresh, true, -5, 7, 0, &x, &y));
    assert(x == -5 && y == 7);
    return 0;
}
