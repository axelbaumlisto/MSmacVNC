#include "MacVNCTLS.h"

/* rfbssl_* are exported by libvncserver but their header is internal. The
   contract: after a successful init, sockets.c routes ALL of this client's
   reads/writes through SSL (cl->sslctx). */
extern int  rfbssl_init(rfbClientPtr cl);
extern void rfbssl_destroy(rfbClientPtr cl);

#include <ifaddrs.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
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

size_t
macVNCTLSBuildSubtypeGreeting(uint8_t *out, size_t capacity)
{
    /* 1 ack + 1 count + 4 per subtype; we offer exactly one. */
    const size_t needed = 1 + 1 + 4;
    if (!out || capacity < needed)
        return 0;

    out[0] = 0; /* version accepted */
    out[1] = 1; /* one subtype follows */
    out[2] = (uint8_t)((MACVNC_SUBTYPE_X509VNC >> 24) & 0xFF);
    out[3] = (uint8_t)((MACVNC_SUBTYPE_X509VNC >> 16) & 0xFF);
    out[4] = (uint8_t)((MACVNC_SUBTYPE_X509VNC >> 8) & 0xFF);
    out[5] = (uint8_t)(MACVNC_SUBTYPE_X509VNC & 0xFF);
    return needed;
}

bool
macVNCTLSValidateClientVersions(uint8_t majorIn, uint8_t minorIn,
                                uint32_t chosenSubtype)
{
    if (majorIn != MACVNC_VENCRYPT_MAJOR || minorIn != MACVNC_VENCRYPT_MINOR)
        return false;
    return chosenSubtype == MACVNC_SUBTYPE_X509VNC;
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

    /*
     * Generate once via the system openssl (libssl is already a dependency of
     * libvncserver; shelling out keeps our TCB free of X.509 plumbing).
     *
     * The names matter. A certificate with only "CN=macVNC" made every viewer
     * report "Server certificate doesn't match given server name", because a
     * viewer dials an ADDRESS - so the addresses this Mac answers on go in as
     * subjectAltName. A self-signed certificate still needs the user to trust
     * it once; that is inherent and honest, but a name mismatch on top of it
     * is our bug, not theirs.
     */
    char hostname[256] = "macVNC";
    gethostname(hostname, sizeof(hostname) - 1);
    hostname[sizeof(hostname) - 1] = '\0';

    char sans[1024];
    size_t used = (size_t)snprintf(sans, sizeof(sans), "DNS:%s,DNS:localhost,"
                                   "IP:127.0.0.1", hostname);

    /* Every IPv4 address this host currently answers on. A later address
       change costs a trust prompt, not a broken handshake. */
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) == 0) {
        for (struct ifaddrs *ifa = interfaces; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET)
                continue;
            char text[INET_ADDRSTRLEN];
            const struct sockaddr_in *sin = (const struct sockaddr_in *)ifa->ifa_addr;
            if (!inet_ntop(AF_INET, &sin->sin_addr, text, sizeof(text)))
                continue;
            if (!strcmp(text, "127.0.0.1"))
                continue;
            int written = snprintf(sans + used, sizeof(sans) - used, ",IP:%s", text);
            if (written < 0 || (size_t)written >= sizeof(sans) - used)
                break; /* keep what fits rather than truncating mid-entry */
            used += (size_t)written;
        }
        freeifaddrs(interfaces);
    }

    char cmd[PATH_MAX * 3 + sizeof(sans)];
    int n = snprintf(cmd, sizeof(cmd),
        "openssl req -x509 -newkey rsa:2048 -sha256 -days 36500 -nodes "
        "-keyout '%s' -out '%s' -subj '/CN=%s' -addext 'subjectAltName=%s' "
        ">/dev/null 2>&1",
        keyPath, certPath, hostname, sans);
    if (n < 0 || (size_t)n >= sizeof(cmd))
        return false;
    if (system(cmd) != 0)
        return false;

    return macVNCTLSCertPaths(certPath, certPathCap, keyPath, keyPathCap,
                              dir, sizeof(dir));
}
