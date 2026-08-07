#pragma once

#include <stdbool.h>
#include <stdint.h>

enum {
    MACVNC_MOD_SHIFT   = 1u << 0,
    MACVNC_MOD_CONTROL = 1u << 1,
    MACVNC_MOD_OPTION  = 1u << 2,
    MACVNC_MOD_COMMAND = 1u << 3,
    MACVNC_MOD_FN      = 1u << 4,
};

typedef struct {
    bool shiftLeft, shiftRight;
    bool controlLeft, controlRight;
    bool metaLeft, metaRight;
    bool altLeft, altRight;
    bool level3;
    bool fn;
} MacVNCKeyboardModifierState;

bool macVNCUpdateModifier(MacVNCKeyboardModifierState *state,
                          uint32_t keySym,
                          bool down);
uint32_t macVNCModifierMask(const MacVNCKeyboardModifierState *state);
bool macVNCShouldAutoReleaseFn(const MacVNCKeyboardModifierState *state,
                               uint32_t keySym,
                               bool down);
void macVNCClearModifiers(MacVNCKeyboardModifierState *state);
