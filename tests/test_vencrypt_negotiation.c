#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

/* The pure unit under test lives in MacVNCTLS.c together with socket glue.
   Stubs keep this target free of libvncserver client plumbing. */
struct _rfbClientRec;
void macVNCTLSHandleVeNCrypt(struct _rfbClientRec *cl) { (void)cl; }
bool macVNCTLSRunVNCAuthInsideTLS(struct _rfbClientRec *cl) { (void)cl; return false; }

#include "MacVNCTLS.h"

int main(void)
{
    /* Accepts exactly what we advertise. */
    /* 261 = X509Vnc: TLS with a certificate, which is what we actually do.
       258 (TLSVnc) is ANONYMOUS TLS and must be refused - advertising it while
       presenting a certificate made real viewers fail the handshake. */
    assert(macVNCTLSValidateClientVersions(0, 2, 261));

    /* Rejects other protocol versions: a client that speaks a different
       VeNCrypt revision must fail closed, not fall through unencrypted. */
    assert(!macVNCTLSValidateClientVersions(0, 0, 261));
    assert(!macVNCTLSValidateClientVersions(0, 1, 261));
    assert(!macVNCTLSValidateClientVersions(1, 2, 261));

    /* Rejects every other subtype - especially Plain (256), which is
       credentials in cleartext, and TLSVnc (258), which is ANONYMOUS TLS: we
       present a certificate, so claiming 258 makes viewers offer anon-only
       ciphers and the handshake dies. */
    assert(!macVNCTLSValidateClientVersions(0, 2, 256));
    assert(!macVNCTLSValidateClientVersions(0, 2, 258));
    assert(!macVNCTLSValidateClientVersions(0, 2, 257));
    assert(!macVNCTLSValidateClientVersions(0, 2, 259));
    assert(!macVNCTLSValidateClientVersions(0, 2, 260));
    assert(!macVNCTLSValidateClientVersions(0, 2, 262));
    assert(!macVNCTLSValidateClientVersions(0, 2, 0));
    assert(!macVNCTLSValidateClientVersions(0, 2, 4294967295u));

    /* The exact bytes on the wire. This is the assertion that was missing when
       the count went out as a U32: a real viewer read those four bytes as
       "version ok, ZERO subtypes" and refused to continue, while a test client
       written against our own code read them as a count and appeared to work. */
    uint8_t greeting[8] = { 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA };
    assert(macVNCTLSBuildSubtypeGreeting(greeting, sizeof(greeting)) == 6);
    assert(greeting[0] == 0);   /* version ack: accepted */
    assert(greeting[1] == 1);   /* exactly one subtype follows */
    /* 261 = X509Vnc, big-endian on the wire. */
    assert(greeting[2] == 0 && greeting[3] == 0);
    assert(greeting[4] == 1 && greeting[5] == 5);
    assert(greeting[6] == 0xAA); /* nothing written past the reported length */

    /* Too small a buffer must report failure rather than write a partial
       greeting - a truncated one would desynchronise the client forever. */
    uint8_t tiny[5] = { 0 };
    assert(macVNCTLSBuildSubtypeGreeting(tiny, sizeof(tiny)) == 0);
    assert(macVNCTLSBuildSubtypeGreeting(NULL, 64) == 0);

    /* The subtype the greeting announces must be the one we accept back. */
    uint32_t announced = ((uint32_t)greeting[2] << 24) | ((uint32_t)greeting[3] << 16) |
                         ((uint32_t)greeting[4] << 8) | greeting[5];
    assert(macVNCTLSValidateClientVersions(0, 2, announced));

    puts("test_vencrypt_negotiation: all assertions passed");
    return 0;
}
