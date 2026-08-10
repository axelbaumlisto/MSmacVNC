
/*
 *  OSXvnc Copyright (C) 2001 Dan McGuirk <mcguirk@incompleteness.net>.
 *  Original Xvnc code Copyright (C) 1999 AT&T Laboratories Cambridge.
 *  All Rights Reserved.
 *
 * Cut in two parts by Johannes Schindelin (2001): libvncserver and OSXvnc.
 *
 * Completely revamped and adapted to work with contemporary APIs by Christian Beier (2020).
 *
 * This file implements every system specific function for Mac OS X.
 *
 *  It includes the keyboard function:
 *
     void KbdAddEvent(down, keySym, cl)
        rfbBool down;
        rfbKeySym keySym;
        rfbClientPtr cl;
 *
 *  the mouse function:
 *
     void PtrAddEvent(buttonMask, x, y, cl)
        int buttonMask;
        int x;
        int y;
        rfbClientPtr cl;
 *
 */

#include <Carbon/Carbon.h>
#include <ScreenCaptureKit/ScreenCaptureKit.h>
#include <rfb/rfb.h>
#include <rfb/keysym.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/pwr_mgt/IOPM.h>
#include <stdio.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <arpa/inet.h>
#include <time.h>

#import "ScreenCapturer.h"
#import "RFBKeySym.h"
#import "DisplayLayout.h"
#import "CompositeFramebuffer.h"
#import "PointerState.h"
#import "KeyboardModifierState.h"
#import "ReadinessPolicy.h"
#import "CaptureRate.h"
#import "mac.h"
#import <AppKit/AppKit.h>

/* The main LibVNCServer screen object */
rfbScreenInfoPtr rfbScreen;
/* Operation modes set via AppDelegate */
rfbBool viewOnly = FALSE;

/* One composite framebuffer; uncovered regions remain black. */
void *frameBufferOne;

/* -2 = all displays, -1 = primary, >=0 = one enumerated display. */
int displayNumber = -1;
static MacVNCDisplayLayout displayLayout;
static NSMutableArray<ScreenCapturer *> *screenCapturers;
static rfbBool rfbServerInitialized = FALSE;
static _Atomic int publishedServerPort = -1;
static pthread_mutex_t serverLifecycleMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t compositorMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t pointerMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t keyboardMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t clientLifecycleMutex = PTHREAD_MUTEX_INITIALIZER;
static MacVNCPointerState pointerState;
static MacVNCKeyboardModifierState keyboardModifierState;

typedef struct {
    rfbBool captureCounted;
    MacVNCReadinessPolicy readiness;
} MacVNCClientState;

static rfbBool macVNCPasswordCheck(rfbClientPtr client,
                                   const char *encryptedPassword,
                                   int length);

/* The server's private event source */
CGEventSourceRef eventSource;

/* Screen (un)dimming machinery */
rfbBool preventDimming = FALSE;
rfbBool preventSleep   = TRUE;
static pthread_mutex_t  dimming_mutex;
static unsigned long    dim_time;
static unsigned long    sleep_time;
static mach_port_t      master_dev_port;
static io_connect_t     power_mgt;
static rfbBool initialized            = FALSE;
static rfbBool dim_time_saved         = FALSE;
static rfbBool sleep_time_saved       = FALSE;

/* a dictionary mapping characters to keycodes */
CFMutableDictionaryRef charKeyMap;

/* a dictionary mapping characters obtained by Shift to keycodes */
CFMutableDictionaryRef charShiftKeyMap;

/* a dictionary mapping characters obtained by Alt-Gr to keycodes */
CFMutableDictionaryRef charAltGrKeyMap;

/* a dictionary mapping characters obtained by Shift+Alt-Gr to keycodes */
CFMutableDictionaryRef charShiftAltGrKeyMap;

/* a table mapping special keys to keycodes. static as these are layout-independent */
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

    /* Weirdness I can't figure out */
#if 0
    XK_3270_PrintScreen,     105,     /* PrintScrn */
    ???  94,          50,      /* International */
    XK_Menu,              50,      /* Menu (-> International) */
#endif
};

/* Tile size (pixels) for dirty-region comparison */
#define TILE_SIZE 64
#define INITIAL_READINESS_TIMEOUT_NANOSECONDS (3ULL * NSEC_PER_SEC)

static uint64_t
monotonicNanoseconds(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * NSEC_PER_SEC + (uint64_t)now.tv_nsec;
}

/* Number of currently connected clients (read by AppDelegate for status display) */
_Atomic int vncConnectedClients = 0;


static int
saveDimSettings(void)
{
    if (IOPMGetAggressiveness(power_mgt,
                              kPMMinutesToDim,
                              &dim_time) != kIOReturnSuccess)
        return -1;

    dim_time_saved = TRUE;
    return 0;
}

static int
restoreDimSettings(void)
{
    if (!dim_time_saved)
        return -1;

    if (IOPMSetAggressiveness(power_mgt,
                              kPMMinutesToDim,
                              dim_time) != kIOReturnSuccess)
        return -1;

    dim_time_saved = FALSE;
    dim_time = 0;
    return 0;
}

static int
saveSleepSettings(void)
{
    if (IOPMGetAggressiveness(power_mgt,
                              kPMMinutesToSleep,
                              &sleep_time) != kIOReturnSuccess)
        return -1;

    sleep_time_saved = TRUE;
    return 0;
}

static int
restoreSleepSettings(void)
{
    if (!sleep_time_saved)
        return -1;

    if (IOPMSetAggressiveness(power_mgt,
                              kPMMinutesToSleep,
                              sleep_time) != kIOReturnSuccess)
        return -1;

    sleep_time_saved = FALSE;
    sleep_time = 0;
    return 0;
}


int
dimmingInit(void)
{
    pthread_mutex_init(&dimming_mutex, NULL);

#if __MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_VERSION_12_0
    if (IOMainPort(bootstrap_port, &master_dev_port) != kIOReturnSuccess)
#else
    if (IOMasterPort(bootstrap_port, &master_dev_port) != kIOReturnSuccess)
#endif
        return -1;

    if (!(power_mgt = IOPMFindPowerManagement(master_dev_port)))
        return -1;

    if (preventDimming) {
        if (saveDimSettings() < 0)
            return -1;
        if (IOPMSetAggressiveness(power_mgt,
                                  kPMMinutesToDim, 0) != kIOReturnSuccess)
            return -1;
    }

    if (preventSleep) {
        if (saveSleepSettings() < 0)
            return -1;
        if (IOPMSetAggressiveness(power_mgt,
                                  kPMMinutesToSleep, 0) != kIOReturnSuccess)
            return -1;
    }

    initialized = TRUE;
    return 0;
}


int
undim(void)
{
    int result = -1;

    pthread_mutex_lock(&dimming_mutex);

    if (!initialized)
        goto DONE;

    if (!preventDimming) {
        if (saveDimSettings() < 0)
            goto DONE;
        if (IOPMSetAggressiveness(power_mgt, kPMMinutesToDim, 0) != kIOReturnSuccess)
            goto DONE;
        if (restoreDimSettings() < 0)
            goto DONE;
    }

    if (!preventSleep) {
        if (saveSleepSettings() < 0)
            goto DONE;
        if (IOPMSetAggressiveness(power_mgt, kPMMinutesToSleep, 0) != kIOReturnSuccess)
            goto DONE;
        if (restoreSleepSettings() < 0)
            goto DONE;
    }

    result = 0;

 DONE:
    pthread_mutex_unlock(&dimming_mutex);
    return result;
}


int
dimmingShutdown(void)
{
    int result = -1;

    if (!initialized)
        return 0;

    pthread_mutex_lock(&dimming_mutex);
    if (dim_time_saved)
        if (restoreDimSettings() < 0)
            goto DONE;
    if (sleep_time_saved)
        if (restoreSleepSettings() < 0)
            goto DONE;

    result = 0;
    initialized = FALSE;

 DONE:
    pthread_mutex_unlock(&dimming_mutex);
    return result;
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

static void
resetKeyboardModifiers(void)
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
    CGEventRef mouseEvent = NULL;

    undim();

    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x >= (int)rfbScreen->width) x = (int)rfbScreen->width - 1;
    if (y >= (int)rfbScreen->height) y = (int)rfbScreen->height - 1;

    double globalX = 0, globalY = 0;
    bool validPosition = macVNCMapFramebufferPoint(
        &displayLayout, x, y, &globalX, &globalY, NULL);
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
    rfbScreen->cursorX = x;
    rfbScreen->cursorY = y;

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


/*
  Initialises keyboard handling:
  This creates four keymaps mapping UniChars to keycodes for the current keyboard layout with no shifting modifiers, Shift, Alt-Gr and Shift+Alt-Gr applied, respectively.
 */
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

rfbBool keyboardInit()
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


static void
markCompositeDirty(void *context, int x, int y, int width, int height)
{
    (void)context;
    rfbMarkRectAsModified(rfbScreen, x, y, x + width, y + height);
}

typedef struct {
    rfbClientPtr *items;
    size_t count;
} LockedClientSet;

static rfbBool
lockCurrentClients(LockedClientSet *set)
{
    memset(set, 0, sizeof(*set));
    size_t capacity = 0;
    rfbClientIteratorPtr iterator = rfbGetClientIterator(rfbScreen);
    rfbClientPtr client;
    while ((client = rfbClientIteratorNext(iterator))) {
        if (set->count == capacity) {
            size_t nextCapacity = capacity ? capacity * 2 : 4;
            rfbClientPtr *next = realloc(set->items, nextCapacity * sizeof(*next));
            if (!next) {
                rfbReleaseClientIterator(iterator);
                for (size_t i = 0; i < set->count; ++i)
                    rfbDecrClientRef(set->items[i]);
                free(set->items);
                memset(set, 0, sizeof(*set));
                return FALSE;
            }
            set->items = next;
            capacity = nextCapacity;
        }
        rfbIncrClientRef(client);
        set->items[set->count++] = client;
    }
    rfbReleaseClientIterator(iterator);
    for (size_t i = 0; i < set->count; ++i)
        LOCK(set->items[i]->sendMutex);
    return TRUE;
}

static void
unlockCurrentClients(LockedClientSet *set)
{
    for (size_t i = set->count; i > 0; --i)
        UNLOCK(set->items[i - 1]->sendMutex);
    for (size_t i = 0; i < set->count; ++i)
        rfbDecrClientRef(set->items[i]);
    free(set->items);
    memset(set, 0, sizeof(*set));
}

static void
updateCompositeFrame(CMSampleBufferRef sampleBuffer,
                     const MacVNCDisplayGeometry *geometry)
{
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer)
        return;
    if ((int)CVPixelBufferGetWidth(pixelBuffer) != geometry->input.pixelWidth ||
        (int)CVPixelBufferGetHeight(pixelBuffer) != geometry->input.pixelHeight) {
        rfbErr("Unexpected display %u frame size %zux%zu (expected %dx%d)\n",
               geometry->input.displayID,
               CVPixelBufferGetWidth(pixelBuffer),
               CVPixelBufferGetHeight(pixelBuffer),
               geometry->input.pixelWidth,
               geometry->input.pixelHeight);
        return;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    const uint8_t *source = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer);

    pthread_mutex_lock(&compositorMutex);
    LockedClientSet lockedClients;
    if (!lockCurrentClients(&lockedClients)) {
        pthread_mutex_unlock(&compositorMutex);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        rfbErr("Could not retain current VNC clients for framebuffer update\n");
        return;
    }

    macVNCCompositeDisplayFrame((uint8_t *)rfbScreen->frameBuffer,
                                rfbScreen->width,
                                rfbScreen->height,
                                geometry,
                                source,
                                sourceStride,
                                TILE_SIZE,
                                markCompositeDirty,
                                NULL);

    unlockCurrentClients(&lockedClients);
    pthread_mutex_unlock(&compositorMutex);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
}

static rfbBool
ScreenInit(int port, const char *password, int captureFramesPerSecond)
{
  int bitsPerSample = 8;
  CGDisplayCount displayCount;
  CGDirectDisplayID displays[32];
  CGDirectDisplayID selectedDisplays[MACVNC_MAX_DISPLAYS];
  MacVNCDisplayInput layoutInputs[MACVNC_MAX_DISPLAYS];
  size_t selectedCount = 0;

  if (captureFramesPerSecond < MACVNC_CAPTURE_FPS_MIN ||
      captureFramesPerSecond > MACVNC_CAPTURE_FPS_MAX) {
      rfbErr("Invalid capture rate: %d FPS\n", captureFramesPerSecond);
      return FALSE;
  }
  int framebufferDeferMilliseconds =
      macVNCCaptureFrameIntervalMilliseconds(captureFramesPerSecond);
  if (framebufferDeferMilliseconds == 0) {
      rfbErr("Could not derive framebuffer interval for %d FPS\n",
             captureFramesPerSecond);
      return FALSE;
  }
  rfbLog("Screen capture rate: %d FPS per display; client framebuffer updates deferred %d ms\n",
         captureFramesPerSecond, framebufferDeferMilliseconds);

  /* Build a minimal argv so rfbGetScreen() has a program name but does
     not try to parse any options — we configure everything manually.
     The array must be NULL-terminated; rfbGetScreen() may check argv[argc]. */
  int   dummyArgc       = 1;
  char  progName[]      = "macVNC";
  char *dummyArgv[2]    = {progName, NULL};

  CGGetActiveDisplayList(32, displays, &displayCount);
  if (displayCount == 0 || displayCount > MACVNC_MAX_DISPLAYS) {
      rfbErr("Unsupported active display count: %u\n", displayCount);
      return FALSE;
  }
  for (int i = 0; i < (int)displayCount; ++i) {
      CGRect bounds = CGDisplayBounds(displays[i]);
      printf("Found %s display %d id=%u at (%.0f,%.0f), logical %.0fx%.0f, pixels %zux%zu\n",
             CGDisplayIsMain(displays[i]) ? "primary" : "secondary",
             i, displays[i], bounds.origin.x, bounds.origin.y,
             bounds.size.width, bounds.size.height,
             CGDisplayPixelsWide(displays[i]), CGDisplayPixelsHigh(displays[i]));
  }

  if (displayNumber == -2) {
      selectedCount = displayCount;
      for (size_t i = 0; i < selectedCount; ++i)
          selectedDisplays[i] = displays[i];
      printf("Using all %zu active displays in one framebuffer\n", selectedCount);
  } else if (displayNumber == -1) {
      selectedCount = 1;
      selectedDisplays[0] = CGMainDisplayID();
      printf("Using primary display\n");
  } else if (displayNumber >= 0 && displayNumber < (int)displayCount) {
      selectedCount = 1;
      selectedDisplays[0] = displays[displayNumber];
      printf("Using specified display %d\n", displayNumber);
  } else {
      rfbErr("Specified display %d does not exist\n", displayNumber);
      return FALSE;
  }

  for (size_t i = 0; i < selectedCount; ++i) {
      CGRect bounds = CGDisplayBounds(selectedDisplays[i]);
      layoutInputs[i] = (MacVNCDisplayInput){
          .displayID = selectedDisplays[i],
          .logicalX = bounds.origin.x,
          .logicalY = bounds.origin.y,
          .logicalWidth = bounds.size.width,
          .logicalHeight = bounds.size.height,
          .pixelWidth = (int)CGDisplayPixelsWide(selectedDisplays[i]),
          .pixelHeight = (int)CGDisplayPixelsHigh(selectedDisplays[i]),
      };
  }
  if (!macVNCBuildDisplayLayout(layoutInputs, selectedCount, &displayLayout)) {
      rfbErr("Could not build a non-overlapping RFB display layout\n");
      return FALSE;
  }
  printf("Composite framebuffer: %dx%d\n", displayLayout.width, displayLayout.height);
  memset(&pointerState, 0, sizeof(pointerState));
  macVNCClearModifiers(&keyboardModifierState);


  rfbScreen = rfbGetScreen(&dummyArgc, dummyArgv,
                           displayLayout.width,
                           displayLayout.height,
                           bitsPerSample,
                           3,
                           4);
  if(!rfbScreen) {
      rfbErr("Could not init rfbScreen.\n");
      return FALSE;
  }

  /* Configure listen port. MACVNC_LISTEN restricts the server to a trusted
     IPv4 interface (the Tailscale address in the LaunchAgent). */
  rfbScreen->port = port;
  const char *listenAddress = getenv("MACVNC_LISTEN");
  if (listenAddress && *listenAddress) {
      struct in_addr parsedAddress;
      if (inet_pton(AF_INET, listenAddress, &parsedAddress) != 1) {
          rfbErr("Invalid MACVNC_LISTEN address: %s\n", listenAddress);
          return FALSE;
      }
      rfbScreen->listenInterface = parsedAddress.s_addr;
      rfbScreen->ipv6port = 0;
  } else {
      rfbScreen->ipv6port = port;
  }

  /* Configure password authentication if a password was supplied. */
  if (password && strlen(password) > 0) {
      /* passwdList must outlive rfbScreen; static storage guarantees this. */
      static char *passwdList[2] = {NULL, NULL};
      if (passwdList[0]) { free(passwdList[0]); passwdList[0] = NULL; }
      passwdList[0] = strdup(password);
      rfbScreen->authPasswdData = passwdList;
      rfbScreen->passwordCheck = macVNCPasswordCheck;
  } else {
      rfbErr("A non-empty VNC password is required\n");
      return FALSE;
  }

  rfbScreen->serverFormat.redShift   = bitsPerSample * 2;
  rfbScreen->serverFormat.greenShift = bitsPerSample * 1;
  rfbScreen->serverFormat.blueShift  = 0;

  /* Coalesce dirty regions from every display into one per-client framebuffer
     transmission ceiling. Input processing and deferPtrUpdateTime are unchanged. */
  rfbScreen->deferUpdateTime = framebufferDeferMilliseconds;

  gethostname(rfbScreen->thisHost, 255);

  /* A single zeroed composite canvas keeps uncovered display gaps black. */
  size_t bufSize = (size_t)displayLayout.width * (size_t)displayLayout.height * 4;
  frameBufferOne = calloc(1, bufSize);
  if (!frameBufferOne) {
      rfbErr("Could not allocate composite framebuffer\n");
      return FALSE;
  }
  rfbScreen->frameBuffer = frameBufferOne;

  /* ScreenCaptureKit bakes the correctly oriented system cursor into the frame. */
  rfbScreen->cursor = NULL;

  /* Allow multiple VNC clients to connect simultaneously */
  rfbScreen->alwaysShared = TRUE;

  rfbScreen->ptrAddEvent = PtrAddEvent;
  rfbScreen->kbdAddEvent = KbdAddEvent;

  void (^captureErrorHandler)(NSError *) = ^(NSError *error) {
      rfbLog("Screen capture error: %s\n", [error.description UTF8String]);
      dispatch_async(dispatch_get_main_queue(), ^{
          NSAlert *alert = [[NSAlert alloc] init];
          alert.alertStyle = NSAlertStyleCritical;
          alert.messageText = @"Screen Recording permission required";
          alert.informativeText = @"macVNC needs Screen Recording access to share your displays.";
          [alert addButtonWithTitle:@"Open System Settings"];
          [alert addButtonWithTitle:@"Quit"];
          if ([alert runModal] == NSAlertFirstButtonReturn) {
              [[NSWorkspace sharedWorkspace]
                  openURL:[NSURL URLWithString:
                           @"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
          }
          [NSApp terminate:nil];
      });
  };

  screenCapturers = [[NSMutableArray alloc] initWithCapacity:selectedCount];
  for (size_t i = 0; i < selectedCount; ++i) {
      const MacVNCDisplayGeometry *geometry = &displayLayout.displays[i];
      ScreenCapturer *capturer = [[ScreenCapturer alloc]
          initWithDisplay:geometry->input.displayID
          captureFramesPerSecond:captureFramesPerSecond
          frameHandler:^(CMSampleBufferRef sampleBuffer) {
              updateCompositeFrame(sampleBuffer, geometry);
          }
          errorHandler:captureErrorHandler];
      if (!capturer) {
          rfbErr("Could not initialize display capture mailbox\n");
          return FALSE;
      }
      [screenCapturers addObject:capturer];
      [capturer release];
  }

  rfbInitServer(rfbScreen);
  rfbServerInitialized = TRUE;

  return TRUE;
}


static void
startDisplayCaptures(void)
{
    for (ScreenCapturer *capturer in screenCapturers)
        [capturer startCapture];
}

static void
stopDisplayCapturesAndWait(void)
{
    for (ScreenCapturer *capturer in screenCapturers)
        [capturer stopCaptureAndWait];
}

static BOOL
prepareAuthenticatedClient(rfbClientPtr cl)
{
    MacVNCClientState *state = NULL;
    pthread_mutex_lock(&clientLifecycleMutex);
    state = cl->clientData;
    if (!state) {
        pthread_mutex_unlock(&clientLifecycleMutex);
        return NO;
    }
    if (!state->captureCounted) {
        state->captureCounted = TRUE;
        int previous = atomic_fetch_add(&vncConnectedClients, 1);
        if (previous == 0) {
            startDisplayCaptures();
            rfbLog("First client password accepted; starting %lu display captures\n",
                   (unsigned long)screenCapturers.count);
        }
    }
    BOOL alreadyReady = macVNCReadinessIsReady(&state->readiness);
    pthread_mutex_unlock(&clientLifecycleMutex);

    BOOL allReady = alreadyReady;
    if (!alreadyReady) {
        MacVNCReadinessBudget budget = macVNCReadinessBudgetStart(
            monotonicNanoseconds(), INITIAL_READINESS_TIMEOUT_NANOSECONDS);
        allReady = YES;
        for (ScreenCapturer *capturer in screenCapturers) {
            uint64_t remaining = macVNCReadinessBudgetRemaining(
                &budget, monotonicNanoseconds());
            if (remaining == 0 ||
                ![capturer waitForFirstFrameWithTimeout:
                    (NSTimeInterval)remaining / NSEC_PER_SEC]) {
                allReady = NO;
                break;
            }
        }
        BOOL logTimeout = NO;
        pthread_mutex_lock(&clientLifecycleMutex);
        if (cl->clientData == state)
            logTimeout = macVNCReadinessRecordInitialResult(&state->readiness, allReady);
        pthread_mutex_unlock(&clientLifecycleMutex);
        if (logTimeout)
            rfbLog("Initial display readiness timed out; waiting for late frames\n");
    }
    return allReady;
}

static rfbBool
macVNCPasswordCheck(rfbClientPtr client,
                    const char *encryptedPassword,
                    int length)
{
    if (!rfbCheckPasswordByList(client, encryptedPassword, length))
        return FALSE;
    prepareAuthenticatedClient(client);
    return TRUE;
}

static void
displayHook(rfbClientPtr cl)
{
    pthread_mutex_lock(&clientLifecycleMutex);
    MacVNCClientState *state = cl->clientData;
    BOOL timedOut = state && state->readiness.state == MACVNC_READINESS_TIMED_OUT;
    pthread_mutex_unlock(&clientLifecycleMutex);
    if (!timedOut)
        return;

    BOOL allReady = YES;
    for (ScreenCapturer *capturer in screenCapturers) {
        if (![capturer isCurrentGenerationReady]) {
            allReady = NO;
            break;
        }
    }
    if (!allReady)
        return;

    BOOL logRecovery = NO;
    pthread_mutex_lock(&clientLifecycleMutex);
    if (cl->clientData == state)
        logRecovery = macVNCReadinessPromoteIfReady(&state->readiness, true);
    pthread_mutex_unlock(&clientLifecycleMutex);
    if (logRecovery)
        rfbLog("All display captures became ready after the initial timeout\n");
}

void clientGone(rfbClientPtr cl)
{
    int remaining = atomic_load(&vncConnectedClients);
    pthread_mutex_lock(&clientLifecycleMutex);
    MacVNCClientState *state = cl->clientData;
    if (state && state->captureCounted) {
        remaining = atomic_fetch_sub(&vncConnectedClients, 1) - 1;
        if (remaining <= 0) {
            remaining = 0;
            atomic_store(&vncConnectedClients, 0);
            stopDisplayCapturesAndWait();
            resetKeyboardModifiers();
            rfbLog("Last authenticated client disconnected; %lu display captures stopped and modifiers reset\n",
                   (unsigned long)screenCapturers.count);
        }
    }
    cl->clientData = NULL;
    free(state);
    pthread_mutex_unlock(&clientLifecycleMutex);
    rfbLog("Client %s disconnected (%d authenticated remaining)\n", cl->host, remaining);
}

enum rfbNewClientAction newClient(rfbClientPtr cl)
{
  MacVNCClientState *state = calloc(1, sizeof(*state));
  if (!state)
      return RFB_CLIENT_REFUSE;
  rfbLog("New client connected from %s; capture waits for authenticated frame request\n", cl->host);
  cl->clientData = state;
  cl->clientGoneHook = clientGone;
  cl->viewOnly = viewOnly;
  return RFB_CLIENT_ACCEPT;
}


/* -----------------------------------------------------------------------
 * Public API — called from AppDelegate
 * ----------------------------------------------------------------------- */

static bool
serverHasLifecycleResourcesLocked(void)
{
    return rfbScreen || frameBufferOne || screenCapturers || eventSource ||
           charKeyMap || charShiftKeyMap || charAltGrKeyMap ||
           charShiftAltGrKeyMap;
}

static void
vncServerStopLocked(void)
{
    atomic_store_explicit(&publishedServerPort, -1, memory_order_release);
    /* LibVNCServer >=0.9.15 reverted detached client threads. This call stops
       accepting clients and joins every client/listener thread before lifecycle
       objects they can access are released. */
    if (rfbScreen && rfbServerInitialized)
        rfbShutdownServer(rfbScreen, TRUE);
    rfbServerInitialized = FALSE;

    stopDisplayCapturesAndWait();
    [screenCapturers release];
    screenCapturers = nil;
    atomic_store(&vncConnectedClients, 0);
    if (rfbScreen) {
        rfbScreenCleanup(rfbScreen);
        rfbScreen = NULL;
    }
    dimmingShutdown();
    if (eventSource) {
        CFRelease(eventSource);
        eventSource = NULL;
    }
    keyboardShutdown();
    free(frameBufferOne); frameBufferOne = NULL;
}

rfbBool
vncServerStart(int port, const char *password, int captureFramesPerSecond)
{
    pthread_mutex_lock(&serverLifecycleMutex);
    if (serverHasLifecycleResourcesLocked()) {
        rfbErr("VNC server lifecycle is already initialized\n");
        pthread_mutex_unlock(&serverLifecycleMutex);
        return FALSE;
    }
    atomic_store_explicit(&publishedServerPort, -1, memory_order_release);
    if (!viewOnly) {
        /* Request Accessibility permission with a system prompt so the
           user sees the dialog with the app name, not a terminal name. */
        NSDictionary *opts = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
        if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts)) {
            rfbLog("Server does not have Accessibility permission. "
                   "Grant it in System Settings → Privacy & Security → Accessibility "
                   "and relaunch macVNC.\n");
            goto FAILURE;
        }
    }

    dimmingInit();

    eventSource = CGEventSourceCreate(kCGEventSourceStatePrivate);
    if (!eventSource) {
        rfbLog("Could not create CGEventSource\n");
        goto FAILURE;
    }

    if (!keyboardInit())
        goto FAILURE;

    if (!ScreenInit(port, password, captureFramesPerSecond))
        goto FAILURE;

    rfbScreen->newClientHook = newClient;
    rfbScreen->displayHook = displayHook;
    rfbRunEventLoop(rfbScreen, -1, TRUE);
    atomic_store_explicit(&publishedServerPort, rfbScreen->port, memory_order_release);
    pthread_mutex_unlock(&serverLifecycleMutex);
    return TRUE;

FAILURE:
    vncServerStopLocked();
    pthread_mutex_unlock(&serverLifecycleMutex);
    return FALSE;
}

void
vncServerStop(void)
{
    pthread_mutex_lock(&serverLifecycleMutex);
    vncServerStopLocked();
    pthread_mutex_unlock(&serverLifecycleMutex);
}

int
vncServerGetPort(void)
{
    return atomic_load_explicit(&publishedServerPort, memory_order_acquire);
}

#if defined(MACVNC_ENABLE_TEST_HOOKS)
bool
macVNCServerHasLifecycleResourcesForTesting(void)
{
    pthread_mutex_lock(&serverLifecycleMutex);
    bool hasResources = serverHasLifecycleResourcesLocked();
    pthread_mutex_unlock(&serverLifecycleMutex);
    return hasResources;
}
#endif
