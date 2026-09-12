# Manual: a desk-shape change survives a live session

What FIX-D (`.pi/plans/capture-liveness.md`) exists to fix, run by hand
against the real, installed app rather than a test binary: change a
display's mode *while a viewer is connected* and confirm the canvas follows,
instead of the measured regression (753 client updates, zero re-arms, canvas
stuck at the pre-change size - see `tests/test_capture_liveness_rearm_deskshape.m`'s
own header for the full account). This is the exact procedure run on
2026-09-12 against the signed, installed build; ctest cannot drive this
because it requires macOS to actually reconfigure a real display and a real
signed app with a genuine Screen Recording grant, neither of which a bare
test binary has.

## Prerequisites

- macVNC built, signed with a Developer ID (or your own team's identity) and
  installed in `/Applications` - **not** run straight out of `build-arm64/`
  or `build-release-arm64/`, which is not a full GUI launch and will not
  finish AppKit initialization (the log sink stays empty and the listener
  never comes up; this was already the wrong way to test a live server once,
  do not repeat it).
- Screen Recording already granted to that installed, signed app (System
  Settings > Privacy & Security > Screen Recording).
- `displayplacer` (`brew install displayplacer`), to change a display's mode
  from the command line without touching System Settings mid-test.
- The VNC password, readable from `defaults read net.christianbeier.macVNC
  rfbPassword`.
- A second display attached (a laptop's built-in panel plus one external is
  enough - this procedure reconfigures the BUILT-IN panel, since it is the
  one guaranteed to still be present and controllable from the command line
  regardless of what else is plugged in).

## 1. Find this desk's display id and current mode

```bash
displayplacer list
```

Note the `Persistent screen id:` of the display you intend to reconfigure
(the built-in panel, in the run this procedure documents) and its current
`res:`/`origin:` line under "Execute the command below to set your screens to
the current arrangement" - that full line is your restore command. On the
machine this was run on:

- Screen id: `37D8832A-2D66-02CA-B9F7-8F30A301B230`
- Original mode: `res:1710x1112 hz:60 color_depth:8 scaling:on origin:(-1710,1603) degree:0`
- An available alternate mode on the same screen (from `displayplacer list`'s
  own `Resolutions for rotation 0:` block): `res:1470x956 hz:60 color_depth:8 scaling:on`

Substitute your own ids/modes; the commands below are shaped for this desk.

## 2. Start a client that can observe a resize

A plain screen-scrape is not enough: LibVNCServer resizes the framebuffer and
tells every connected client via the `NewFBSize`/`ExtDesktopSize` RFB
extensions (`rfbNewFramebuffer`, `src/mac.m`) rather than dropping anyone, so
the client used to observe this must advertise support for at least one of
those two encodings in its `SetEncodings` message or it will never see the
resize at all. A production VNC viewer already does this; to drive it from a
throwaway script instead (what was actually used), recreate
`/tmp/holdsize.py` if it is gone:

```python
import socket,struct,time,sys
from cryptography.hazmat.primitives.ciphers.algorithms import TripleDES
from cryptography.hazmat.primitives.ciphers import Cipher, modes
def rev(b): return bytes(int('{:08b}'.format(x)[::-1],2) for x in b)
def des(k,d):
    c=Cipher(TripleDES(rev(k)*3),modes.ECB()).encryptor(); return c.update(d)+c.finalize()
s=socket.create_connection(("<listen-address>",<port>),8); s.settimeout(40)
def rd(n):
    b=b''
    while len(b)<n:
        c=s.recv(n-len(b))
        if not c: raise IOError("eof")
        b+=c
    return b
rd(12); s.sendall(b'RFB 003.008\n'); n=rd(1)[0]; rd(n)
s.sendall(bytes([2])); ch=rd(16); s.sendall(des(b'<password>',ch[:8])+des(b'<password>',ch[8:]))
assert struct.unpack('>I',rd(4))[0]==0
s.sendall(bytes([1])); W,H=struct.unpack('>HH',rd(4)); pf=rd(16); nl=struct.unpack('>I',rd(4))[0]; rd(nl)
bpp=pf[0]//8
print("[%s] connected, fb %dx%d"%(time.strftime("%H:%M:%S"),W,H),flush=True)
# raw + NewFBSize(-223) + ExtDesktopSize(-308)
encs=[0,-223,-308]
s.sendall(struct.pack('>BBH',2,0,len(encs))+b''.join(struct.pack('>i',e) for e in encs))
s.sendall(struct.pack('>BBHHHH',3,0,0,0,W,H))
t0=time.time(); updates=0; resizes=0
while time.time()-t0 < float(sys.argv[1] if len(sys.argv)>1 else 90):
    try:
        rd(1); rd(1); nr=struct.unpack('>H',rd(2))[0]
    except socket.timeout:
        print("[%s] TIMEOUT (no update for 40s)"%time.strftime("%H:%M:%S"),flush=True); break
    for _ in range(nr):
        x,y,rw,rh,enc=struct.unpack('>HHHHi',rd(12))
        if enc in (-223,-308):
            if enc==-308:
                cnt=rd(1)[0]; rd(3); rd(16*cnt)
            W,H=rw,rh; resizes+=1
            print("[%s] SERVER RESIZED framebuffer -> %dx%d (enc %d)"%(time.strftime("%H:%M:%S"),W,H,enc),flush=True)
        else:
            rd(rw*rh*bpp)
    updates+=1
    s.sendall(struct.pack('>BBHHHH',3,1,0,0,W,H))
print("[%s] held %.0fs: %d updates, %d resize events, final fb %dx%d"%(time.strftime("%H:%M:%S"),time.time()-t0,updates,resizes,W,H),flush=True)
s.close()
```

What it does: a minimal RFB 3.8 client - VncAuth (DES, the fixed obfuscation
key macVNC/LibVNCServer both use for the wire password), a `SetEncodings`
that lists raw plus `NewFBSize`(-223) and `ExtDesktopSize`(-308), then loops
requesting incremental updates and printing every time the server sends one
of those two resize pseudo-encodings instead of a plain rectangle. Needs
`pip install cryptography`.

```bash
python3 /tmp/holdsize.py 115 &   # hold the session open for 115s
```

## 3. Change the display's mode mid-session, then change it back

While the client above is running (a comfortable 15-20s in, so the first
frame and steady state are visible first):

```bash
displayplacer "id:37D8832A-2D66-02CA-B9F7-8F30A301B230 res:1470x956 hz:60 color_depth:8 enabled:true scaling:on origin:(-1470,1603) degree:0"
```

Wait 25-35s (comfortably past the shipped `MACVNC_DESK_SHAPE_DEBOUNCE`, half
a second, and the real ScreenCaptureKit/LibVNCServer round trip), then
restore:

```bash
displayplacer "id:37D8832A-2D66-02CA-B9F7-8F30A301B230 res:1710x1112 hz:60 color_depth:8 enabled:true scaling:on origin:(-1710,1603) degree:0"
```

## 4. What to check

**Client output** - two `SERVER RESIZED` lines, one per mode change, each
within about a second of the `displayplacer` command that caused it, and the
session runs to completion without a `TIMEOUT` or a dropped connection:

```
[15:46:35] connected, fb 5552x2715
[15:46:35] SERVER RESIZED framebuffer -> 5552x2715 (enc -308)
[15:46:51] SERVER RESIZED framebuffer -> 5312x2559 (enc -308)
[15:47:27] SERVER RESIZED framebuffer -> 5552x2715 (enc -308)
[15:48:01] held 85s: 707 updates, 3 resize events, final fb 5552x2715
```

(The very first `SERVER RESIZED` line, at connect time, is
`ExtDesktopSize`'s own initial-size announcement - expected, not a rebuild.)

**Server log** (`~/Library/Logs/macVNC/macvnc.log`) - exactly one
`Display configuration changed: canvas AxB -> CxD` line per real change
(never per `displayplacer` command that leaves the desk equal - FIX-D's own
debounce/equal-layout-is-a-no-op guarantee), and **zero**
`No capture frames` lines for the whole run - a desk-shape change that is
caught by its own dedicated path (FIX-D) should never also need the silence
watchdog (the earlier, coarser fallback) to notice it:

```
15:46:51  Display configuration changed: canvas 5552x2715 -> 5312x2559; re-arming display captures
15:47:27  Display configuration changed: canvas 5312x2559 -> 5552x2715; re-arming display captures
```

Measured on 2026-09-12, a full 115s run across two real mode changes:

```
desk-shape rebuilds : 2  (one per real change)
silence re-arms     : 0
give-ups            : 0
enumeration noise   : 2  (one "Found primary/secondary display" pair per real rebuild -
                          FIX-E: the compare-only, equal-layout path stays silent)
```

## 5. Cleanup

If the script or shell was interrupted before step 3's restore command ran,
run the restore `displayplacer` command by hand - it is idempotent and safe
to run again even if the desk is already back to its original mode.
