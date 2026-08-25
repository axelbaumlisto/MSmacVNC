#pragma once

#include <rfb/rfb.h>
#include <stdbool.h>
#include "DisplayLayout.h"

/*
 * Keyboard + pointer input injection for the VNC server.
 *
 * Owns the CGEventSource, the four per-modifier keycode maps, the keyboard
 * and pointer mutexes, and the keyboard-modifier / pointer state. The screen
 * geometry it needs (framebuffer bounds + display layout) is injected via
 * macVNCInputSetContext so this module does not reach back into the server
 * core's globals.
 */

/* Create the CGEventSource and build the keyboard layout maps.
 * Returns FALSE on failure (caller should abort startup). */
rfbBool macVNCInputStart(void);

/* Release the CGEventSource and keyboard maps. Safe to call repeatedly. */
void macVNCInputShutdown(void);

/* TRUE while any input resource (event source or a keymap) is still live. */
bool macVNCInputHasResources(void);

/* Inject the active framebuffer screen + display layout used by PtrAddEvent.
 * Call after rfbScreen is created and the layout is built. */
void macVNCInputSetContext(rfbScreenInfoPtr screen, const MacVNCDisplayLayout *layout);

/* Release any latched keyboard modifiers (e.g. when the last client leaves). */
void macVNCInputResetModifiers(void);

/* rfb callbacks — assigned to rfbScreen->kbdAddEvent / ptrAddEvent. */
void KbdAddEvent(rfbBool down, rfbKeySym keySym, struct _rfbClientRec *cl);
void PtrAddEvent(int buttonMask, int x, int y, rfbClientPtr cl);

#if defined(MACVNC_ENABLE_TEST_HOOKS)
/*
 * Copies the modifier keycodes that macVNCInputResetModifiers() will release,
 * derived from the keymap. Exposed so a test can prove the derivation covers
 * every modifier: a stale hand-written list used to leave a modifier down,
 * which affects the LOCAL user's keyboard, not just the client's.
 *
 * Returns the number written (bounded by capacity).
 */
size_t macVNCInputCopyModifierKeycodesForTesting(unsigned short *out, size_t capacity);
#endif
