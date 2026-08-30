#include "MacVNCClamshellPolicy.h"

#include <stddef.h>

MacVNCClamshellAction
macVNCClamshellDecide(MacVNCClamshellInputs inputs)
{
    /* Every term is a reason to be DOWN, so the machine's normal lid behaviour
       is what survives a bug in any one of them. */
    bool wanted = inputs.preferenceEnabled &&
                  inputs.viewerConnected &&
                  inputs.onWallPower &&
                  !inputs.terminating;

    if (wanted == inputs.armed)
        return MacVNCClamshellActionNone;
    return wanted ? MacVNCClamshellActionArm : MacVNCClamshellActionDisarm;
}

MacVNCClamshellAction
macVNCClamshellRecoveryAction(bool markerPresent, bool sameBootSession,
                              bool ownerAlive)
{
    if (!markerPresent)
        return MacVNCClamshellActionNone;
    /* Order matters: the boot test comes first because a marker from an earlier
       boot says nothing about who owns the bit NOW. Disarming on it is how we
       would cancel another app's setting. */
    if (!sameBootSession)
        return MacVNCClamshellActionForgetMarker;
    if (ownerAlive)
        return MacVNCClamshellActionNone;
    return MacVNCClamshellActionDisarm;
}

bool
macVNCClamshellApply(MacVNCClamshellAction action, bool armed,
                     const MacVNCClamshellEffects *effects)
{
    /* Without effects nothing can be performed, so nothing may be claimed. */
    if (effects == NULL || effects->setKernelDisable == NULL ||
        effects->setMarker == NULL)
        return armed;

    switch (action) {
    case MacVNCClamshellActionArm:
        /* Refuse rather than set a bit we could not record. This is the one
           failure where doing nothing is strictly better than trying: an
           unrecorded bit is the state no later run can recover from. */
        if (!effects->setMarker(effects->context, true))
            return armed;
        if (effects->setKernelDisable(effects->context, true) != 0) {
            /* The marker deliberately stays. We cannot observe whether the
               request reached the mask, and a marker we did not need costs one
               spare disarm; a bit we failed to record costs a reboot. */
            return true;
        }
        return true;

    case MacVNCClamshellActionDisarm:
        if (effects->setKernelDisable(effects->context, false) != 0) {
            /* Keep the marker AND keep calling ourselves armed, so the next
               re-evaluation and the next launch both try again. */
            return armed;
        }
        effects->setMarker(effects->context, false);
        return false;

    case MacVNCClamshellActionForgetMarker:
        /* No kernel call: the bit this record described died with its boot. */
        effects->setMarker(effects->context, false);
        return armed;

    case MacVNCClamshellActionNone:
        break;
    }
    return armed;
}
