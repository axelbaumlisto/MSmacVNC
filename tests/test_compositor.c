#include "CompositeFramebuffer.h"

#include <assert.h>
#include <stdint.h>
#include <string.h>

typedef struct { int count, x, y, w, h; } Dirty;
static void dirty(void *context, int x, int y, int w, int h)
{
    Dirty *d = context; d->count++; d->x=x; d->y=y; d->w=w; d->h=h;
}

static uint8_t *pixel(uint8_t *canvas, int width, int x, int y)
{
    return canvas + ((size_t)y * width + x) * 4;
}

int main(void)
{
    uint8_t canvas[8 * 6 * 4] = {0};
    MacVNCDisplayGeometry display = {{7, -4, 2, 4, 3, 4, 3}, 1, 2};
    /* Source has four padding bytes after each 4-pixel row. */
    uint8_t source[3 * 20]; memset(source, 0, sizeof(source));
    for (int y=0; y<3; ++y) for (int x=0; x<4; ++x) {
        uint8_t *p=source + y*20 + x*4; p[0]=10+x; p[1]=20+y; p[2]=30; p[3]=255;
    }
    Dirty d={0};
    size_t changed=macVNCCompositeDisplayFrame(canvas,8,6,&display,source,20,2,dirty,&d);
    assert(changed==4 && d.count==4);
    assert(pixel(canvas,8,0,0)[0]==0); /* gap remains black */
    assert(pixel(canvas,8,1,2)[0]==10);
    assert(pixel(canvas,8,4,4)[0]==13);
    assert(pixel(canvas,8,5,2)[0]==0); /* right neighbor untouched */

    d=(Dirty){0};
    changed=macVNCCompositeDisplayFrame(canvas,8,6,&display,source,20,2,dirty,&d);
    assert(changed==0 && d.count==0);

    /* Alpha is outside the advertised 24-bit RFB color depth and must not dirty tiles. */
    for (int y=0; y<3; ++y) for (int x=0; x<4; ++x)
        source[y*20 + x*4 + 3] = (uint8_t)(x + y);
    d=(Dirty){0};
    changed=macVNCCompositeDisplayFrame(canvas,8,6,&display,source,20,2,dirty,&d);
    assert(changed==0 && d.count==0);

    source[1*20 + 2*4] = 99;
    d=(Dirty){0};
    changed=macVNCCompositeDisplayFrame(canvas,8,6,&display,source,20,2,dirty,&d);
    assert(changed==1 && d.count==1);
    assert(d.x==3 && d.y==2 && d.w==2 && d.h==2);
    assert(pixel(canvas,8,3,3)[0]==99);
    assert(pixel(canvas,8,1,2)[0]==10); /* other display pixels remain */

    /* ---- Dirty hints -------------------------------------------------- */

    /* A hint covering the change behaves exactly like a full sweep. */
    source[1*20 + 2*4] = 111;
    MacVNCDirtyRect covering = { 2, 1, 2, 2 };
    MacVNCDirtyHint hint = { &covering, 1 };
    d=(Dirty){0};
    changed=macVNCCompositeDisplayFrameHinted(canvas,8,6,&display,source,20,2,
                                              &hint,dirty,&d);
    assert(changed==1 && d.count==1);
    assert(pixel(canvas,8,3,3)[0]==111);

    /* A hint pointing ELSEWHERE leaves the changed pixel uncomposited: this is
       the whole risk of trusting a hint, and why a periodic full sweep is not
       optional. */
    source[1*20 + 2*4] = 222;
    MacVNCDirtyRect elsewhere = { 0, 0, 2, 1 };
    hint = (MacVNCDirtyHint){ &elsewhere, 1 };
    d=(Dirty){0};
    changed=macVNCCompositeDisplayFrameHinted(canvas,8,6,&display,source,20,2,
                                              &hint,dirty,&d);
    assert(changed==0 && d.count==0);
    assert(pixel(canvas,8,3,3)[0]==111); /* still the previous value */

    /* ...and the next full sweep repairs it. */
    d=(Dirty){0};
    changed=macVNCCompositeDisplayFrameHinted(canvas,8,6,&display,source,20,2,
                                              NULL,dirty,&d);
    assert(changed==1 && pixel(canvas,8,3,3)[0]==222);

    /* An empty hint (count 0) means "sweep everything", never "nothing". */
    source[1*20 + 2*4] = 33;
    hint = (MacVNCDirtyHint){ &covering, 0 };
    d=(Dirty){0};
    changed=macVNCCompositeDisplayFrameHinted(canvas,8,6,&display,source,20,2,
                                              &hint,dirty,&d);
    assert(changed==1 && pixel(canvas,8,3,3)[0]==33);

    /* Unaligned hints are widened to the tile grid, not dropped: a 1x1 rect at
       (3,3) must still composite the tile that contains it. */
    source[1*20 + 2*4] = 44;
    MacVNCDirtyRect tiny = { 3, 1, 1, 1 };
    hint = (MacVNCDirtyHint){ &tiny, 1 };
    d=(Dirty){0};
    changed=macVNCCompositeDisplayFrameHinted(canvas,8,6,&display,source,20,2,
                                              &hint,dirty,&d);
    assert(changed==1 && pixel(canvas,8,3,3)[0]==44);

    /* Hostile hints: negative origins, sizes past the frame, zero area. They
       must be clamped, never read or written out of bounds (ASan/UBSan would
       trap here otherwise). */
    source[1*20 + 2*4] = 55;
    MacVNCDirtyRect hostile[] = {
        { -100, -100, 4, 3 },      /* clamped to the top-left corner */
        { 0, 0, 1000000, 1000000 },/* clamped to the frame */
        { 2, 1, 0, 0 },            /* empty */
        { 10, 10, 4, 4 },          /* entirely outside */
    };
    hint = (MacVNCDirtyHint){ hostile, 4 };
    d=(Dirty){0};
    changed=macVNCCompositeDisplayFrameHinted(canvas,8,6,&display,source,20,2,
                                              &hint,dirty,&d);
    assert(changed>=1 && pixel(canvas,8,3,3)[0]==55);

    /* The unused byte must be forced to 0 in the canvas even when the source
       carries opaque alpha: clients are told the depth is 24, and leaving the
       byte at 0xFF would publish uninitialised-looking data. */
    for (int i = 0; i < 3 * 20; i += 4)
        source[i + 3] = 0xFF;
    source[1*20 + 2*4] = 77;
    d=(Dirty){0};
    changed=macVNCCompositeDisplayFrameHinted(canvas,8,6,&display,source,20,2,
                                              NULL,dirty,&d);
    assert(changed==1 && pixel(canvas,8,3,3)[0]==77);
    assert(pixel(canvas,8,3,3)[3]==0);

    /* Overlapping rects must not double-report a tile: the second visit finds
       it already identical. */
    source[1*20 + 2*4] = 66;
    MacVNCDirtyRect overlap[] = { { 2, 1, 2, 2 }, { 2, 1, 2, 2 }, { 1, 0, 4, 3 } };
    hint = (MacVNCDirtyHint){ overlap, 3 };
    d=(Dirty){0};
    changed=macVNCCompositeDisplayFrameHinted(canvas,8,6,&display,source,20,2,
                                              &hint,dirty,&d);
    assert(changed==1 && d.count==1 && pixel(canvas,8,3,3)[0]==66);

    /* A tile whose width is ODD exercises the single-pixel tail of the
       compare/copy loops, which the 2-pixel-wide tiles above never reach. */
    {
        uint8_t tailCanvas[8 * 6 * 4];
        uint8_t tailSource[3 * 20];
        memset(tailCanvas, 0, sizeof(tailCanvas));
        memset(tailSource, 7, sizeof(tailSource));
        for (int i = 0; i < 3 * 20; i += 4)
            tailSource[i + 3] = 0xFF; /* opaque source, depth-24 canvas */

        MacVNCDisplayGeometry tailDisplay = display;
        d=(Dirty){0};
        /* tileSize 3 over a 4-wide display: tiles are 3 and 1 pixels wide. */
        changed=macVNCCompositeDisplayFrameHinted(tailCanvas,8,6,&tailDisplay,
                                                  tailSource,20,3,NULL,dirty,&d);
        assert(changed==2);
        const uint8_t *tailPixel = pixel(tailCanvas,8,
                                        tailDisplay.framebufferX + 3,
                                        tailDisplay.framebufferY);
        assert(tailPixel[0]==7 && tailPixel[3]==0);
    }

    return 0;
}
