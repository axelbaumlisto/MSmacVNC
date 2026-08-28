#include "MacVNCCurtainPolicy.h"

#include <string.h>

/* UTF-16 surrogate range. The tap hands us code UNITS, so a character outside
   the BMP arrives as two of them and has to be rejoined before it can be
   encoded - see the bytes-not-code-points note in the header. */
#define HIGH_SURROGATE_MIN 0xD800u
#define HIGH_SURROGATE_MAX 0xDBFFu
#define LOW_SURROGATE_MIN  0xDC00u
#define LOW_SURROGATE_MAX  0xDFFFu

/* Attempts past this add nothing: the delay saturated at the cap long before,
   and the counter must not be allowed to wrap. */
#define MAX_COUNTED_FAILURES 32u

/*
 * Compares the 8 effective bytes with no early exit: every byte is read on
 * every call, so the time taken says nothing about how much of the secret was
 * right. `volatile` keeps the accumulation from being optimised into the short
 * circuit it deliberately is not.
 */
static bool
effectiveBytesEqual(const uint8_t *a, const uint8_t *b)
{
    volatile uint8_t diff = 0;
    for (size_t i = 0; i < MACVNC_CURTAIN_SECRET_EFFECTIVE_BYTES; ++i)
        diff |= (uint8_t)(a[i] ^ b[i]);
    return diff == 0;
}

/* The first 8 bytes, zero-padded - the same bytes LibVNCServer's DES keys
   itself from, which is why a longer password compares equal to its own
   8-byte prefix. */
static void
effectiveBytes(const void *bytes, size_t length, uint8_t out[MACVNC_CURTAIN_SECRET_EFFECTIVE_BYTES])
{
    size_t used = length < MACVNC_CURTAIN_SECRET_EFFECTIVE_BYTES
                      ? length
                      : MACVNC_CURTAIN_SECRET_EFFECTIVE_BYTES;
    memset(out, 0, MACVNC_CURTAIN_SECRET_EFFECTIVE_BYTES);
    if (used > 0)
        memcpy(out, bytes, used);
}

/* Every outcome ends here: the typed bytes never outlive the attempt that
   produced them, and neither does half a surrogate pair. */
static void
clearBuffer(MacVNCCurtainPolicy *policy)
{
    memset(policy->typed, 0, sizeof(policy->typed));
    policy->typedLength = 0;
    policy->pendingHighSurrogate = 0;
}

/* Doubling, then flat at the cap. Computed by repeated doubling rather than a
   shift so a large attempt count cannot turn into undefined behaviour. */
static uint64_t
throttleDelay(unsigned failedAttempts)
{
    uint64_t delay = MACVNC_CURTAIN_THROTTLE_STEP_NANOSECONDS;
    if (failedAttempts == 0)
        return 0;
    for (unsigned i = 1; i < failedAttempts; ++i) {
        if (delay >= MACVNC_CURTAIN_THROTTLE_CAP_NANOSECONDS)
            break;
        delay *= 2;
    }
    return delay > MACVNC_CURTAIN_THROTTLE_CAP_NANOSECONDS
               ? MACVNC_CURTAIN_THROTTLE_CAP_NANOSECONDS
               : delay;
}

/* Appends one Unicode scalar as UTF-8. A scalar that does not fit WHOLE is
   dropped whole, so the buffer is always valid UTF-8 and a bounded buffer can
   never hold a truncated character. Returns whether anything was stored. */
static bool
appendScalar(MacVNCCurtainPolicy *policy, uint32_t scalar)
{
    uint8_t encoded[4];
    size_t length;

    if (scalar < 0x80u) {
        encoded[0] = (uint8_t)scalar;
        length = 1;
    } else if (scalar < 0x800u) {
        encoded[0] = (uint8_t)(0xC0u | (scalar >> 6));
        encoded[1] = (uint8_t)(0x80u | (scalar & 0x3Fu));
        length = 2;
    } else if (scalar < 0x10000u) {
        encoded[0] = (uint8_t)(0xE0u | (scalar >> 12));
        encoded[1] = (uint8_t)(0x80u | ((scalar >> 6) & 0x3Fu));
        encoded[2] = (uint8_t)(0x80u | (scalar & 0x3Fu));
        length = 3;
    } else {
        encoded[0] = (uint8_t)(0xF0u | (scalar >> 18));
        encoded[1] = (uint8_t)(0x80u | ((scalar >> 12) & 0x3Fu));
        encoded[2] = (uint8_t)(0x80u | ((scalar >> 6) & 0x3Fu));
        encoded[3] = (uint8_t)(0x80u | (scalar & 0x3Fu));
        length = 4;
    }

    if (policy->typedLength + length > sizeof(policy->typed))
        return false;

    memcpy(policy->typed + policy->typedLength, encoded, length);
    policy->typedLength += length;
    return true;
}

/* Return was pressed: this is the whole decision. */
static MacVNCCurtainUnlockOutcome
evaluate(MacVNCCurtainPolicy *policy, uint64_t nowNanoseconds)
{
    uint8_t typedEffective[MACVNC_CURTAIN_SECRET_EFFECTIVE_BYTES];
    effectiveBytes(policy->typed, policy->typedLength, typedEffective);
    bool granted = effectiveBytesEqual(typedEffective, policy->secret);
    memset(typedEffective, 0, sizeof(typedEffective));

    if (granted) {
        /* One-shot: the curtain this policy guarded is coming down, and a
           policy left armed with the secret still in it is both a password
           sitting in memory for no reason and a curtain that could be raised
           again without a deliberate re-arm. */
        macVNCCurtainPolicyReset(policy);
        return MacVNCCurtainUnlockGranted;
    }

    clearBuffer(policy);
    if (policy->failedAttempts < MAX_COUNTED_FAILURES)
        policy->failedAttempts++;
    policy->throttleUntilNanoseconds = nowNanoseconds + throttleDelay(policy->failedAttempts);
    return MacVNCCurtainUnlockRejected;
}

bool
macVNCCurtainPolicyArm(MacVNCCurtainPolicy *policy,
                       const char *secret,
                       size_t secretLength)
{
    if (!policy)
        return false;

    /* Cleared FIRST, so every failure path below leaves a disarmed policy
       rather than the previous secret still armed. */
    memset(policy, 0, sizeof(*policy));

    if (!secret || secretLength == 0)
        return false;

    effectiveBytes(secret, secretLength, policy->secret);
    policy->armed = true;
    return true;
}

void
macVNCCurtainPolicyReset(MacVNCCurtainPolicy *policy)
{
    if (!policy)
        return;
    memset(policy, 0, sizeof(*policy));
}

MacVNCCurtainUnlockOutcome
macVNCCurtainPolicyFeed(MacVNCCurtainPolicy *policy,
                        const uint16_t *utf16Units,
                        size_t unitCount,
                        uint64_t nowNanoseconds)
{
    MacVNCCurtainUnlockOutcome outcome = MacVNCCurtainUnlockIgnored;

    if (!policy || !policy->armed)
        return MacVNCCurtainUnlockIgnored;

    if (macVNCCurtainPolicyThrottledAt(policy, nowNanoseconds)) {
        /* Throttled means nothing is read at all - not accumulated, not
           compared, not counted. Counting keystrokes made during the wait
           would let a frustrated user extend their own lockout. */
        clearBuffer(policy);
        return MacVNCCurtainUnlockIgnored;
    }

    for (size_t i = 0; i < unitCount && utf16Units; ++i) {
        uint32_t unit = utf16Units[i];

        if (policy->pendingHighSurrogate != 0) {
            uint16_t high = policy->pendingHighSurrogate;
            policy->pendingHighSurrogate = 0;
            if (unit >= LOW_SURROGATE_MIN && unit <= LOW_SURROGATE_MAX) {
                uint32_t scalar = 0x10000u + (((uint32_t)high - HIGH_SURROGATE_MIN) << 10) +
                                  (unit - LOW_SURROGATE_MIN);
                if (appendScalar(policy, scalar))
                    outcome = MacVNCCurtainUnlockAccumulated;
                continue;
            }
            /* An unpaired high surrogate is not a character; the unit that
               followed it still is one, so it falls through. */
        }

        if (unit >= HIGH_SURROGATE_MIN && unit <= HIGH_SURROGATE_MAX) {
            policy->pendingHighSurrogate = (uint16_t)unit;
            continue;
        }
        if (unit >= LOW_SURROGATE_MIN && unit <= LOW_SURROGATE_MAX)
            continue; /* unpaired low surrogate: nothing was typed */

        if (unit == 0x000Du || unit == 0x000Au)
            return evaluate(policy, nowNanoseconds);

        if (unit == 0x001Bu) {
            clearBuffer(policy);
            /* The throttle deliberately survives: Escape corrects a typo, it
               does not undo a wrong attempt. */
            return MacVNCCurtainUnlockCleared;
        }

        /* Control characters are keys, not text. Backspace among them: with no
           visible feedback behind the curtain, Escape-and-retype is the only
           correction whose effect the user can be sure of. */
        if (unit < 0x0020u || unit == 0x007Fu)
            continue;

        if (appendScalar(policy, unit))
            outcome = MacVNCCurtainUnlockAccumulated;
    }

    return outcome;
}

bool
macVNCCurtainPolicyThrottledAt(const MacVNCCurtainPolicy *policy,
                               uint64_t nowNanoseconds)
{
    if (!policy)
        return false;
    return nowNanoseconds < policy->throttleUntilNanoseconds;
}

uint64_t
macVNCCurtainPolicyThrottleDeadline(const MacVNCCurtainPolicy *policy)
{
    return policy ? policy->throttleUntilNanoseconds : 0;
}

bool
macVNCCurtainPolicyIsArmed(const MacVNCCurtainPolicy *policy)
{
    return policy && policy->armed;
}

size_t
macVNCCurtainPolicyBufferedByteCount(const MacVNCCurtainPolicy *policy)
{
    return policy ? policy->typedLength : 0;
}

bool
macVNCCurtainPolicySecretChanged(const MacVNCCurtainPolicy *policy,
                                 const char *secret,
                                 size_t secretLength)
{
    uint8_t candidate[MACVNC_CURTAIN_SECRET_EFFECTIVE_BYTES];
    bool equal;

    /* No armed secret, or no usable secret to compare against, is reported as
       a change: the caller's reaction is to lift, and lifting on an unarmed
       policy is harmless while NOT lifting on a cleared password is the
       lockout. */
    if (!policy || !policy->armed || !secret || secretLength == 0)
        return true;

    effectiveBytes(secret, secretLength, candidate);
    equal = effectiveBytesEqual(candidate, policy->secret);
    memset(candidate, 0, sizeof(candidate));
    return !equal;
}
