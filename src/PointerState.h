#pragma once

#include <stdbool.h>

typedef struct {
    bool hasLastValidPosition;
    double lastX;
    double lastY;
    int buttonMask;
} MacVNCPointerState;

/** Resolve a pointer event. Invalid gap positions are ignored except releases. */
bool macVNCResolvePointerEvent(MacVNCPointerState *state,
                               bool hasValidPosition,
                               double candidateX,
                               double candidateY,
                               int newButtonMask,
                               double *resolvedX,
                               double *resolvedY);
