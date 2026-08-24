#import "MacVNCInput.h"

#include <Carbon/Carbon.h>
#include <pthread.h>
#include <rfb/keysym.h>
#import <AppKit/AppKit.h>

#import "RFBKeySym.h"
#import "PointerState.h"
#import "KeyboardModifierState.h"
#import "MacVNCPowerMgmt.h"

/* The server's private event source */
static CGEventSourceRef eventSource;

/* Character->keycode maps for the current layout: base, Shift, Alt-Gr, Shift+Alt-Gr. */
static CFMutableDictionaryRef charKeyMap;
static CFMutableDictionaryRef charShiftKeyMap;
static CFMutableDictionaryRef charAltGrKeyMap;
static CFMutableDictionaryRef charShiftAltGrKeyMap;

static pthread_mutex_t pointerMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t keyboardMutex = PTHREAD_MUTEX_INITIALIZER;
static MacVNCPointerState pointerState;
static MacVNCKeyboardModifierState keyboardModifierState;

/* Injected screen geometry (owned by the server core). */
static rfbScreenInfoPtr inputScreen;
static const MacVNCDisplayLayout *inputLayout;

/* A table mapping special keys to keycodes. Static as these are layout-independent. */
static int specialKeyMap[] = {
    /* "Special" keys */
    XK_space,             49,      /* Space */
    XK_Return,            36,      /* Return */
    XK_Delete,           117,      /* Delete */
    XK_Tab,               48,      /* Tab */
    XK_Escape,            53,      /* Esc */
    XK_Caps_Lock,         57,      /* Caps Lock */
    XK_Num_Lock,          71,      /* Num Lock */
    XK_Scroll_Lock,      107,      /* Scroll Lock */
    XK_Pause,            113,      /* Pause */
    XK_BackSpace,         51,      /* Backspace */
    XK_Insert,           114,      /* Insert */

    /* Cursor movement */
    XK_Up,               126,      /* Cursor Up */
    XK_Down,             125,      /* Cursor Down */
    XK_Left,             123,      /* Cursor Left */
    XK_Right,            124,      /* Cursor Right */
    XK_Page_Up,          116,      /* Page Up */
    XK_Page_Down,        121,      /* Page Down */
    XK_Home,             115,      /* Home */
    XK_End,              119,      /* End */

    /* Numeric keypad */
    XK_KP_0,              82,      /* KP 0 */
    XK_KP_1,              83,      /* KP 1 */
    XK_KP_2,              84,      /* KP 2 */
    XK_KP_3,              85,      /* KP 3 */
    XK_KP_4,              86,      /* KP 4 */
    XK_KP_5,              87,      /* KP 5 */
    XK_KP_6,              88,      /* KP 6 */
    XK_KP_7,              89,      /* KP 7 */
    XK_KP_8,              91,      /* KP 8 */
    XK_KP_9,              92,      /* KP 9 */
    XK_KP_Enter,          76,      /* KP Enter */
    XK_KP_Decimal,        65,      /* KP . */
    XK_KP_Add,            69,      /* KP + */
    XK_KP_Subtract,       78,      /* KP - */
    XK_KP_Multiply,       67,      /* KP * */
    XK_KP_Divide,         75,      /* KP / */

    /* Function keys */
    XK_F1,               122,      /* F1 */
    XK_F2,               120,      /* F2 */
    XK_F3,                99,      /* F3 */
    XK_F4,               118,      /* F4 */
    XK_F5,                96,      /* F5 */
    XK_F6,                97,      /* F6 */
    XK_F7,                98,      /* F7 */
    XK_F8,               100,      /* F8 */
    XK_F9,               101,      /* F9 */
    XK_F10,              109,      /* F10 */
    XK_F11,              103,      /* F11 */
    XK_F12,              111,      /* F12 */

    /* Modifier keys */
    XK_Shift_L,           56,      /* Shift Left */
    XK_Shift_R,           56,      /* Shift Right */
    XK_Control_L,         59,      /* Ctrl Left */
    XK_Control_R,         59,      /* Ctrl Right */
    XK_Meta_L,            58,      /* Logo Left (-> Option) */
    XK_Meta_R,            58,      /* Logo Right (-> Option) */
    XK_Alt_L,             55,      /* Alt Left (-> Command) */
    XK_Alt_R,             55,      /* Alt Right (-> Command) */
    XK_ISO_Level3_Shift,  61,      /* Alt-Gr (-> Option Right) */
    0x1008FF2B,           63,      /* Fn */
};

void macVNCInputSetContext(rfbScreenInfoPtr screen, const MacVNCDisplayLayout *layout)
{
    inputScreen = screen;
    inputLayout = layout;
}

static CGEventFlags
currentKeyboardFlags(void)
{
    uint32_t mask = macVNCModifierMask(&keyboardModifierState);
    CGEventFlags flags = 0;
    if (mask & MACVNC_MOD_SHIFT) flags |= kCGEventFlagMaskShift;
    if (mask & MACVNC_MOD_CONTROL) flags |= kCGEventFlagMaskControl;
    if (mask & MACVNC_MOD_OPTION) flags |= kCGEventFlagMaskAlternate;
    if (mask & MACVNC_MOD_COMMAND) flags |= kCGEventFlagMaskCommand;
    if (mask & MACVNC_MOD_FN) flags |= kCGEventFlagMaskSecondaryFn;
    return flags;
}

void macVNCInputResetModifiers(void)
{
    static const CGKeyCode modifierKeyCodes[] = {56, 59, 58, 55, 61, 63};
    pthread_mutex_lock(&keyboardMutex);
    macVNCClearModifiers(&keyboardModifierState);
    for (size_t i = 0; i < sizeof(modifierKeyCodes) / sizeof(modifierKeyCodes[0]); ++i) {
        CGEventRef keyUp = CGEventCreateKeyboardEvent(eventSource, modifierKeyCodes[i], false);
        if (keyUp) {
            CGEventSetFlags(keyUp, 0);
            CGEventPost(kCGSessionEventTap, keyUp);
            CFRelease(keyUp);
        }
    }
    pthread_mutex_unlock(&keyboardMutex);
}

/*
  Synthesize a keyboard event. This is not called on the main thread due to rfbRunEventLoop(..,..,TRUE), but it works.
  We first look up the incoming keysym in the keymap for special keys (and save state of the shifting modifiers).
  If the incoming keysym does not map to a special key, the char keymaps pertaining to the respective shifting modifier are used
  in order to allow for keyboard combos with other modifiers.
  As a last resort, the incoming keysym is simply used as a Unicode value. This way MacOS does not support any modifiers though.
*/
void
KbdAddEvent(rfbBool down, rfbKeySym keySym, struct _rfbClientRec* cl)
{
    (void)cl;
    undim();
    pthread_mutex_lock(&keyboardMutex);

    CGKeyCode keyCode = (CGKeyCode)-1;
    for (size_t i = 0; i < sizeof(specialKeyMap) / sizeof(specialKeyMap[0]); i += 2) {
        if ((rfbKeySym)specialKeyMap[i] == keySym) {
            keyCode = (CGKeyCode)specialKeyMap[i + 1];
            break;
        }
    }

    bool isModifier = macVNCUpdateModifier(&keyboardModifierState, keySym, down);
    bool autoReleaseFn = macVNCShouldAutoReleaseFn(&keyboardModifierState, keySym, down);
    CGEventRef keyboardEvent = NULL;

    if (keyCode != (CGKeyCode)-1) {
        keyboardEvent = CGEventCreateKeyboardEvent(eventSource, keyCode, down);
    } else {
        UniChar unicodeChar = macVNCUnicodeForRFBKeySym(keySym);
        if (!unicodeChar) {
            pthread_mutex_unlock(&keyboardMutex);
            return;
        }
        size_t keyCodeFromDictionary;
        bool shift = (macVNCModifierMask(&keyboardModifierState) & MACVNC_MOD_SHIFT) != 0;
        bool level3 = keyboardModifierState.level3;
        CFMutableDictionaryRef keyMap = charKeyMap;
        if (shift && !level3) keyMap = charShiftKeyMap;
        if (!shift && level3) keyMap = charAltGrKeyMap;
        if (shift && level3) keyMap = charShiftAltGrKeyMap;
        CFStringRef character = CFStringCreateWithCharacters(kCFAllocatorDefault, &unicodeChar, 1);
        if (CFDictionaryGetValueIfPresent(keyMap, character,
                                          (const void **)&keyCodeFromDictionary)) {
            keyboardEvent = CGEventCreateKeyboardEvent(
                eventSource, (CGKeyCode)keyCodeFromDictionary, down);
        } else {
            keyboardEvent = CGEventCreateKeyboardEvent(eventSource, 0, down);
            if (keyboardEvent)
                CGEventKeyboardSetUnicodeString(keyboardEvent, 1, &unicodeChar);
        }
        CFRelease(character);
    }

    if (keyboardEvent) {
        CGEventSetFlags(keyboardEvent, currentKeyboardFlags());
        CGEventPost(kCGSessionEventTap, keyboardEvent);
        CFRelease(keyboardEvent);
    }

    /* Mobile viewers can leave Fn latched. Treat it as a one-key modifier. */
    if (!isModifier && autoReleaseFn) {
        macVNCUpdateModifier(&keyboardModifierState, 0x1008ff2bU, false);
        CGEventRef fnUp = CGEventCreateKeyboardEvent(eventSource, 63, false);
        if (fnUp) {
            CGEventSetFlags(fnUp, currentKeyboardFlags());
            CGEventPost(kCGSessionEventTap, fnUp);
            CFRelease(fnUp);
        }
        rfbLog("Auto-released latched Fn modifier after key event\n");
    }
    pthread_mutex_unlock(&keyboardMutex);
}

/* Synthesize a mouse event. This is not called on the main thread due to rfbRunEventLoop(..,..,TRUE), but it works. */
void
PtrAddEvent(int buttonMask, int x, int y, rfbClientPtr cl)
{
    (void)cl;
    CGEventRef mouseEvent = NULL;

    undim();

    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x >= (int)inputScreen->width) x = (int)inputScreen->width - 1;
    if (y >= (int)inputScreen->height) y = (int)inputScreen->height - 1;

    double globalX = 0, globalY = 0;
    bool validPosition = macVNCMapFramebufferPoint(
        inputLayout, x, y, &globalX, &globalY, NULL);
    pthread_mutex_lock(&pointerMutex);
    bool shouldPost = macVNCResolvePointerEvent(
        &pointerState, validPosition, globalX, globalY, buttonMask, &globalX, &globalY);
    pthread_mutex_unlock(&pointerMutex);
    if (!shouldPost)
        return;
    CGPoint position = CGPointMake(globalX, globalY);

    /* Tell LibVNCServer where the cursor is. Clients that advertise the
       PointerPos encoding receive a position update in the next
       FramebufferUpdate, so they can render the cursor locally at the
       exact position without waiting for framebuffer data. */
    inputScreen->cursorX = x;
    inputScreen->cursorY = y;

    /* map buttons 4 5 6 7 to scroll events as per https://github.com/rfbproto/rfbproto/blob/master/rfbproto.rst#745pointerevent */
    if(buttonMask & (1 << 3))
	mouseEvent = CGEventCreateScrollWheelEvent(eventSource, kCGScrollEventUnitLine, 2, 1, 0);
    if(buttonMask & (1 << 4))
	mouseEvent = CGEventCreateScrollWheelEvent(eventSource, kCGScrollEventUnitLine, 2, -1, 0);
    if(buttonMask & (1 << 5))
	mouseEvent = CGEventCreateScrollWheelEvent(eventSource, kCGScrollEventUnitLine, 2, 0, 1);
    if(buttonMask & (1 << 6))
	mouseEvent = CGEventCreateScrollWheelEvent(eventSource, kCGScrollEventUnitLine, 2, 0, -1);

    if (mouseEvent) {
	CGEventPost(kCGSessionEventTap, mouseEvent);
	CFRelease(mouseEvent);
    }
    else {
	/*
	  Use the deprecated CGPostMouseEvent API here as we get a buttonmask plus position which is pretty low-level
	  whereas CGEventCreateMouseEvent is expecting higher-level events. This allows for direct injection of
	  double clicks and drags whereas we would need to synthesize these events for the high-level API.
	 */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	CGPostMouseEvent(position, TRUE, 3,
			 (buttonMask & (1 << 0)) ? TRUE : FALSE,
			 (buttonMask & (1 << 2)) ? TRUE : FALSE,
			 (buttonMask & (1 << 1)) ? TRUE : FALSE);
#pragma clang diagnostic pop
    }
}

static void
keyboardShutdown(void)
{
    CFMutableDictionaryRef *keyMaps[] = {
        &charKeyMap,
        &charShiftKeyMap,
        &charAltGrKeyMap,
        &charShiftAltGrKeyMap,
    };
    for (size_t i = 0; i < sizeof(keyMaps) / sizeof(keyMaps[0]); ++i) {
        if (*keyMaps[i]) {
            CFRelease(*keyMaps[i]);
            *keyMaps[i] = NULL;
        }
    }
}

/*
  Initialises keyboard handling:
  This creates four keymaps mapping UniChars to keycodes for the current keyboard layout with no shifting modifiers, Shift, Alt-Gr and Shift+Alt-Gr applied, respectively.
 */
static rfbBool keyboardInit(void)
{
    size_t i, keyCodeCount=128;
    TISInputSourceRef currentKeyboard = TISCopyCurrentKeyboardInputSource();
    const UCKeyboardLayout *keyboardLayout;

    if(!currentKeyboard) {
	fprintf(stderr, "Could not get current keyboard info\n");
	return FALSE;
    }

    keyboardLayout = (const UCKeyboardLayout *)CFDataGetBytePtr(TISGetInputSourceProperty(currentKeyboard, kTISPropertyUnicodeKeyLayoutData));

    printf("Found keyboard layout '%s'\n", CFStringGetCStringPtr(TISGetInputSourceProperty(currentKeyboard, kTISPropertyInputSourceID), kCFStringEncodingUTF8));

    charKeyMap = CFDictionaryCreateMutable(kCFAllocatorDefault, keyCodeCount, &kCFCopyStringDictionaryKeyCallBacks, NULL);
    charShiftKeyMap = CFDictionaryCreateMutable(kCFAllocatorDefault, keyCodeCount, &kCFCopyStringDictionaryKeyCallBacks, NULL);
    charAltGrKeyMap = CFDictionaryCreateMutable(kCFAllocatorDefault, keyCodeCount, &kCFCopyStringDictionaryKeyCallBacks, NULL);
    charShiftAltGrKeyMap = CFDictionaryCreateMutable(kCFAllocatorDefault, keyCodeCount, &kCFCopyStringDictionaryKeyCallBacks, NULL);

    if(!charKeyMap || !charShiftKeyMap || !charAltGrKeyMap || !charShiftAltGrKeyMap) {
	fprintf(stderr, "Could not create keymaps\n");
        CFRelease(currentKeyboard);
	return FALSE;
    }

    /* Loop through every keycode to find the character it is mapping to. */
    for (i = 0; i < keyCodeCount; ++i) {
	UInt32 deadKeyState = 0;
	UniChar chars[4];
	UniCharCount realLength;
	UInt32 m, modifiers[] = {0, kCGEventFlagMaskShift, kCGEventFlagMaskAlternate, kCGEventFlagMaskShift|kCGEventFlagMaskAlternate};

	/* do this for no modifier, shift and alt-gr applied */
	for(m = 0; m < sizeof(modifiers) / sizeof(modifiers[0]); ++m) {
	    UCKeyTranslate(keyboardLayout,
			   i,
			   kUCKeyActionDisplay,
			   (modifiers[m] >> 16) & 0xff,
			   LMGetKbdType(),
			   kUCKeyTranslateNoDeadKeysBit,
			   &deadKeyState,
			   sizeof(chars) / sizeof(chars[0]),
			   &realLength,
			   chars);

	    CFStringRef string = CFStringCreateWithCharacters(kCFAllocatorDefault, chars, 1);
	    if(string) {
		switch(modifiers[m]) {
		case 0:
		    CFDictionaryAddValue(charKeyMap, string, (const void *)i);
		    break;
		case kCGEventFlagMaskShift:
		    CFDictionaryAddValue(charShiftKeyMap, string, (const void *)i);
		    break;
		case kCGEventFlagMaskAlternate:
		    CFDictionaryAddValue(charAltGrKeyMap, string, (const void *)i);
		    break;
		case kCGEventFlagMaskShift|kCGEventFlagMaskAlternate:
		    CFDictionaryAddValue(charShiftAltGrKeyMap, string, (const void *)i);
		    break;
		}

		CFRelease(string);
	    }
	}
    }

    CFRelease(currentKeyboard);

    return TRUE;
}

rfbBool macVNCInputStart(void)
{
    eventSource = CGEventSourceCreate(kCGEventSourceStatePrivate);
    if (!eventSource) {
        rfbLog("Could not create CGEventSource\n");
        return FALSE;
    }
    memset(&pointerState, 0, sizeof(pointerState));
    macVNCClearModifiers(&keyboardModifierState);
    if (!keyboardInit()) {
        macVNCInputShutdown();
        return FALSE;
    }
    return TRUE;
}

void macVNCInputShutdown(void)
{
    if (eventSource) {
        CFRelease(eventSource);
        eventSource = NULL;
    }
    keyboardShutdown();
    inputScreen = NULL;
    inputLayout = NULL;
}

bool macVNCInputHasResources(void)
{
    return eventSource || charKeyMap || charShiftKeyMap ||
           charAltGrKeyMap || charShiftAltGrKeyMap;
}
