#include "KeyboardModifierState.h"

#include <string.h>

#define XK_SHIFT_L 0xffe1U
#define XK_SHIFT_R 0xffe2U
#define XK_CONTROL_L 0xffe3U
#define XK_CONTROL_R 0xffe4U
#define XK_META_L 0xffe7U
#define XK_META_R 0xffe8U
#define XK_ALT_L 0xffe9U
#define XK_ALT_R 0xffeaU
#define XK_ISO_LEVEL3_SHIFT 0xfe03U
#define XK_FN 0x1008ff2bU

bool
macVNCUpdateModifier(MacVNCKeyboardModifierState *state,
                     uint32_t keySym,
                     bool down)
{
    if (!state) return false;
    switch (keySym) {
        case XK_SHIFT_L: state->shiftLeft = down; return true;
        case XK_SHIFT_R: state->shiftRight = down; return true;
        case XK_CONTROL_L: state->controlLeft = down; return true;
        case XK_CONTROL_R: state->controlRight = down; return true;
        case XK_META_L: state->metaLeft = down; return true;
        case XK_META_R: state->metaRight = down; return true;
        case XK_ALT_L: state->altLeft = down; return true;
        case XK_ALT_R: state->altRight = down; return true;
        case XK_ISO_LEVEL3_SHIFT: state->level3 = down; return true;
        case XK_FN: state->fn = down; return true;
        default: return false;
    }
}

uint32_t
macVNCModifierMask(const MacVNCKeyboardModifierState *state)
{
    if (!state) return 0;
    uint32_t mask = 0;
    if (state->shiftLeft || state->shiftRight) mask |= MACVNC_MOD_SHIFT;
    if (state->controlLeft || state->controlRight) mask |= MACVNC_MOD_CONTROL;
    /* Preserve macVNC's existing mobile mapping: Meta→Option, Alt→Command. */
    if (state->metaLeft || state->metaRight || state->level3) mask |= MACVNC_MOD_OPTION;
    if (state->altLeft || state->altRight) mask |= MACVNC_MOD_COMMAND;
    if (state->fn) mask |= MACVNC_MOD_FN;
    return mask;
}

bool
macVNCShouldAutoReleaseFn(const MacVNCKeyboardModifierState *state,
                          uint32_t keySym,
                          bool down)
{
    if (!state || !state->fn || down) return false;
    MacVNCKeyboardModifierState copy = *state;
    return !macVNCUpdateModifier(&copy, keySym, false);
}

void
macVNCClearModifiers(MacVNCKeyboardModifierState *state)
{
    if (state) memset(state, 0, sizeof(*state));
}
