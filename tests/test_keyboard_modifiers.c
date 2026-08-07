#include "KeyboardModifierState.h"

#include <assert.h>

int main(void)
{
    MacVNCKeyboardModifierState state = {0};
    assert(macVNCModifierMask(&state) == 0);

    assert(macVNCUpdateModifier(&state, 0xffe1, true));
    assert(macVNCUpdateModifier(&state, 0xffe2, true));
    assert(macVNCModifierMask(&state) & MACVNC_MOD_SHIFT);
    assert(macVNCUpdateModifier(&state, 0xffe1, false));
    assert(macVNCModifierMask(&state) & MACVNC_MOD_SHIFT); /* right still held */
    assert(macVNCUpdateModifier(&state, 0xffe2, false));
    assert(!(macVNCModifierMask(&state) & MACVNC_MOD_SHIFT));

    assert(macVNCUpdateModifier(&state, 0xffe3, true));
    assert(macVNCModifierMask(&state) & MACVNC_MOD_CONTROL);
    assert(macVNCUpdateModifier(&state, 0xffe7, true));
    assert(macVNCModifierMask(&state) & MACVNC_MOD_OPTION);
    assert(macVNCUpdateModifier(&state, 0xffe9, true));
    assert(macVNCModifierMask(&state) & MACVNC_MOD_COMMAND);

    assert(macVNCUpdateModifier(&state, 0x1008ff2b, true));
    assert(macVNCModifierMask(&state) & MACVNC_MOD_FN);
    assert(!macVNCShouldAutoReleaseFn(&state, 'f', true));
    assert(macVNCShouldAutoReleaseFn(&state, 'f', false));
    assert(!macVNCShouldAutoReleaseFn(&state, 0x1008ff2b, false));

    macVNCClearModifiers(&state);
    assert(macVNCModifierMask(&state) == 0);
    return 0;
}
