#pragma once

#include <stdint.h>

/** Convert an RFB/X11 keysym to a UTF-16 BMP code unit, or 0 if unsupported. */
uint16_t macVNCUnicodeForRFBKeySym(uint32_t keySym);
