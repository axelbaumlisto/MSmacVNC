/*
 * Only the rotation decision is testable without a filesystem, and it is the
 * one part of the log sink that can silently do the wrong thing: rotate too
 * early and lose otherwise-recoverable history, rotate too late and let the
 * file grow forever, or - the failure mode that looked obvious in review and
 * was not - loop forever rotating an empty file because one logged line
 * (a full display list, say) is bigger than the cap by itself.
 *
 * MacVNCLogSink.m's file handling, mutex and rfbLog/rfbErr installation are
 * glue with no decision left in them once this function returns the right
 * answer, exactly like the split between DisplayLayout.c and mac.m's canvas
 * swap.
 */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "MacVNCLogSink.h"

static void
testWellUnderCapDoesNotRotate(void)
{
    assert(!macVNCLogSinkShouldRotate(1024, 80));
}

static void
testExactlyAtCapDoesNotRotate(void)
{
    /* The pending line lands EXACTLY on the cap: it still fits, so this must
       not rotate - ">" in the header's contract, not ">=". */
    assert(!macVNCLogSinkShouldRotate(kMacVNCLogSinkCapBytes - 80, 80));
}

static void
testOneByteOverCapRotates(void)
{
    assert(macVNCLogSinkShouldRotate(kMacVNCLogSinkCapBytes - 79, 80));
}

static void
testFarOverCapRotates(void)
{
    assert(macVNCLogSinkShouldRotate(kMacVNCLogSinkCapBytes, 1));
    assert(macVNCLogSinkShouldRotate(kMacVNCLogSinkCapBytes * 3, 1));
}

static void
testEmptyFileNeverRotatesEvenForAnOversizedLine(void)
{
    /* The loop-forever case: a single line bigger than the whole cap must
       not repeatedly "rotate" a file that is already empty. */
    assert(!macVNCLogSinkShouldRotate(0, kMacVNCLogSinkCapBytes + 1));
    assert(!macVNCLogSinkShouldRotate(0, 1));
    assert(!macVNCLogSinkShouldRotate(0, 0));
}

static void
testZeroLengthLineNeverTipsAnAlreadyFullFile(void)
{
    /* A zero-length pending write can happen (vsnprintf truncation edge, or
       a caller logging an empty format) and must not itself be blamed for
       crossing the cap when the file was already exactly at it. */
    assert(!macVNCLogSinkShouldRotate(kMacVNCLogSinkCapBytes, 0));
}

static void
testShippedCapAndNamesAreWhatOperatorsWillActuallySee(void)
{
    /* Pinned so a change to any of the three is a deliberate diff to this
       test, not a silent rename of the file someone is tailing after an
       outage. */
    assert(kMacVNCLogSinkCapBytes == 5 * 1024 * 1024);
    assert(strcmp(kMacVNCLogSinkFileName, "macvnc.log") == 0);
    assert(strcmp(kMacVNCLogSinkRotatedFileName, "macvnc.log.1") == 0);
}

int
main(void)
{
    testWellUnderCapDoesNotRotate();
    testExactlyAtCapDoesNotRotate();
    testOneByteOverCapRotates();
    testFarOverCapRotates();
    testEmptyFileNeverRotatesEvenForAnOversizedLine();
    testZeroLengthLineNeverTipsAnAlreadyFullFile();
    testShippedCapAndNamesAreWhatOperatorsWillActuallySee();

    puts("test_log_sink: all assertions passed");
    return 0;
}
