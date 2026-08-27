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
    assert(macVNCTLSValidateClientVersions(0, 2, 258));

    /* Rejects other protocol versions: a client that speaks a different
       VeNCrypt revision must fail closed, not fall through unencrypted. */
    assert(!macVNCTLSValidateClientVersions(0, 0, 258));
    assert(!macVNCTLSValidateClientVersions(0, 1, 258));
    assert(!macVNCTLSValidateClientVersions(1, 2, 258));

    /* Rejects every subtype except TLSVnc - especially Plain (256), which is
       credentials in cleartext, and X509 variants we do not offer. */
    assert(!macVNCTLSValidateClientVersions(0, 2, 256));
    assert(!macVNCTLSValidateClientVersions(0, 2, 257));
    assert(!macVNCTLSValidateClientVersions(0, 2, 259));
    assert(!macVNCTLSValidateClientVersions(0, 2, 261));
    assert(!macVNCTLSValidateClientVersions(0, 2, 0));
    assert(!macVNCTLSValidateClientVersions(0, 2, 4294967295u));

    puts("test_vencrypt_negotiation: all assertions passed");
    return 0;
}
