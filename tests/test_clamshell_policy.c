/*
 * Closed-display mode decides whether to set a global kernel bit that the
 * kernel will NOT clear when this process dies.
 *
 * That asymmetry is what these assertions are really about. Failing to arm
 * costs the user a Mac that sleeps when they wanted it awake - annoying, and
 * fixed by opening the lid. Failing to DISARM, or arming without recording
 * that we did, leaves every future lid close on this machine unable to sleep
 * until it reboots, with nothing in the UI to explain why. So the ordering
 * cases below are not paperwork: they are the difference between a bug and a
 * bug the user cannot undo.
 */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "MacVNCClamshellPolicy.h"

/* ---- a recorder standing in for defaults + IOKit ---- */

#define MAX_STEPS 8

typedef struct {
    char steps[MAX_STEPS][32];
    int count;
    int kernelResult;   /* what setKernelDisable returns */
    int kernelCalls;
    bool markerFails;   /* the preferences domain refuses to persist */
} Recorder;

static void
record(Recorder *r, const char *what)
{
    if (r->count < MAX_STEPS)
        snprintf(r->steps[r->count++], sizeof r->steps[0], "%s", what);
}

static bool
recMarker(void *ctx, bool present)
{
    Recorder *r = (Recorder *)ctx;
    record(r, present ? "marker+" : "marker-");
    return !r->markerFails;
}

static int
recKernel(void *ctx, bool disable)
{
    Recorder *r = (Recorder *)ctx;
    record(r, disable ? "kernel+" : "kernel-");
    r->kernelCalls++;
    return r->kernelResult;
}

static MacVNCClamshellEffects
effectsFor(Recorder *r)
{
    MacVNCClamshellEffects fx;
    fx.setMarker = recMarker;
    fx.setKernelDisable = recKernel;
    fx.context = r;
    return fx;
}

static bool
stepsAre(const Recorder *r, const char *a, const char *b)
{
    int want = (a ? 1 : 0) + (b ? 1 : 0);
    if (r->count != want)
        return false;
    if (a && strcmp(r->steps[0], a) != 0)
        return false;
    if (b && strcmp(r->steps[1], b) != 0)
        return false;
    return true;
}

static MacVNCClamshellInputs
inputs(bool pref, bool viewer, bool ac, bool armed)
{
    MacVNCClamshellInputs in;
    in.preferenceEnabled = pref;
    in.viewerConnected = viewer;
    in.onWallPower = ac;
    in.terminating = false;
    in.armed = armed;
    return in;
}

/* ---- the decision ---- */

static void
testEveryPreconditionIsRequired(void)
{
    /* Only the all-true row may arm. Enumerated rather than spot-checked so a
       term silently dropped from the conjunction cannot pass. */
    for (int bits = 0; bits < 8; ++bits) {
        bool pref = (bits & 1) != 0;
        bool viewer = (bits & 2) != 0;
        bool ac = (bits & 4) != 0;
        bool all = pref && viewer && ac;

        MacVNCClamshellAction fromDown =
            macVNCClamshellDecide(inputs(pref, viewer, ac, false));
        assert(fromDown == (all ? MacVNCClamshellActionArm
                                : MacVNCClamshellActionNone));

        MacVNCClamshellAction fromUp =
            macVNCClamshellDecide(inputs(pref, viewer, ac, true));
        assert(fromUp == (all ? MacVNCClamshellActionNone
                              : MacVNCClamshellActionDisarm));
    }
}

static void
testTheThreeWaysBackDown(void)
{
    /* Each precondition must be able to bring an armed machine back on its
       own: the user unticks the box, the viewer leaves, the plug comes out. */
    assert(macVNCClamshellDecide(inputs(false, true, true, true)) ==
           MacVNCClamshellActionDisarm);
    assert(macVNCClamshellDecide(inputs(true, false, true, true)) ==
           MacVNCClamshellActionDisarm);
    assert(macVNCClamshellDecide(inputs(true, true, false, true)) ==
           MacVNCClamshellActionDisarm);
}

static void
testDecisionIsIdempotent(void)
{
    assert(macVNCClamshellDecide(inputs(true, true, true, true)) ==
           MacVNCClamshellActionNone);
    assert(macVNCClamshellDecide(inputs(false, false, false, false)) ==
           MacVNCClamshellActionNone);
}

static void
testQuittingRefusesToArmAndReleases(void)
{
    /* The quit window is the one time a fresh connection must not arm: the
       backstop disarm sits behind a teardown the quit path may abandon, so an
       arm accepted here can outlive the process. */
    MacVNCClamshellInputs in = inputs(true, true, true, false);
    in.terminating = true;
    assert(macVNCClamshellDecide(in) == MacVNCClamshellActionNone);

    in.armed = true;
    assert(macVNCClamshellDecide(in) == MacVNCClamshellActionDisarm);
}

static void
testRecoveryNeedsOwnershipNotJustAMarker(void)
{
    /* No record: nothing to do. */
    assert(macVNCClamshellRecoveryAction(false, false, false) ==
           MacVNCClamshellActionNone);
    assert(macVNCClamshellRecoveryAction(false, true, true) ==
           MacVNCClamshellActionNone);

    /* A record from an EARLIER boot describes a bit the kernel already zeroed.
       Issuing a disarm on it is how we would cancel Amphetamine's setting on
       the next launch after a reboot - so: drop the record, touch nothing. */
    assert(macVNCClamshellRecoveryAction(true, false, false) ==
           MacVNCClamshellActionForgetMarker);
    assert(macVNCClamshellRecoveryAction(true, false, true) ==
           MacVNCClamshellActionForgetMarker);

    /* Our boot, owner still running: another live instance owns the bit. This
       project runs a second instance on another port under the SAME bundle id,
       so "a marker exists" would otherwise make each launch disarm the other. */
    assert(macVNCClamshellRecoveryAction(true, true, true) ==
           MacVNCClamshellActionNone);

    /* Our boot, owner gone: the one case that is genuinely ours to clean up. */
    assert(macVNCClamshellRecoveryAction(true, true, false) ==
           MacVNCClamshellActionDisarm);
}

static void
testForgetMarkerNeverTouchesTheKernel(void)
{
    Recorder r = {0};
    MacVNCClamshellEffects fx = effectsFor(&r);
    bool armed = macVNCClamshellApply(MacVNCClamshellActionForgetMarker, false, &fx);
    assert(!armed);
    assert(stepsAre(&r, "marker-", NULL));
    assert(r.kernelCalls == 0);
}

static void
testUnrecordableMarkerRefusesTheArm(void)
{
    Recorder r = {0};
    r.markerFails = true;
    MacVNCClamshellEffects fx = effectsFor(&r);
    bool armed = macVNCClamshellApply(MacVNCClamshellActionArm, false, &fx);
    /* A bit we cannot record is a bit no later run can recover. Refusing is
       strictly better than trying: the feature simply does not engage. */
    assert(!armed);
    assert(stepsAre(&r, "marker+", NULL));
    assert(r.kernelCalls == 0);
}

/* ---- the ordering ---- */

static void
testArmRecordsBeforeItActs(void)
{
    Recorder r = {0};
    MacVNCClamshellEffects fx = effectsFor(&r);
    bool armed = macVNCClamshellApply(MacVNCClamshellActionArm, false, &fx);
    assert(armed);
    /* Marker first. Crashing between the two then leaves a marker and no bit,
       which the next launch cleans up for free. */
    assert(stepsAre(&r, "marker+", "kernel+"));
}

static void
testDisarmClearsTheBitBeforeForgettingIt(void)
{
    Recorder r = {0};
    MacVNCClamshellEffects fx = effectsFor(&r);
    bool armed = macVNCClamshellApply(MacVNCClamshellActionDisarm, true, &fx);
    assert(!armed);
    /* Kernel first. Clearing the marker first and then dying would strand the
       bit with nothing recording it. */
    assert(stepsAre(&r, "kernel-", "marker-"));
}

static void
testFailedArmStillCountsAsArmed(void)
{
    Recorder r = {0};
    r.kernelResult = -1;
    MacVNCClamshellEffects fx = effectsFor(&r);
    bool armed = macVNCClamshellApply(MacVNCClamshellActionArm, false, &fx);
    /* We cannot see the mask, so a rejected call and a delivered one look
       identical. Assume the worst and keep both the marker and the state. */
    assert(armed);
    assert(stepsAre(&r, "marker+", "kernel+"));
}

static void
testFailedDisarmKeepsTheMarkerAndRetries(void)
{
    Recorder r = {0};
    r.kernelResult = -1;
    MacVNCClamshellEffects fx = effectsFor(&r);
    bool armed = macVNCClamshellApply(MacVNCClamshellActionDisarm, true, &fx);
    assert(armed);
    /* The marker must NOT be cleared: it is the only thing that will make the
       next launch try again. */
    assert(stepsAre(&r, "kernel-", NULL));

    /* And because we still call ourselves armed, the next evaluation asks for
       a disarm again rather than settling. */
    assert(macVNCClamshellDecide(inputs(false, false, false, armed)) ==
           MacVNCClamshellActionDisarm);
}

static void
testNoneTouchesNothing(void)
{
    Recorder r = {0};
    MacVNCClamshellEffects fx = effectsFor(&r);
    assert(macVNCClamshellApply(MacVNCClamshellActionNone, true, &fx));
    assert(!macVNCClamshellApply(MacVNCClamshellActionNone, false, &fx));
    assert(r.count == 0);
}

static void
testMissingEffectsChangeNothing(void)
{
    /* A half-built effects table must not let us believe we armed. */
    assert(macVNCClamshellApply(MacVNCClamshellActionArm, false, NULL) == false);
    assert(macVNCClamshellApply(MacVNCClamshellActionDisarm, true, NULL) == true);

    Recorder r = {0};
    MacVNCClamshellEffects half = effectsFor(&r);
    half.setKernelDisable = NULL;
    assert(macVNCClamshellApply(MacVNCClamshellActionArm, false, &half) == false);
    assert(r.count == 0);

    half = effectsFor(&r);
    half.setMarker = NULL;
    assert(macVNCClamshellApply(MacVNCClamshellActionArm, false, &half) == false);
    assert(r.count == 0);
    assert(r.kernelCalls == 0);
}

int
main(void)
{
    testEveryPreconditionIsRequired();
    testTheThreeWaysBackDown();
    testDecisionIsIdempotent();
    testQuittingRefusesToArmAndReleases();
    testRecoveryNeedsOwnershipNotJustAMarker();
    testForgetMarkerNeverTouchesTheKernel();
    testUnrecordableMarkerRefusesTheArm();
    testArmRecordsBeforeItActs();
    testDisarmClearsTheBitBeforeForgettingIt();
    testFailedArmStillCountsAsArmed();
    testFailedDisarmKeepsTheMarkerAndRetries();
    testNoneTouchesNothing();
    testMissingEffectsChangeNothing();

    puts("test_clamshell_policy: all assertions passed");
    return 0;
}
