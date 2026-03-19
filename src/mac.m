
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

#import "ScreenCapturer.h"
#import "mac.h"
#import <AppKit/AppKit.h>

/* The main LibVNCServer screen object */
rfbScreenInfoPtr rfbScreen;
/* Operation modes set via AppDelegate */
rfbBool viewOnly = FALSE;

/* Two framebuffers. */
void *frameBufferOne;
void *frameBufferTwo;

/* Pointer to the current backbuffer. */
void *backBuffer;

/* The multi-screen display number chosen by the user */
int displayNumber = -1;
/* The corresponding multi-screen display ID */
CGDirectDisplayID displayID;

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

/* Global shifting modifier states */
rfbBool isShiftDown;
rfbBool isAltGrDown;

/* Tile size (pixels) for dirty-region comparison */
#define TILE_SIZE 64

/* Number of currently connected clients (read by AppDelegate for status display) */
_Atomic int vncConnectedClients = 0;

/* Scale factor: physical pixels per logical point (2.0 on 2× Retina, 1.0 otherwise).
   Computed once at startup and used to convert SCKit dirty-rect coordinates. */
static double displayScale = 1.0;


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
        goto DONE;

    pthread_mutex_lock(&dimming_mutex);
    if (dim_time_saved)
        if (restoreDimSettings() < 0)
            goto DONE;
    if (sleep_time_saved)
        if (restoreSleepSettings() < 0)
            goto DONE;

    result = 0;

 DONE:
    pthread_mutex_unlock(&dimming_mutex);
    return result;
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
    int i;
    CGKeyCode keyCode = -1;
    CGEventRef keyboardEvent;
    int specialKeyFound = 0;

    undim();

    /* look for special key */
    for (i = 0; i < (sizeof(specialKeyMap) / sizeof(int)); i += 2) {
        if (specialKeyMap[i] == keySym) {
            keyCode = specialKeyMap[i+1];
            specialKeyFound = 1;
            break;
        }
    }

    if(specialKeyFound) {
	/* keycode for special key found */
	keyboardEvent = CGEventCreateKeyboardEvent(eventSource, keyCode, down);
	/* save state of shifting modifiers */
	if(keySym == XK_ISO_Level3_Shift)
	    isAltGrDown = down;
	if(keySym == XK_Shift_L || keySym == XK_Shift_R)
	    isShiftDown = down;

    } else {
	/* look for char key */
	size_t keyCodeFromDict;
	CFStringRef charStr = CFStringCreateWithCharacters(kCFAllocatorDefault, (UniChar*)&keySym, 1);
	CFMutableDictionaryRef keyMap = charKeyMap;
	if(isShiftDown && !isAltGrDown)
	    keyMap = charShiftKeyMap;
	if(!isShiftDown && isAltGrDown)
	    keyMap = charAltGrKeyMap;
	if(isShiftDown && isAltGrDown)
	    keyMap = charShiftAltGrKeyMap;

	if (CFDictionaryGetValueIfPresent(keyMap, charStr, (const void **)&keyCodeFromDict)) {
	    /* keycode for ASCII key found */
	    keyboardEvent = CGEventCreateKeyboardEvent(eventSource, keyCodeFromDict, down);
	} else {
	    /* last resort: use the symbol's utf-16 value, does not support modifiers though */
	    keyboardEvent = CGEventCreateKeyboardEvent(eventSource, 0, down);
	    CGEventKeyboardSetUnicodeString(keyboardEvent, 1, (UniChar*)&keySym);
        }

	CFRelease(charStr);
    }

    /* Set the Shift modifier explicitly as MacOS sometimes gets internal state wrong and Shift stuck.
       Only set/clear the Shift bit; leave all other modifier bits untouched. */
    CGEventFlags kbdFlags = CGEventGetFlags(keyboardEvent);
    if (isShiftDown)
        kbdFlags |= kCGEventFlagMaskShift;
    else
        kbdFlags &= ~kCGEventFlagMaskShift;
    CGEventSetFlags(keyboardEvent, kbdFlags);

    CGEventPost(kCGSessionEventTap, keyboardEvent);
    CFRelease(keyboardEvent);
}

/* Synthesize a mouse event. This is not called on the main thread due to rfbRunEventLoop(..,..,TRUE), but it works. */
void
PtrAddEvent(int buttonMask, int x, int y, rfbClientPtr cl)
{
    CGPoint position;
    CGRect displayBounds = CGDisplayBounds(displayID);
    CGEventRef mouseEvent = NULL;

    undim();

    /* Clamp incoming coordinates to the framebuffer (physical pixel) bounds. */
    if (x < 0)                    x = 0;
    if (y < 0)                    y = 0;
    if (x >= (int)rfbScreen->width)  x = (int)rfbScreen->width  - 1;
    if (y >= (int)rfbScreen->height) y = (int)rfbScreen->height - 1;

    /* The VNC framebuffer is sized in physical pixels (from CGDisplayPixelsWide/High),
       but CGPostMouseEvent / CGDisplayBounds work in logical points.
       On a 2× Retina display this scale factor is 0.5; on non-HiDPI it is 1.0.
       Without this conversion the server cursor moves at 2× the speed of the
       client cursor on Retina displays. */
    double scaleX = displayBounds.size.width  / (double)rfbScreen->width;
    double scaleY = displayBounds.size.height / (double)rfbScreen->height;

    position.x = x * scaleX + displayBounds.origin.x;
    position.y = y * scaleY + displayBounds.origin.y;

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


/*
  Compare newBuf and oldBuf in TILE_SIZE x TILE_SIZE tiles and call
  rfbMarkRectAsModified() only for tiles that actually differ.  This
  avoids sending the full framebuffer every frame when only a small
  region of the screen has changed.
  Must be called while client send-mutexes are held.
*/
static void
markChangedRegions(void *newBuf, void *oldBuf, int width, int height)
{
    int tilesX = (width  + TILE_SIZE - 1) / TILE_SIZE;
    int tilesY = (height + TILE_SIZE - 1) / TILE_SIZE;

    for (int ty = 0; ty < tilesY; ty++) {
        int y0 = ty * TILE_SIZE;
        int y1 = y0 + TILE_SIZE < height ? y0 + TILE_SIZE : height;

        for (int tx = 0; tx < tilesX; tx++) {
            int x0 = tx * TILE_SIZE;
            int x1 = x0 + TILE_SIZE < width ? x0 + TILE_SIZE : width;
            int rowBytes = (x1 - x0) * 4;

            for (int row = y0; row < y1; row++) {
                size_t off = ((size_t)row * width + x0) * 4;
                if (memcmp((char *)newBuf + off,
                           (char *)oldBuf + off, rowBytes) != 0) {
                    rfbMarkRectAsModified(rfbScreen, x0, y0, x1, y1);
                    goto next_tile;
                }
            }
        next_tile:;
        }
    }
}


/*
 * Build a RichCursor from an NSCursor and push it to all connected VNC clients.
 * The cursor image is rendered into a BGRA bitmap matching the server pixel format
 * (blueShift=0, greenShift=8, redShift=16), so clients display the correct shape
 * instead of the generic fallback dot.
 */
static void
sendMacOSCursor(rfbScreenInfoPtr screen, NSCursor *nsCursor)
{
    if (!screen || !nsCursor) return;

    NSImage *image   = nsCursor.image;
    NSPoint  hotSpot = nsCursor.hotSpot;

    int w = (int)image.size.width;
    int h = (int)image.size.height;
    if (w <= 0 || h <= 0) return;

    /* Render cursor image into a BGRA CGBitmapContext.
       kCGBitmapByteOrder32Little + kCGImageAlphaPremultipliedFirst on LE hardware
       produces memory layout [B][G][R][A] — identical to our server pixel format. */
    CGColorSpaceRef cs  = CGColorSpaceCreateDeviceRGB();
    uint8_t        *pix = calloc((size_t)w * h * 4, 1);
    CGContextRef    ctx = CGBitmapContextCreate(pix, (size_t)w, (size_t)h, 8, (size_t)w * 4,
                                                cs,
                                                kCGImageAlphaPremultipliedFirst |
                                                kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(pix); return; }

    /* Flip the coordinate system so the image draws right-side up. */
    CGContextTranslateCTM(ctx, 0, h);
    CGContextScaleCTM(ctx, 1.0, -1.0);

    CGImageRef cgImg = [image CGImageForProposedRect:nil context:nil hints:nil];
    if (cgImg)
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cgImg);
    CGContextRelease(ctx);

    /* Build the 1-bit-per-pixel mask from the alpha channel. */
    int      maskStride = (w + 7) / 8;
    uint8_t *mask       = calloc((size_t)maskStride * h, 1);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            /* BGRA: alpha is byte 3 in each 4-byte pixel */
            if (pix[((size_t)y * w + x) * 4 + 3] > 0)
                mask[(size_t)y * maskStride + x / 8] |= (uint8_t)(0x80u >> (x % 8));
        }
    }

    rfbCursorPtr c    = calloc(1, sizeof(rfbCursor));
    c->width          = w;
    c->height         = h;
    c->xhot           = (int)hotSpot.x;
    c->yhot           = (int)hotSpot.y;
    c->richSource     = pix;
    c->cleanUpRichSource = TRUE;
    c->mask           = mask;
    c->cleanUpMask    = TRUE;

    rfbSetCursor(screen, c);
}


static rfbBool
ScreenInit(int port, const char *password)
{
  int bitsPerSample = 8;
  CGDisplayCount displayCount;
  CGDirectDisplayID displays[32];

  /* Build a minimal argv so rfbGetScreen() has a program name but does
     not try to parse any options — we configure everything manually. */
  int    dummyArgc    = 1;
  char  *dummyArgvBuf = "macVNC";
  char **dummyArgv    = &dummyArgvBuf;

  /* grab the active displays */
  CGGetActiveDisplayList(32, displays, &displayCount);
  for (int i=0; i<displayCount; i++) {
      CGRect bounds = CGDisplayBounds(displays[i]);
      printf("Found %s display %d at (%d,%d) and a resolution of %dx%d\n", (CGDisplayIsMain(displays[i]) ? "primary" : "secondary"), i, (int)bounds.origin.x, (int)bounds.origin.y, (int)bounds.size.width, (int)bounds.size.height);
  }
  if(displayNumber < 0) {
      printf("Using primary display as a default\n");
      displayID = CGMainDisplayID();
  } else if (displayNumber < (int)displayCount) {
      printf("Using specified display %d\n", displayNumber);
      displayID = displays[displayNumber];
  } else {
      fprintf(stderr, "Specified display %d does not exist\n", displayNumber);
      return FALSE;
  }

  /* Compute the Retina scale factor once. SCKit dirty-rect coordinates are in
     logical points; multiplying by displayScale converts them to pixel coords. */
  {
      CGRect logicalBounds = CGDisplayBounds(displayID);
      displayScale = logicalBounds.size.width > 0
                     ? (double)CGDisplayPixelsWide(displayID) / logicalBounds.size.width
                     : 1.0;
      printf("Display scale factor: %.1f\n", displayScale);
  }


  rfbScreen = rfbGetScreen(&dummyArgc, &dummyArgv,
			   CGDisplayPixelsWide(displayID),
			   CGDisplayPixelsHigh(displayID),
			   bitsPerSample,
			   3,
			   4);
  if(!rfbScreen) {
      rfbErr("Could not init rfbScreen.\n");
      return FALSE;
  }

  /* Configure listen port. */
  rfbScreen->port     = port;
  rfbScreen->ipv6port = port;

  /* Configure password authentication if a password was supplied. */
  if (password && strlen(password) > 0) {
      /* passwdList must outlive rfbScreen; static storage guarantees this. */
      static char *passwdList[2] = {NULL, NULL};
      if (passwdList[0]) { free(passwdList[0]); passwdList[0] = NULL; }
      passwdList[0] = strdup(password);
      rfbScreen->authPasswdData = passwdList;
      rfbScreen->passwordCheck  = rfbCheckPasswordByList;
  }

  rfbScreen->serverFormat.redShift   = bitsPerSample * 2;
  rfbScreen->serverFormat.greenShift = bitsPerSample * 1;
  rfbScreen->serverFormat.blueShift  = 0;

  /* Send updates immediately — don't batch them. We control frame rate via
     SCKit's minimumFrameInterval so there's no risk of flooding clients. */
  rfbScreen->deferUpdateTime = 0;

  gethostname(rfbScreen->thisHost, 255);

  /* Use calloc so the buffers are zero-initialised; this prevents undefined
     behaviour when markChangedRegions() compares them on the very first frame,
     and ensures no stale data is ever sent to a client. */
  size_t bufSize = (size_t)CGDisplayPixelsWide(displayID) * (size_t)CGDisplayPixelsHigh(displayID) * 4;
  frameBufferOne = calloc(1, bufSize);
  if (!frameBufferOne) {
      rfbErr("Could not allocate framebuffer\n");
      return FALSE;
  }
  frameBufferTwo = calloc(1, bufSize);
  if (!frameBufferTwo) {
      free(frameBufferOne);
      rfbErr("Could not allocate framebuffer\n");
      return FALSE;
  }

  /* back buffer */
  backBuffer = frameBufferOne;
  /* front buffer */
  rfbScreen->frameBuffer = frameBufferTwo;

  /* On macOS 13+ we disable cursor capture in SCKit (showsCursor=NO in ScreenCapturer.m)
     so that the cursor does NOT appear baked into the framebuffer.  Instead we send the
     real macOS cursor shape as a RichCursor after rfbInitServer() below, and keep the
     client's cursor position in sync via rfbScreen->cursorX/Y in PtrAddEvent().
     On macOS 12.x, showsCursor defaults to YES so the cursor is in the framebuffer;
     we clear rfbScreen->cursor to avoid showing two cursors simultaneously. */
  if (@available(macOS 13.0, *)) {
      /* Keep LibVNCServer's cursor enabled; it will be replaced by sendMacOSCursor(). */
  } else {
      rfbScreen->cursor = NULL;
  }

  /* Allow multiple VNC clients to connect simultaneously */
  rfbScreen->alwaysShared = TRUE;

  rfbScreen->ptrAddEvent = PtrAddEvent;
  rfbScreen->kbdAddEvent = KbdAddEvent;

  ScreenCapturer *capturer = [[ScreenCapturer alloc] initWithDisplay: displayID
                                                        frameHandler:^(CMSampleBufferRef sampleBuffer) {
          rfbClientIteratorPtr iterator;
          rfbClientPtr cl;
          int dispW = (int)CGDisplayPixelsWide(displayID);
          int dispH = (int)CGDisplayPixelsHigh(displayID);

          /* Extract frame metadata.  Keep frameInfo in scope — it is used later
             for both the idle-skip check and for SCKit dirty-rect tracking. */
          NSDictionary *frameInfo = nil;
          {
              CFArrayRef arr = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
              if (arr && CFArrayGetCount(arr) > 0)
                  frameInfo = (__bridge NSDictionary *)CFArrayGetValueAtIndex(arr, 0);
          }

          /* Skip frames where ScreenCaptureKit reports no screen change.
             SCFrameStatusIdle means the display contents are identical to
             the previous frame — no copy or VNC update is needed. */
          if ([frameInfo[SCStreamFrameInfoStatus] integerValue] == SCFrameStatusIdle)
              return;

          /*
            Copy new frame to back buffer.
          */
          CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
          if(!pixelBuffer)
              return;

          CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

          /* Copy row-by-row to honour the pixel buffer's actual bytes-per-row
             (which may include alignment padding after each row).  A single
             bulk memcpy using dispW*dispH*4 would read past the end of the
             buffer whenever bytesPerRow > dispW*4. */
          {
              const uint8_t *src      = CVPixelBufferGetBaseAddress(pixelBuffer);
              uint8_t       *dst      = backBuffer;
              size_t         srcStride = CVPixelBufferGetBytesPerRow(pixelBuffer);
              size_t         dstStride = (size_t)dispW * 4;

              if (srcStride == dstStride) {
                  /* Fast path: no padding */
                  memcpy(dst, src, (size_t)dispH * dstStride);
              } else {
                  for (int row = 0; row < dispH; row++) {
                      memcpy(dst, src, dstStride);
                      src += srcStride;
                      dst += dstStride;
                  }
              }
          }

          CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

          /* Lock out client reads. */
          iterator=rfbGetClientIterator(rfbScreen);
          while((cl=rfbClientIteratorNext(iterator))) {
              LOCK(cl->sendMutex);
          }
          rfbReleaseClientIterator(iterator);

          /* Swap framebuffers. */
          if (backBuffer == frameBufferOne) {
              backBuffer = frameBufferTwo;
              rfbScreen->frameBuffer = frameBufferOne;
          } else {
              backBuffer = frameBufferOne;
              rfbScreen->frameBuffer = frameBufferTwo;
          }

          /*
            Mark only the screen regions that actually changed so that VNC
            clients receive minimal update rectangles.

            On macOS 14+ SCKit provides the dirty rectangles directly in the
            frame metadata — no pixel comparison needed.  On older systems we
            fall back to our own tile-based comparison.
          */
          if (@available(macOS 14.0, *)) {
              NSArray<NSValue *> *dirty = frameInfo[SCStreamFrameInfoDirtyRects];
              NSNumber           *scaleN = frameInfo[SCStreamFrameInfoContentScale];
              double              scale  = scaleN ? scaleN.doubleValue : displayScale;

              if (dirty.count > 0) {
                  for (NSValue *rv in dirty) {
                      CGRect r = rv.CGRectValue;
                      /* Dirty rects are in logical points; convert to physical pixels. */
                      int x1 = MAX(0,     (int)floor(r.origin.x                   * scale));
                      int y1 = MAX(0,     (int)floor(r.origin.y                   * scale));
                      int x2 = MIN(dispW, (int)ceil((r.origin.x + r.size.width)  * scale));
                      int y2 = MIN(dispH, (int)ceil((r.origin.y + r.size.height) * scale));
                      if (x2 > x1 && y2 > y1)
                          rfbMarkRectAsModified(rfbScreen, x1, y1, x2, y2);
                  }
              } else {
                  /* No dirty-rect info — mark full frame (safe fallback). */
                  rfbMarkRectAsModified(rfbScreen, 0, 0, dispW, dispH);
              }
          } else {
              /* macOS 12–13: compare tile by tile. */
              markChangedRegions(rfbScreen->frameBuffer, backBuffer, dispW, dispH);
          }

          /* Swapping framebuffers finished, reenable client reads. */
          iterator=rfbGetClientIterator(rfbScreen);
          while((cl=rfbClientIteratorNext(iterator))) {
              UNLOCK(cl->sendMutex);
          }
          rfbReleaseClientIterator(iterator);

      } errorHandler:^(NSError *error) {
          rfbLog("Screen capture error: %s\n", [error.description UTF8String]);

          /* Show a user-friendly alert on the main thread instead of crashing.
             This keeps the app alive so the user can grant Screen Recording
             permission in System Settings and relaunch without a crash loop. */
          dispatch_async(dispatch_get_main_queue(), ^{
              NSAlert *alert = [[NSAlert alloc] init];
              alert.alertStyle      = NSAlertStyleCritical;
              alert.messageText     = @"Screen Recording permission required";
              alert.informativeText = @"macVNC needs Screen Recording access to share your display.\n\n"
                                      @"Enable it in:\nSystem Settings → Privacy & Security → Screen Recording\n\n"
                                      @"Then relaunch macVNC.";
              [alert addButtonWithTitle:@"Open System Settings"];
              [alert addButtonWithTitle:@"Quit"];

              if ([alert runModal] == NSAlertFirstButtonReturn) {
                  [[NSWorkspace sharedWorkspace]
                      openURL:[NSURL URLWithString:
                               @"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
              }
              [NSApp terminate:nil];
          });
      }];
  [capturer startCapture];

  rfbInitServer(rfbScreen);

  /* Send the macOS arrow cursor as a RichCursor so clients display a proper
     arrow shape instead of the generic fallback dot. */
  sendMacOSCursor(rfbScreen, [NSCursor arrowCursor]);

  return TRUE;
}


void clientGone(rfbClientPtr cl)
{
    vncConnectedClients--;
    rfbLog("Client %s disconnected (%d remaining)\n", cl->host, (int)vncConnectedClients);
}

enum rfbNewClientAction newClient(rfbClientPtr cl)
{
  rfbLog("New client connected from %s\n", cl->host);
  vncConnectedClients++;
  cl->clientGoneHook = clientGone;
  cl->viewOnly = viewOnly;

  return(RFB_CLIENT_ACCEPT);
}


/* -----------------------------------------------------------------------
 * Public API — called from AppDelegate
 * ----------------------------------------------------------------------- */

rfbBool
vncServerStart(int port, const char *password)
{
    if (!viewOnly) {
        /* Request Accessibility permission with a system prompt so the
           user sees the dialog with the app name, not a terminal name. */
        NSDictionary *opts = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
        if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts)) {
            rfbLog("Server does not have Accessibility permission. "
                   "Grant it in System Settings → Privacy & Security → Accessibility "
                   "and relaunch macVNC.\n");
            return FALSE;
        }
    }

    dimmingInit();

    eventSource = CGEventSourceCreate(kCGEventSourceStatePrivate);
    if (!eventSource) {
        rfbLog("Could not create CGEventSource\n");
        return FALSE;
    }

    if (!keyboardInit())
        return FALSE;

    if (!ScreenInit(port, password))
        return FALSE;

    rfbScreen->newClientHook = newClient;
    rfbRunEventLoop(rfbScreen, -1, TRUE);

    return TRUE;
}

void
vncServerStop(void)
{
    if (rfbScreen) {
        rfbShutdownServer(rfbScreen, TRUE);
        rfbScreenCleanup(rfbScreen);
        rfbScreen = NULL;
    }
    dimmingShutdown();
    if (eventSource) {
        CFRelease(eventSource);
        eventSource = NULL;
    }
    free(frameBufferOne); frameBufferOne = NULL;
    free(frameBufferTwo); frameBufferTwo = NULL;
}

int
vncServerGetPort(void)
{
    if (!rfbScreen)
        return -1;
    return rfbScreen->port;
}
