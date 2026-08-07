#include "PointerState.h"

bool
macVNCResolvePointerEvent(MacVNCPointerState *state,
                          bool hasValidPosition,
                          double candidateX,
                          double candidateY,
                          int newButtonMask,
                          double *resolvedX,
                          double *resolvedY)
{
    if (!state)
        return false;
    int buttons = newButtonMask & 0x07;
    int released = state->buttonMask & ~buttons;

    if (hasValidPosition) {
        state->hasLastValidPosition = true;
        state->lastX = candidateX;
        state->lastY = candidateY;
        state->buttonMask = buttons;
        if (resolvedX) *resolvedX = candidateX;
        if (resolvedY) *resolvedY = candidateY;
        return true;
    }

    state->buttonMask = buttons;
    if (!released || !state->hasLastValidPosition)
        return false;
    if (resolvedX) *resolvedX = state->lastX;
    if (resolvedY) *resolvedY = state->lastY;
    return true;
}
