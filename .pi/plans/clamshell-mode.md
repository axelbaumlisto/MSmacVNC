# Closed-display (clamshell) mode

## What the kernel actually does

Measured against `apple-oss-distributions/xnu` and the macOS SDK, not guessed.

`IOPMrootDomain::shouldSleepOnClamshellClosed()` (`IOPMrootDomain.cpp:4461`):

```c
return !clamshellDisabled && !(desktopMode && acAdaptorConnected) && !clamshellSleepDisableMask;
```

So macOS already stays awake with the lid shut when an external display is
attached **and** the adaptor is in. The bit we can set,
`clamshellSleepDisableMask`, is the third term — it is what lets the machine
keep running with the lid closed and *no* external display.

Userspace reaches it through `kPMSetClamshellSleepState`, which is **12** in
the public SDK header `IOKit/pwr_mgt/IOPMLibDefs.h` — not a private constant,
though the user client it is sent to is undocumented.

## The three properties that shape the whole design

1. **The return code is worthless.** `RootDomainUserClient.cpp:525` runs
   `setClamShellSleepDisable(...)` and then assigns `kIOReturnSuccess`
   unconditionally. `rc == 0` proves only that the message was delivered.
2. **There is no readback.** `AppleClamshellCausesSleep` does reflect the mask,
   but it is only republished from `sendClientClamshellNotification()`, which
   `setClamShellSleepDisable` never calls. Measured: setting the bit changed
   nothing at all in `ioreg -c IOPMrootDomain`. So this feature cannot have the
   verify-or-fail gate that the curtain window has.
3. **The bit outlives the process.** `clientClose` calls `terminate()` and
   `stop()` deallocates the task; neither clears the mask. It is zeroed at
   `IOPMrootDomain.cpp:1768`, i.e. at boot. **If we set it and crash, the Mac
   never sleeps on lid close again until it reboots.**

Point 3 is the exact failure `MacVNCPowerMgmt.m` was written to escape — that
module's header explains that the old code wrote global Energy Saver timers and
"a crash, a force-quit, and the app's own Restart" each left the Mac on "never
sleep" forever. We are deliberately re-entering that class of hazard, so it
needs the mitigation that the pmset code never had.

There is also no refcount: `kClamshellSleepDisablePowerd` is one shared bit for
powerd, us, and any other app using this call. Whoever clears last wins. Two
such apps cannot coexist correctly, and no design of ours can fix that.

## Design

**Arm only while a viewer is connected, and only on wall power.**

Wall power is my own added precondition, not something Amphetamine requires,
and it is one constant to remove if unwanted. The reason: the danger of this
bit is a laptop with the lid shut that refuses to sleep inside a bag. On
battery that ends in a hot, flat machine; on the adaptor the failure is merely
wasted electricity. It also keeps us strictly additive to macOS: native
clamshell needs external display **and** AC, we relax it to AC alone.

**Crash recovery via an owner-stamped marker.** Write the record into defaults
*before* the kernel call, clear it *after* the disarm call. A crash in the gap
then leaves a record with no bit; the opposite order would leave the bit with no
record, which is the permanent failure.

The record must say **who** wrote it (pid) and **in which boot**. A bare
boolean was a defect found in review: the bit is machine-wide and uncounted, so
an anonymous record makes every launch a licence to clear whatever the kernel
currently holds. Two concrete losses. After a reboot the mask is zero but the
record survives, so a user who has since armed Amphetamine's closed-display
mode would have it cancelled by launching macVNC. And this project routinely
runs a second instance on another port under the same bundle id — hence the
same defaults domain — where each launch would disarm the live one. So
recovery acts only on a record from **this** boot whose owner is **gone**.

For the same reason the quit path is **not** unconditional: it withdraws only
what this process holds.

## Tasks

1. `src/MacVNCClamshellPolicy.{h,c}` — pure C. `Decide()` maps
   (preference, viewer, wall power, terminating, armed) to none/arm/disarm;
   `RecoveryAction()` maps (present, same boot, owner alive) to
   none/disarm/forget; `Apply()` performs an action through injected effects in
   the crash-safe order. No IOKit, no Foundation. Mutation-tested.
2. `src/MacVNCClamshellMarker.{h,m}` — the persisted record alone: pid + boot
   session, written through and read back, reporting whether it truly persisted.
3. `src/MacVNCClamshell.{h,m}` — the adapter: selector 12, AC state via
   `IOPSGetProvidingPowerSourceType`, a leaf mutex, level-triggered
   re-evaluation on client count / power source / preference change, and a
   latching, ownership-respecting disarm on quit.
4. Wiring: defaults key + registered `@NO`, `reconcileCaptureState()`,
   termination path (listeners closed **before** the disarm), Preferences
   checkbox, `ARCHITECTURE.md` test count.

## What cannot be verified from here

The bit's effect is only observable by physically closing the lid. No software
trigger republishes the property, and the user is remote. The feature therefore
ships behind an off-by-default preference with an explicit statement that its
effect is unverified on this machine.
