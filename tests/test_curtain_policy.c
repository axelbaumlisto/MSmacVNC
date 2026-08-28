/*
 * The way back in from curtain mode.
 *
 * Every assertion here guards someone sitting in front of a black screen with
 * their keyboard swallowed by an event tap. Two failure modes, both bad and not
 * symmetric: a policy that unlocks too easily hands the local machine to
 * anyone who walks up, and a policy that unlocks too grudgingly - a throttle
 * that never stops growing, a buffer that keeps stale characters, a comparison
 * stricter than the server's own - leaves the owner with no way out short of
 * the power button.
 */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "MacVNCCurtainPolicy.h"

/* Types ASCII text one key event at a time, the way the tap delivers it. */
static MacVNCCurtainUnlockOutcome
type(MacVNCCurtainPolicy *policy, const char *ascii, uint64_t now)
{
    MacVNCCurtainUnlockOutcome outcome = MacVNCCurtainUnlockIgnored;
    for (const char *c = ascii; *c; ++c) {
        uint16_t unit = (uint16_t)(unsigned char)*c;
        outcome = macVNCCurtainPolicyFeed(policy, &unit, 1, now);
    }
    return outcome;
}

static MacVNCCurtainUnlockOutcome
typeUnits(MacVNCCurtainPolicy *policy, const uint16_t *units, size_t count,
          uint64_t now)
{
    MacVNCCurtainUnlockOutcome outcome = MacVNCCurtainUnlockIgnored;
    for (size_t i = 0; i < count; ++i)
        outcome = macVNCCurtainPolicyFeed(policy, &units[i], 1, now);
    return outcome;
}

static void
armWith(MacVNCCurtainPolicy *policy, const char *secret)
{
    assert(macVNCCurtainPolicyArm(policy, secret, strlen(secret)));
    assert(macVNCCurtainPolicyIsArmed(policy));
}

int
main(void)
{
    const uint64_t step = MACVNC_CURTAIN_THROTTLE_STEP_NANOSECONDS;
    const uint64_t cap = MACVNC_CURTAIN_THROTTLE_CAP_NANOSECONDS;
    const uint64_t t0 = 1000;
    MacVNCCurtainPolicy policy;

    /* The constants themselves are part of the contract: behind a black screen
       a delay long enough to look like a lockout IS one, and a buffer that
       could not hold the bytes that matter would refuse the right password. */
    assert(step > 0 && step <= cap);
    assert(cap <= 10ull * 1000ull * 1000ull * 1000ull);
    assert(MACVNC_CURTAIN_MAX_INPUT_BYTES >= MACVNC_CURTAIN_SECRET_EFFECTIVE_BYTES);
    assert(MACVNC_CURTAIN_MAX_INPUT_BYTES <= 4096);
    assert(MACVNC_CURTAIN_SECRET_EFFECTIVE_BYTES == 8); /* what DES keys from */

    /* A curtain with no way out is the failure this refusal exists to prevent:
       an empty or missing secret must not arm, and must leave the policy
       DISARMED rather than "unchanged". */
    memset(&policy, 0xAB, sizeof(policy));
    assert(!macVNCCurtainPolicyArm(&policy, "", 0));
    assert(!macVNCCurtainPolicyIsArmed(&policy));
    assert(!macVNCCurtainPolicyArm(&policy, NULL, 8));
    assert(!macVNCCurtainPolicyIsArmed(&policy));
    assert(!macVNCCurtainPolicyArm(&policy, "secret", 0));
    assert(!macVNCCurtainPolicyIsArmed(&policy));

    /* Clearing the password must not leave the PREVIOUS one armed - that is
       precisely the lockout, and it is why arming does not follow the
       leave-the-output-untouched rule of the parser modules. */
    armWith(&policy, "supersecret");
    assert(!macVNCCurtainPolicyArm(&policy, "", 0));
    assert(!macVNCCurtainPolicyIsArmed(&policy));

    /* A disarmed policy accumulates nothing and grants nothing, whatever is
       typed at it. */
    assert(type(&policy, "supersecret\r", t0) == MacVNCCurtainUnlockIgnored);
    assert(macVNCCurtainPolicyBufferedByteCount(&policy) == 0);

    /* The password lifts the curtain, and the buffer does not survive it. */
    armWith(&policy, "supersecret");
    assert(type(&policy, "supersecret", t0) == MacVNCCurtainUnlockAccumulated);
    assert(macVNCCurtainPolicyBufferedByteCount(&policy) == 11);
    assert(type(&policy, "\r", t0) == MacVNCCurtainUnlockGranted);
    assert(macVNCCurtainPolicyBufferedByteCount(&policy) == 0);
    /* A grant is one-shot: raising the curtain again is a deliberate re-arm,
       never a leftover armed policy. */
    assert(!macVNCCurtainPolicyIsArmed(&policy));

    /* Only the 8 bytes VNC authentication keys DES from are compared. The
       server itself admits a client that typed just those 8, so refusing them
       here would lock out a password the VNC side accepts. */
    armWith(&policy, "supersecret");
    assert(type(&policy, "supersec\r", t0) == MacVNCCurtainUnlockGranted);
    armWith(&policy, "supersecret");
    assert(type(&policy, "supersecretly-longer\r", t0) == MacVNCCurtainUnlockGranted);
    /* ...and the truncation is not a free pass: the first 8 bytes must match. */
    armWith(&policy, "supersecret");
    assert(type(&policy, "supersed\r", t0) == MacVNCCurtainUnlockRejected);
    /* A raise is a new curtain: arming starts a fresh backoff rather than
       carrying the previous run's deadline into it. */
    assert(macVNCCurtainPolicyThrottleDeadline(&policy) != 0);
    armWith(&policy, "supersecret");
    assert(macVNCCurtainPolicyThrottleDeadline(&policy) == 0);
    /* A short password is compared over its whole length, not just a prefix:
       zero padding means "abc" is not satisfied by "abcd". */
    armWith(&policy, "abc");
    assert(type(&policy, "abcd\r", t0) == MacVNCCurtainUnlockRejected);
    assert(type(&policy, "ab\r", t0 + 100 * cap) == MacVNCCurtainUnlockRejected);
    assert(type(&policy, "abc\r", t0 + 200 * cap) == MacVNCCurtainUnlockGranted);

    /* Wrong attempts throttle, and the throttle is a DEADLINE the caller
       compares against - this module never sleeps, because a sleep in a tap
       callback is what makes WindowServer disable the tap. */
    armWith(&policy, "supersecret");
    assert(macVNCCurtainPolicyThrottleDeadline(&policy) == 0);
    assert(!macVNCCurtainPolicyThrottledAt(&policy, t0));
    assert(type(&policy, "nope\r", t0) == MacVNCCurtainUnlockRejected);
    assert(macVNCCurtainPolicyBufferedByteCount(&policy) == 0);
    assert(macVNCCurtainPolicyThrottleDeadline(&policy) == t0 + step);
    assert(macVNCCurtainPolicyThrottledAt(&policy, t0 + step - 1));
    /* The deadline itself is over: waiting must end, not last one tick longer
       than advertised. */
    assert(!macVNCCurtainPolicyThrottledAt(&policy, t0 + step));

    /* While throttled NOTHING is accepted - not even the right password - and
       the attempt is not counted either, so hammering the keyboard cannot push
       the delay up while it is already running. */
    uint64_t during = t0 + step / 2;
    assert(type(&policy, "supersecret\r", during) == MacVNCCurtainUnlockIgnored);
    assert(macVNCCurtainPolicyBufferedByteCount(&policy) == 0);
    assert(macVNCCurtainPolicyThrottleDeadline(&policy) == t0 + step);

    /* The delay doubles per wrong attempt and then STOPS growing. An uncapped
       backoff is indistinguishable from a lockout for someone who cannot see
       the screen. */
    uint64_t at = t0 + step;
    const uint64_t expected[] = { 2 * step, 4 * step, 8 * step, cap, cap, cap };
    for (size_t i = 0; i < sizeof(expected) / sizeof(expected[0]); ++i) {
        uint64_t want = expected[i] < cap ? expected[i] : cap;
        assert(type(&policy, "nope\r", at) == MacVNCCurtainUnlockRejected);
        assert(macVNCCurtainPolicyThrottleDeadline(&policy) == at + want);
        assert(macVNCCurtainPolicyThrottleDeadline(&policy) - at <= cap);
        at += want;
    }

    /* Escape clears the buffer but NOT the throttle, or Escape would be a free
       reset of the backoff. */
    assert(type(&policy, "nope\r", at) == MacVNCCurtainUnlockRejected);
    uint64_t deadline = macVNCCurtainPolicyThrottleDeadline(&policy);
    assert(deadline > at);
    assert(type(&policy, "\x1b", at) == MacVNCCurtainUnlockIgnored); /* throttled */
    assert(macVNCCurtainPolicyThrottleDeadline(&policy) == deadline);
    assert(type(&policy, "half", deadline) == MacVNCCurtainUnlockAccumulated);
    assert(macVNCCurtainPolicyBufferedByteCount(&policy) == 4);
    assert(type(&policy, "\x1b", deadline) == MacVNCCurtainUnlockCleared);
    assert(macVNCCurtainPolicyBufferedByteCount(&policy) == 0);
    assert(macVNCCurtainPolicyThrottleDeadline(&policy) == deadline);

    /* Having waited out the cap, the right password still works: the throttle
       delays the owner, it never locks them out. */
    assert(type(&policy, "supersecret\r", deadline) == MacVNCCurtainUnlockGranted);

    /* The buffer is BOUNDED: a stuck or hostile keyboard cannot grow it, and
       what overflowed is not silently carried into the next attempt. */
    armWith(&policy, "supersecret");
    for (int i = 0; i < 10000; ++i) {
        type(&policy, "a", t0);
        assert(macVNCCurtainPolicyBufferedByteCount(&policy) <= MACVNC_CURTAIN_MAX_INPUT_BYTES);
    }
    assert(macVNCCurtainPolicyBufferedByteCount(&policy) == MACVNC_CURTAIN_MAX_INPUT_BYTES);
    assert(type(&policy, "a", t0) == MacVNCCurtainUnlockIgnored);
    assert(type(&policy, "\r", t0) == MacVNCCurtainUnlockRejected);
    assert(macVNCCurtainPolicyBufferedByteCount(&policy) == 0);
    assert(type(&policy, "supersecret\r", t0 + 100 * cap) == MacVNCCurtainUnlockGranted);

    /* Both newline forms are Return: which one a layout produces is not a
       property this module should depend on. */
    armWith(&policy, "supersecret");
    assert(type(&policy, "supersecret\n", t0) == MacVNCCurtainUnlockGranted);

    /* A dead key produces zero units, and other control characters are not
       text: neither may reach the buffer, or a modifier press would corrupt an
       attempt the user cannot see. */
    armWith(&policy, "supersecret");
    assert(macVNCCurtainPolicyFeed(&policy, NULL, 0, t0) == MacVNCCurtainUnlockIgnored);
    const uint16_t tab = 0x0009, del = 0x007F, bell = 0x0007;
    assert(macVNCCurtainPolicyFeed(&policy, &tab, 1, t0) == MacVNCCurtainUnlockIgnored);
    assert(macVNCCurtainPolicyFeed(&policy, &del, 1, t0) == MacVNCCurtainUnlockIgnored);
    assert(macVNCCurtainPolicyFeed(&policy, &bell, 1, t0) == MacVNCCurtainUnlockIgnored);
    assert(macVNCCurtainPolicyBufferedByteCount(&policy) == 0);
    assert(type(&policy, "supersecret\r", t0) == MacVNCCurtainUnlockGranted);

    /* A terminator ends the attempt even when the event carries more text
       behind it: characters after a Return must not seed the next attempt. */
    armWith(&policy, "supersecret");
    const uint16_t returnThenText[] = { 'a', '\r', 'b', 'c' };
    assert(macVNCCurtainPolicyFeed(&policy, returnThenText, 4, t0) == MacVNCCurtainUnlockRejected);
    assert(macVNCCurtainPolicyBufferedByteCount(&policy) == 0);

    /* Non-ASCII is compared as BYTES, exactly as the server does. "пароль" is
       six code points but twelve UTF-8 bytes, and VNC only ever keys DES from
       the first eight of them - the four Cyrillic letters "паро". A code-point
       comparison would refuse a password the server accepts. */
    const char *cyrillic = "\xd0\xbf\xd0\xb0\xd1\x80\xd0\xbe\xd0\xbb\xd1\x8c";
    const uint16_t parol[] = { 0x043F, 0x0430, 0x0440, 0x043E, 0x043B, 0x044C, '\r' };
    armWith(&policy, cyrillic);
    assert(typeUnits(&policy, parol, 7, t0) == MacVNCCurtainUnlockGranted);
    armWith(&policy, cyrillic);
    const uint16_t firstFourAndReturn[] = { 0x043F, 0x0430, 0x0440, 0x043E, '\r' };
    assert(typeUnits(&policy, firstFourAndReturn, 5, t0) == MacVNCCurtainUnlockGranted);
    /* Three of the six letters are only six bytes: still short of the eight
       that matter, so it must be refused. */
    armWith(&policy, cyrillic);
    const uint16_t firstThreeAndReturn[] = { 0x043F, 0x0430, 0x0440, '\r' };
    assert(typeUnits(&policy, firstThreeAndReturn, 4, t0) == MacVNCCurtainUnlockRejected);

    /* Surrogate pairs are combined here rather than in the tap, so the bytes in
       the buffer are the same UTF-8 the password was stored as. U+1F600 is
       four bytes; two of them are the whole effective secret. */
    armWith(&policy, "\xF0\x9F\x98\x80\xF0\x9F\x98\x80");
    const uint16_t twoEmojiAndReturn[] = { 0xD83D, 0xDE00, 0xD83D, 0xDE00, '\r' };
    assert(typeUnits(&policy, twoEmojiAndReturn, 5, t0) == MacVNCCurtainUnlockGranted);
    /* A lone high surrogate is not a character: it buffers nothing on its own
       and must not produce a stray byte. */
    armWith(&policy, "\xF0\x9F\x98\x80\xF0\x9F\x98\x80");
    const uint16_t loneHigh = 0xD83D;
    assert(macVNCCurtainPolicyFeed(&policy, &loneHigh, 1, t0) == MacVNCCurtainUnlockIgnored);
    assert(macVNCCurtainPolicyBufferedByteCount(&policy) == 0);
    assert(type(&policy, "\r", t0) == MacVNCCurtainUnlockRejected);

    /* Changing the password changes the credential, and that is what lifts the
       curtain (Task 4) - benignly when the owner does it, defensively when the
       remote party does. Comparison is on the effective bytes only: a ninth
       character changes nothing the server can see, so it is not a change. */
    armWith(&policy, "supersecret");
    assert(!macVNCCurtainPolicySecretChanged(&policy, "supersecret", 11));
    assert(!macVNCCurtainPolicySecretChanged(&policy, "supersec", 8));
    assert(!macVNCCurtainPolicySecretChanged(&policy, "supersecXYZ", 11));
    assert(macVNCCurtainPolicySecretChanged(&policy, "supersecret", 7));
    assert(macVNCCurtainPolicySecretChanged(&policy, "Supersecret", 11));
    assert(macVNCCurtainPolicySecretChanged(&policy, "", 0));
    assert(macVNCCurtainPolicySecretChanged(&policy, NULL, 11));

    /* An unarmed policy has no secret to still match, so it always reports a
       change: the caller's safe reaction (lift) must not depend on order. */
    macVNCCurtainPolicyReset(&policy);
    assert(macVNCCurtainPolicySecretChanged(&policy, "supersecret", 11));
    /* Including against the all-zero bytes a cleared policy happens to hold:
       the answer comes from "is anything armed", never from the padding
       matching by accident. */
    assert(macVNCCurtainPolicySecretChanged(&policy, "\0\0\0\0\0\0\0\0", 8));

    /* Reset is the lift path: nothing survives it - not the buffer, not the
       throttle, not the armed secret. */
    armWith(&policy, "supersecret");
    assert(type(&policy, "nope\r", t0) == MacVNCCurtainUnlockRejected);
    assert(macVNCCurtainPolicyThrottleDeadline(&policy) != 0);
    macVNCCurtainPolicyReset(&policy);
    assert(!macVNCCurtainPolicyIsArmed(&policy));
    assert(macVNCCurtainPolicyBufferedByteCount(&policy) == 0);
    assert(macVNCCurtainPolicyThrottleDeadline(&policy) == 0);
    assert(!macVNCCurtainPolicyThrottledAt(&policy, 0));

    /* A missing policy must fail SAFE - never "granted", never a crash in a
       tap callback. */
    const uint16_t any = 'a';
    assert(macVNCCurtainPolicyFeed(NULL, &any, 1, t0) == MacVNCCurtainUnlockIgnored);
    assert(!macVNCCurtainPolicyIsArmed(NULL));
    assert(!macVNCCurtainPolicyThrottledAt(NULL, t0));
    assert(macVNCCurtainPolicyThrottleDeadline(NULL) == 0);
    assert(macVNCCurtainPolicyBufferedByteCount(NULL) == 0);
    assert(macVNCCurtainPolicySecretChanged(NULL, "supersecret", 11));
    assert(!macVNCCurtainPolicyArm(NULL, "supersecret", 11));
    macVNCCurtainPolicyReset(NULL);

    puts("test_curtain_policy: all assertions passed");
    return 0;
}
