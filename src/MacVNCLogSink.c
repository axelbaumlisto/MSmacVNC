#include "MacVNCLogSink.h"

/* See the header for why 5 MiB and why exactly one rotated generation. */
const size_t kMacVNCLogSinkCapBytes = 5 * 1024 * 1024;

const char *const kMacVNCLogSinkFileName = "macvnc.log";
const char *const kMacVNCLogSinkRotatedFileName = "macvnc.log.1";

bool
macVNCLogSinkShouldRotate(size_t currentFileSize, size_t pendingLineLength)
{
    if (currentFileSize == 0)
        return false;
    return currentFileSize + pendingLineLength > kMacVNCLogSinkCapBytes;
}
