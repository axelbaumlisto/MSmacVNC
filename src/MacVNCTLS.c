#include "MacVNCTLS.h"

/* rfbssl_* are exported by libvncserver but their header is internal. The
   contract: after a successful init, sockets.c routes ALL of this client's
   reads/writes through SSL (cl->sslctx). */
extern int  rfbssl_init(rfbClientPtr cl);
extern void rfbssl_destroy(rfbClientPtr cl);

#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syslimits.h>

/*
 * VeNCrypt 0.2 wire order for security type 19 (after the client picked 19):
 *   server -> client: u8 major(0) u8 minor(2)
 *   client -> server: u8 major u8 minor            (echo)
 *   server -> client: u32 subtype count, then u32[] subtypes
 *   client -> server: u32 chosen subtype (258 = TLSVnc)
 *   ... TLS handshake over the same socket ...
 *   standard VNC auth INSIDE the encrypted channel.
 */

#define MACVNC_VENCRYPT_MAJOR 0
#define MACVNC_VENCRYPT_MINOR 2
/* TLSVnc: encrypted channel, then classic VNC password auth inside it. */
#define MACVNC_SUBTYPE_TLSVNC 258u

bool
macVNCTLSValidateClientVersions(uint8_t majorIn, uint8_t minorIn,
                                uint32_t chosenSubtype)
{
    if (majorIn != MACVNC_VENCRYPT_MAJOR || minorIn != MACVNC_VENCRYPT_MINOR)
        return false;
    return chosenSubtype == MACVNC_SUBTYPE_TLSVNC;
}

/* Where the pair lives. One per installation; regenerated only if deleted. */
static bool macVNCTLSCertPaths(char *certPath, size_t certCap,
                               char *keyPath, size_t keyCap,
                               char *dirPath, size_t dirCap)
{
    const char *home = getenv("HOME");
    if (!home || !*home)
        return false;
    int n1 = snprintf(dirPath, dirCap, "%s/Library/Application Support/macVNC", home);
    if (n1 < 0 || (size_t)n1 >= dirCap)
        return false;
    mkdir(dirPath, 0700); /* EEXIST is fine */
    if (snprintf(certPath, certCap, "%s/tls-cert.pem", dirPath) >= (int)certCap)
        return false;
    if (snprintf(keyPath, keyCap, "%s/tls-key.pem", dirPath) >= (int)keyCap)
        return false;
    struct stat st;
    return stat(certPath, &st) == 0 && stat(keyPath, &st) == 0 &&
           st.st_size > 0;
}

bool
macVNCTLSEnsureCertificate(char *certPath, size_t certPathCap,
                           char *keyPath, size_t keyPathCap)
{
    char dir[PATH_MAX];
    if (macVNCTLSCertPaths(certPath, certPathCap, keyPath, keyPathCap,
                           dir, sizeof(dir)))
        return true;

    /* Generate once via the system openssl (libssl is already a dependency of
       libvncserver; shelling out keeps our TCB free of X.509 plumbing). */
    char cmd[PATH_MAX * 3];
    int n = snprintf(cmd, sizeof(cmd),
        "openssl req -x509 -newkey rsa:2048 -sha256 -days 36500 -nodes "
        "-keyout '%s' -out '%s' -subj '/CN=macVNC' >/dev/null 2>&1",
        keyPath, certPath);
    if (n < 0 || (size_t)n >= sizeof(cmd))
        return false;
    if (system(cmd) != 0)
        return false;

    return macVNCTLSCertPaths(certPath, certPathCap, keyPath, keyPathCap,
                              dir, sizeof(dir));
}
