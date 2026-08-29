#import "MacVNCInput.h"

#include <Carbon/Carbon.h>
#include <pthread.h>
#include <rfb/keysym.h>
#import <AppKit/AppKit.h>

#import "MacVNCCurtainInput.h"   /* MACVNC_CURTAIN_INPUT_EVENT_MAGIC */
#import "RFBKeySym.h"
#import "PointerState.h"
#import "KeyboardModifierState.h"
#import "MacVNCPowerMgmt.h"

/*
 * The server's private event source, TAGGED.
 *
 * Curtain mode installs an event tap that swallows local input, and
 * CGEventPost delivers to taps at the same location, so the remote viewer's
 * own keyboard and pointer arrive at that tap like anyone else's. The tag is
 * how the tap tells them apart and passes them through unmodified.
 *
 * Every injection path in this file, and how each one is identified:
 *   - CGEventCreateKeyboardEvent + CGEventPost (KbdAddEvent, the Fn
 *     auto-release, macVNCInputResetModifiers): built from THIS source, so
 *     they carry the tag.
 *   - CGEventCreateScrollWheelEvent + CGEventPost (PtrAddEvent): same source,
 *     same tag.
 *   - CGPostMouseEvent (PtrAddEvent's move/button path): the legacy API takes
 *     a button MASK plus a position, which is why it is here at all - drags
 *     and double clicks need no synthesis - and it has NO source to tag. It is
 *     identified by the posting process id instead
 *     (kCGEventSourceUnixProcessID == getpid(), measured to be stamped on
 *     these events); see macVNCCurtainInputEventIsSelfInjected.
 *   - No CGWarpMouseCursorPosition anywhere in this file: warping produces no
 *     event for a tap to swallow, and the cursor is moved by the line above.
 *
 * Setting user data on our own private source changes nothing for anyone but a
 * tap: no tap, no difference, which is what keeps a server with the curtain
 * never raised behaving exactly as before.
 */
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

/* Fn key: X keysym and the macOS virtual keycode (used in several places). */
#define MACVNC_KEYSYM_FN   0x1008FF2BU
#define MACVNC_KEYCODE_FN  63

/* A table mapping special keys to keycodes. Static as these are layout-independent.
 * A typed {sym, code} struct avoids the fragile pair-stride of a flat int[]. */
typedef struct { rfbKeySym sym; CGKeyCode code; } MacVNCSpecialKey;
static const MacVNCSpecialKey specialKeyMap[] = {
    /* "Special" keys */
    {XK_space,             49},      /* Space */
    {XK_Return,            36},      /* Return */
    {XK_Delete,           117},      /* Delete */
    {XK_Tab,               48},      /* Tab */
    {XK_Escape,            53},      /* Esc */
    {XK_Caps_Lock,         57},      /* Caps Lock */
    {XK_Num_Lock,          71},      /* Num Lock */
    {XK_Scroll_Lock, 107},      /* Scroll Lock */
    {XK_Pause, 113},      /* Pause */
    {XK_BackSpace, 51},      /* Backspace */
    {XK_Insert, 114},      /* Insert */

    /* Cursor movement */
    {XK_Up, 126},      /* Cursor Up */
    {XK_Down, 125},      /* Cursor Down */
    {XK_Left, 123},      /* Cursor Left */
    {XK_Right, 124},      /* Cursor Right */
    {XK_Page_Up, 116},      /* Page Up */
    {XK_Page_Down, 121},      /* Page Down */
    {XK_Home, 115},      /* Home */
    {XK_End, 119},      /* End */

    /* Numeric keypad */
    {XK_KP_0, 82},      /* KP 0 */
    {XK_KP_1, 83},      /* KP 1 */
    {XK_KP_2, 84},      /* KP 2 */
    {XK_KP_3, 85},      /* KP 3 */
    {XK_KP_4, 86},      /* KP 4 */
    {XK_KP_5, 87},      /* KP 5 */
    {XK_KP_6, 88},      /* KP 6 */
    {XK_KP_7, 89},      /* KP 7 */
    {XK_KP_8, 91},      /* KP 8 */
    {XK_KP_9, 92},      /* KP 9 */
    {XK_KP_Enter, 76},      /* KP Enter */
    {XK_KP_Decimal, 65},      /* KP . */
    {XK_KP_Add, 69},      /* KP + */
    {XK_KP_Subtract, 78},      /* KP - */
    {XK_KP_Multiply, 67},      /* KP * */
    {XK_KP_Divide, 75},      /* KP / */

    /* Function keys */
    {XK_F1, 122},      /* F1 */
    {XK_F2, 120},      /* F2 */
    {XK_F3, 99},      /* F3 */
    {XK_F4, 118},      /* F4 */
    {XK_F5, 96},      /* F5 */
    {XK_F6, 97},      /* F6 */
    {XK_F7, 98},      /* F7 */
    {XK_F8, 100},      /* F8 */
    {XK_F9, 101},      /* F9 */
    {XK_F10, 109},      /* F10 */
    {XK_F11, 103},      /* F11 */
    {XK_F12, 111},      /* F12 */

    /* Modifier keys */
    {XK_Shift_L, 56},      /* Shift Left */
    {XK_Shift_R, 56},      /* Shift Right */
    {XK_Control_L, 59},      /* Ctrl Left */
    {XK_Control_R, 59},      /* Ctrl Right */
    {XK_Meta_L, 58},      /* Logo Left (-> Option) */
    {XK_Meta_R, 58},      /* Logo Right (-> Option) */
    {XK_Alt_L, 55},      /* Alt Left (-> Command) */
    {XK_Alt_R, 55},      /* Alt Right (-> Command) */
    {XK_ISO_Level3_Shift, 61},      /* Alt-Gr (-> Option Right) */
    {MACVNC_KEYSYM_FN, MACVNC_KEYCODE_FN},      /* Fn */
};

/* Index of the first modifier entry in specialKeyMap above. Everything from
   here to the end of the table is a modifier, which is what lets
   macVNCInputResetModifiers derive the keycodes to release instead of
   restating them: a hand-written second list silently missed any modifier
   added later, leaving that key stuck down for the local user. */
#define MACVNC_FIRST_MODIFIER_KEYSYM XK_Shift_L
#define MACVNC_MAX_MODIFIER_KEYCODES 16

/*
 * The distinct keycodes of every modifier in specialKeyMap.
 *
 * De-duplicated: the table maps left and right variants to the SAME keycode
 * (Shift_L and Shift_R are both 56), so releasing per table row would post the
 * same key-up twice.
 */
static size_t macVNCInputCollectModifierKeycodes(unsigned short *out, size_t capacity)
{
    size_t count = 0;
    bool inModifiers = false;
    for (size_t i = 0; i < sizeof(specialKeyMap) / sizeof(specialKeyMap[0]); ++i) {
        if (specialKeyMap[i].sym == MACVNC_FIRST_MODIFIER_KEYSYM)
            inModifiers = true;
        if (!inModifiers)
            continue;
        unsigned short code = (unsigned short)specialKeyMap[i].code;
        bool seen = false;
        for (size_t j = 0; j < count; ++j)
            if (out[j] == code) { seen = true; break; }
        if (!seen && count < capacity)
            out[count++] = code;
    }
    return count;
}

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
    pthread_mutex_lock(&keyboardMutex);
    macVNCClearModifiers(&keyboardModifierState);
    /* Release every modifier the keymap knows about, taken FROM that keymap:
       a separate hand-written list of keycodes went stale the moment a modifier
       was added, and a modifier left down affects the local user's own
       keyboard. */
    unsigned short codes[MACVNC_MAX_MODIFIER_KEYCODES];
    size_t count = macVNCInputCollectModifierKeycodes(codes, sizeof(codes) / sizeof(codes[0]));
    for (size_t i = 0; i < count; ++i) {
        CGEventRef keyUp = CGEventCreateKeyboardEvent(eventSource, codes[i], false);
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
/* Rebuild the char keymaps if the user has switched input source since they
   were built. Called with keyboardMutex held; compare-then-rebuild keeps the
   common path at one TIS call. Stale maps used to mean: switch US->Russian
   mid-session, and every Cyrillic keysym silently degraded to the
   modifier-blind unicode fallback. */
static CFStringRef gMappedSourceID = NULL;
static rfbBool keyboardInit(void);
static void keyboardShutdownLocked(void);

static void
keyboardRefreshIfLayoutChangedLocked(void)
{
    TISInputSourceRef current = TISCopyCurrentKeyboardInputSource();
    if (!current)
        return;
    CFStringRef currentID = (CFStringRef)TISGetInputSourceProperty(
        current, kTISPropertyInputSourceID);
    bool changed = true;
    if (currentID && gMappedSourceID)
        changed = !CFEqual(currentID, gMappedSourceID);
    CFRelease(current);
    if (!changed)
        return;
    keyboardShutdownLocked();
    if (!keyboardInit())
        fprintf(stderr, "macVNC: keyboard layout changed but the new layout "
                        "could not be mapped; keeping no char maps\n");
}

void
KbdAddEvent(rfbBool down, rfbKeySym keySym, struct _rfbClientRec* cl)
{
    (void)cl;
    undim();
    pthread_mutex_lock(&keyboardMutex);
    keyboardRefreshIfLayoutChangedLocked();

    CGKeyCode keyCode = (CGKeyCode)-1;
    for (size_t i = 0; i < sizeof(specialKeyMap) / sizeof(specialKeyMap[0]); ++i) {
        if (specialKeyMap[i].sym == keySym) {
            keyCode = specialKeyMap[i].code;
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
            /* Unicode-string fallback: synthesizes TEXT, not a keystroke. A
               keystroke carries its modifiers; a unicode string with e.g.
               Command set is interpreted by many apps as a SHORTCUT, not as
               the character with a modifier. The fallback is modifier-blind
               by construction, so it must not inherit live modifier flags. */
            keyboardEvent = CGEventCreateKeyboardEvent(eventSource, 0, down);
            if (keyboardEvent)
                CGEventKeyboardSetUnicodeString(keyboardEvent, 1, &unicodeChar);
        }
        CFRelease(character);
    }

    if (keyboardEvent) {
        bool unicodeFallback = (keyCode == (CGKeyCode)-1);
        CGEventSetFlags(keyboardEvent,
                        unicodeFallback ? 0 : currentKeyboardFlags());
        CGEventPost(kCGSessionEventTap, keyboardEvent);
        CFRelease(keyboardEvent);
    }

    /* Mobile viewers can leave Fn latched. Treat it as a one-key modifier. */
    if (!isModifier && autoReleaseFn) {
        macVNCUpdateModifier(&keyboardModifierState, MACVNC_KEYSYM_FN, false);
        CGEventRef fnUp = CGEventCreateKeyboardEvent(eventSource, MACVNC_KEYCODE_FN, false);
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

    /* The injected context is set in ScreenInit before client threads start and
       cleared in macVNCInputShutdown only after rfbShutdownServer(TRUE) has
       joined every client thread. A NULL here means a late/stray event outside
       that window: refuse it locally instead of relying on that invariant. */
    if (!inputScreen || !inputLayout)
        return;

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
    /* Tell LibVNCServer where the cursor is. Clients that advertise the
       PointerPos encoding receive a position update in the next
       FramebufferUpdate, so they can render the cursor locally at the
       exact position without waiting for framebuffer data. Written under
       pointerMutex so concurrent multi-client events cannot tear the fields.

       Published ONLY when the point mapped to real display space. On a
       mapping failure the OS cursor never moved (no event is posted), so
       telling PointerPos clients the clamped framebuffer coordinates would
       be a phantom position the user's cursor is not at. */
    if (validPosition) {
        inputScreen->cursorX = x;
        inputScreen->cursorY = y;
    }
    pthread_mutex_unlock(&pointerMutex);
    if (!shouldPost)
        return;
    CGPoint position = CGPointMake(globalX, globalY);

    /* map buttons 4 5 6 7 to scroll events as per https://github.com/rfbproto/rfbproto/blob/master/rfbproto.rst#745pointerevent
       Scroll directions are mutually exclusive; use else-if so at most one
       event is created (avoids overwriting/leaking a prior CGEvent). */
    if(buttonMask & (1 << 3))
	mouseEvent = CGEventCreateScrollWheelEvent(eventSource, kCGScrollEventUnitLine, 2, 1, 0);
    else if(buttonMask & (1 << 4))
	mouseEvent = CGEventCreateScrollWheelEvent(eventSource, kCGScrollEventUnitLine, 2, -1, 0);
    else if(buttonMask & (1 << 5))
	mouseEvent = CGEventCreateScrollWheelEvent(eventSource, kCGScrollEventUnitLine, 2, 0, 1);
    else if(buttonMask & (1 << 6))
	mouseEvent = CGEventCreateScrollWheelEvent(eventSource, kCGScrollEventUnitLine, 2, 0, -1);

    if (mouseEvent) {
	CGEventPost(kCGSessionEventTap, mouseEvent);
	CFRelease(mouseEvent);
	/* A scroll event (mask bits 4-7) does NOT imply "no pointer movement":
	   trackpad-driven viewers routinely send the new x/y in the SAME
	   PointerEvent as the scroll bit. Swallowing the move here desynced the
	   OS cursor from what PointerPos clients had been told. Fall through to
	   the move/button injection as well. */
    }
    {
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

/* Caller holds keyboardMutex (see macVNCInputShutdown). */
static void
keyboardShutdownLocked(void)
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

    /* kTISPropertyUnicodeKeyLayoutData is NULL for input sources with no uchr
       data (e.g. CJK/handwriting IMEs). CFDataGetBytePtr(NULL) is a contract
       violation and UCKeyTranslate(NULL,...) would crash - so instead of
       failing startup outright (which left such users with NO input at all),
       fall back to the ASCII-capable layout: ASCII keys keep working. */
    CFDataRef layoutData = (CFDataRef)TISGetInputSourceProperty(currentKeyboard, kTISPropertyUnicodeKeyLayoutData);
    keyboardLayout = layoutData ? (const UCKeyboardLayout *)CFDataGetBytePtr(layoutData) : NULL;
    if (!keyboardLayout) {
        fprintf(stderr, "Active keyboard input source has no Unicode layout data; "
                        "falling back to the ASCII-capable layout\n");
        CFRelease(currentKeyboard);
        currentKeyboard = TISCopyCurrentASCIICapableKeyboardInputSource();
        if (!currentKeyboard)
            return FALSE;
        layoutData = (CFDataRef)TISGetInputSourceProperty(currentKeyboard, kTISPropertyUnicodeKeyLayoutData);
        keyboardLayout = layoutData ? (const UCKeyboardLayout *)CFDataGetBytePtr(layoutData) : NULL;
        if (!keyboardLayout) {
            CFRelease(currentKeyboard);
            return FALSE;
        }
    }

    /* CFStringGetCStringPtr may return NULL when no direct buffer exists; copy
       into a local buffer for a safe printf. */
    CFStringRef sourceID = (CFStringRef)TISGetInputSourceProperty(
        currentKeyboard, kTISPropertyInputSourceID);
    char layoutName[256] = "unknown";
    if (sourceID)
        CFStringGetCString(sourceID, layoutName, sizeof(layoutName), kCFStringEncodingUTF8);
    printf("Found keyboard layout '%s'\n", layoutName);

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

	    /* UCKeyTranslate sets realLength=0 (and leaves chars[0] unwritten) for
	       keycodes that produce no character; skip to avoid a bogus mapping
	       from an uninitialized UniChar. */
	    if (realLength < 1)
	        continue;
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

    /* Remember WHICH source these maps describe (may be the ASCII fallback,
       which is why the ID is read from currentKeyboard, not from the system). */
    if (gMappedSourceID)
        CFRelease(gMappedSourceID);
    gMappedSourceID = (CFStringRef)TISGetInputSourceProperty(
        currentKeyboard, kTISPropertyInputSourceID);
    if (gMappedSourceID)
        CFRetain(gMappedSourceID);

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
    /* See the note on eventSource: this is what makes remote input survive a
       raised curtain. */
    CGEventSourceSetUserData(eventSource, MACVNC_CURTAIN_INPUT_EVENT_MAGIC);
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
    /* Under keyboardMutex: KbdAddEvent reads eventSource and the keymaps under
       it, and the join-then-clear ordering that protects us is an INVARIANT OF
       THE CALLER, not of this function. A future caller that clears context
       while a client thread still runs must not turn that mistake into a
       use-after-free for free. */
    pthread_mutex_lock(&keyboardMutex);
    if (eventSource) {
        CFRelease(eventSource);
        eventSource = NULL;
    }
    keyboardShutdownLocked();
    if (gMappedSourceID) {
        CFRelease(gMappedSourceID);
        gMappedSourceID = NULL;
    }
    inputScreen = NULL;
    inputLayout = NULL;
    pthread_mutex_unlock(&keyboardMutex);
}

bool macVNCInputHasResources(void)
{
    return eventSource || charKeyMap || charShiftKeyMap ||
           charAltGrKeyMap || charShiftAltGrKeyMap;
}

#if defined(MACVNC_ENABLE_TEST_HOOKS)
size_t macVNCInputCopyModifierKeycodesForTesting(unsigned short *out, size_t capacity)
{
    /* The production function itself, so the test cannot pass against a
       re-implementation that drifted from what actually runs. */
    return macVNCInputCollectModifierKeycodes(out, capacity);
}
#endif
