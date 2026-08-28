#pragma once

#include <rfb/rfb.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * VeNCrypt-style TLS for plain RFB (security type 19 -> subtype 258, TLSVnc).
 *
 * The viewer warns "connection unencrypted" because classic VNC auth (type 2)
 * sends no channel encryption at all: screen pixels and keystrokes go in
 * plaintext, and the DES challenge-response is offline-bruteforceable from one
 * captured handshake. Our deployment encrypts TRANSPORT (Tailscale/WireGuard),
 * so the real exposure is small - but "encrypted because of an accident of
 * network topology" is weaker than "encrypted by the protocol", and clients
 * cannot tell the difference.
 *
 * Design (KISS): ONE self-signed certificate per installation, generated once
 * and stored next to the app's support directory; ANON TLS = server does not
 * authenticate itself to the client via CA chain (there is no CA), the client
 * is protected by knowing WHICH host it dialed + the VNC password INSIDE the
   TLS channel. No new macOS permission dialogs.
 *
 * All functions are pure decision helpers except macVNCTLSHandleSecurity,
 * which performs the on-socket negotiation. Certificate generation lives in
 * macVNCTLSEnsureCertificate().
 */

/* Where the cert/key PEM pair lives; creates the directory if missing.
   Returns true when both files exist afterwards. */
bool macVNCTLSEnsureCertificate(char *certPath, size_t certPathCap,
                                char *keyPath, size_t keyPathCap);

/* Parse the client's VeNCrypt version reply (2 bytes) + chosen subtype
   (4 bytes). Pure. Returns false if the client cannot do what we offer. */
bool macVNCTLSValidateClientVersions(uint8_t majorIn, uint8_t minorIn,
                                     uint32_t chosenSubtype);

/*
 * Build the VeNCrypt subtype greeting the server sends after the version
 * exchange: U8 version-ack, U8 subtype-count, then one U32 per subtype.
 *
 * A pure function because the LAYOUT is what broke: the count went out as a
 * U32, so a real viewer read "ack 0, zero subtypes" and gave up. Nothing
 * tested those bytes - the only client exercising them was a script written
 * against this code instead of against the specification.
 *
 * Returns the number of bytes written, or 0 if the buffer is too small.
 */
size_t macVNCTLSBuildSubtypeGreeting(uint8_t *out, size_t capacity);

/* The subtype we implement: X509Vnc, i.e. TLS with a certificate. */
#define MACVNC_SUBTYPE_X509VNC 261u

/* The security-handler entry point libvncserver calls with type 19. */
void macVNCTLSHandleVeNCrypt(rfbClientPtr cl);

/* Classic VNC auth INSIDE the channel; implemented by the owner of the
   password store (mac.m) because that is where the check lives. Returns
   false if auth failed - caller closes. */
bool macVNCTLSRunVNCAuthInsideTLS(rfbClientPtr cl);
