#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * The way BACK from curtain mode: the rule that decides whether what the person
 * standing at the Mac typed lifts the curtain.
 *
 * The curtain is raised by the REMOTE party, so the local user is looking at a
 * black screen with their keyboard swallowed by an event tap. This module is
 * the only path back in, which is why it is a pure module rather than logic
 * inside the tap callback: every rule below is decided and tested without a
 * window, a tap, a capture stream or a VNC server.
 *
 * Two properties of the CALLER shape the whole API:
 *
 * 1. The caller is a `CGEventTapCallBack`. A callback that blocks for ~1 s
 *    makes WindowServer disable the tap, which restores local input while the
 *    black window stays composited. So this module NEVER sleeps, never takes a
 *    lock, never allocates, and never reads a clock: the caller passes the
 *    monotonic timestamp in (`macVNCMonotonicNow()`, FirstFrameBudget.h), and
 *    a throttle is expressed as a DEADLINE the caller compares against.
 * 2. The caller has already translated keycodes to characters with
 *    `CGEventKeyboardGetUnicodeString` (no allocation, callback-safe, and it
 *    applies the active layout, shift and caps lock for us). That is the
 *    keycode-to-character rule for this feature, decided here rather than in
 *    the tap: this module's input is UTF-16 code units exactly as that call
 *    produces them (`UniChar` is `unsigned short`, i.e. `uint16_t`), and a
 *    dead key - which yields zero units - is simply nothing to feed.
 *
 * BYTES, NOT CODE POINTS. The buffer holds UTF-8 bytes, because the thing it
 * is ultimately compared against is a VNC password whose DES key is built from
 * the first 8 BYTES (see MACVNC_VNC_PASSWORD_EFFECTIVE_MAX in MacVNCPassword.h
 * and LibVNCServer's MAXPWLEN). Comparing code points would disagree with the
 * server about non-ASCII secrets: "пароль" is 6 code points but 12 bytes, and
 * the server only ever sees the first 8 of those bytes. Surrogate pairs are
 * combined here into one scalar before encoding, so the UTF-8 in the buffer is
 * exactly what an NSString of the same text would produce.
 */

/* The number of password bytes VNC authentication actually uses; anything past
 * it is ignored by DES. Mirrors MACVNC_VNC_PASSWORD_EFFECTIVE_MAX, which lives
 * in an Objective-C header this pure C module must not include. */
#define MACVNC_CURTAIN_SECRET_EFFECTIVE_BYTES 8

/* The typing buffer is FIXED. It only has to survive until the next Return or
 * Escape, and only its first 8 bytes are ever compared, so its size is a bound
 * on a hostile/stuck keyboard rather than a capacity anyone should reach. */
#define MACVNC_CURTAIN_MAX_INPUT_BYTES 64

/* Throttle after a wrong attempt: doubling, and CAPPED. Uncapped backoff is
 * indistinguishable from a lockout for someone who cannot see the screen. */
#define MACVNC_CURTAIN_THROTTLE_STEP_NANOSECONDS (500ull * 1000ull * 1000ull)
#define MACVNC_CURTAIN_THROTTLE_CAP_NANOSECONDS (5ull * 1000ull * 1000ull * 1000ull)

typedef enum {
    /* Nothing changed: not armed, still throttled, a dead key, or a character
       the policy does not accumulate (control keys other than Return/Escape). */
    MacVNCCurtainUnlockIgnored = 0,
    /* The character went into the buffer. */
    MacVNCCurtainUnlockAccumulated,
    /* Escape: buffer cleared. The throttle deliberately SURVIVES this, or
       Escape would be a free reset of the backoff. */
    MacVNCCurtainUnlockCleared,
    /* Return with the wrong text: buffer cleared, throttle deadline extended. */
    MacVNCCurtainUnlockRejected,
    /* Return with the right text: buffer cleared and the policy DISARMS. */
    MacVNCCurtainUnlockGranted,
} MacVNCCurtainUnlockOutcome;

typedef struct {
    bool armed;
    /* The secret's effective bytes, zero-padded - the same 8 bytes DES keys
       itself from. Only meaningful while `armed`. */
    uint8_t secret[MACVNC_CURTAIN_SECRET_EFFECTIVE_BYTES];
    uint8_t typed[MACVNC_CURTAIN_MAX_INPUT_BYTES];
    size_t typedLength;
    unsigned failedAttempts;
    uint64_t throttleUntilNanoseconds;
    /* Half of a surrogate pair waiting for its partner; 0 when none. */
    uint16_t pendingHighSurrogate;
} MacVNCCurtainPolicy;

/*
 * Arm the policy with the secret that lifts the curtain.
 *
 * REFUSES an empty or missing secret (returns false): a curtain armed with a
 * secret nobody can type is a black screen with no way out. On refusal the
 * policy is left DISARMED and cleared - deliberately unlike this project's
 * parser modules, which leave a caller's output untouched on rejection. Here
 * "untouched" would mean a policy that stays armed with the PREVIOUS secret
 * after the owner cleared their password, which is the exact lockout this
 * refusal exists to prevent.
 *
 * `secret` is the raw password bytes (UTF-8, as stored); `secretLength` is its
 * length in bytes. Only the first MACVNC_CURTAIN_SECRET_EFFECTIVE_BYTES are
 * retained, so a longer password is not kept in memory past what it can do.
 *
 * Arming starts a FRESH backoff. It takes no timestamp because it has nothing
 * to schedule: a raise is a new curtain, and carrying the previous run's
 * throttle into it would punish the local user for someone else's attempt.
 */
bool macVNCCurtainPolicyArm(MacVNCCurtainPolicy *policy,
                            const char *secret,
                            size_t secretLength);

/* Disarm and clear everything: the buffer, the attempt count and the throttle.
 * Called whenever the curtain comes down, by whatever route. */
void macVNCCurtainPolicyReset(MacVNCCurtainPolicy *policy);

/*
 * Feed the characters of ONE key event, as produced by
 * `CGEventKeyboardGetUnicodeString`. `unitCount` may be 0 (dead key).
 *
 * Units are consumed in order and processing STOPS at the first Return or
 * Escape, whose outcome is what the call returns: a terminator decides the
 * attempt, and text arriving behind it in the same event must not silently
 * seed the next one. Return is CR or LF; Escape is U+001B.
 */
MacVNCCurtainUnlockOutcome macVNCCurtainPolicyFeed(MacVNCCurtainPolicy *policy,
                                                   const uint16_t *utf16Units,
                                                   size_t unitCount,
                                                   uint64_t nowNanoseconds);

/** True while the deadline from the last wrong attempt has not passed. */
bool macVNCCurtainPolicyThrottledAt(const MacVNCCurtainPolicy *policy,
                                    uint64_t nowNanoseconds);

/* The deadline itself, so the caller can log or display it without a clock of
 * its own. 0 when there is nothing to wait for. */
uint64_t macVNCCurtainPolicyThrottleDeadline(const MacVNCCurtainPolicy *policy);

/** Whether a secret is armed at all - the precondition for raising a curtain. */
bool macVNCCurtainPolicyIsArmed(const MacVNCCurtainPolicy *policy);

/* How many bytes are buffered. Exists so the "cleared on every outcome"
 * invariant is checkable from outside rather than only by reading the code. */
size_t macVNCCurtainPolicyBufferedByteCount(const MacVNCCurtainPolicy *policy);

/*
 * Whether `secret` still keys the same VNC authentication as the one armed.
 *
 * This is the seam for "the secret is read at each comparison, and any change
 * to it lifts the curtain": the benign case is the owner changing their
 * password, the adversarial one is the remote party changing it to lock the
 * local user out. Compared on the EFFECTIVE bytes only, because that is what
 * changes the credential - appending a 9th character changes nothing the server
 * can see, so it must not be reported as a change. An unarmed policy, and an
 * empty or missing secret, both report "changed".
 */
bool macVNCCurtainPolicySecretChanged(const MacVNCCurtainPolicy *policy,
                                      const char *secret,
                                      size_t secretLength);
