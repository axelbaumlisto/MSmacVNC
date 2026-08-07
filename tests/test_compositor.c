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
    return 0;
}
