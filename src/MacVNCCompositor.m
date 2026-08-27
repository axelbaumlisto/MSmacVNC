#import "MacVNCCompositor.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#import "CompositeFramebuffer.h"
#import <rfb/rfbregion.h>

/* Tile size (pixels) for dirty-region comparison. */
#define TILE_SIZE 64

/* Serialises compositing so two displays' frames cannot interleave writes into
   the shared canvas - AND owns the screen pointer's lifetime (see SetScreen). */
static pthread_mutex_t compositorMutex = PTHREAD_MUTEX_INITIALIZER;
static rfbScreenInfoPtr compositorScreen = NULL;

/* Dirty-marking runs WITHOUT any client sendMutex held: rfbMarkRectAsModified
   only takes each client's updateMutex (verified in the 0.9.15 sources,
   main.c:412-426), and both lock paths order sendMutex above updateMutex, so
   painting first and marking after cannot create a cycle. Holding sendMutexes
   during the paint was the round-5 anti-freeze design - and it starved the
   FIRST paint whenever two clients were each streaming their huge initial
   frame at connect time: trylock-any-fail meant no pixels landed in the
   framebuffer at all, and every viewer sat on libvncserver's checkerboard
   until the initial-send storm subsided (~20s observed on iPad+second client). */
typedef struct {
    rfbScreenInfoPtr screen;
    sraRegion *dirtyRegion;    /* tiles painted this frame, unioned */
} CompositeContext;

static void
markCompositeDirty(void *context, int x, int y, int width, int height)
{
    CompositeContext *ctx = context;
    (void)ctx->screen;
    /* Accumulate here (compositorMutex is held), notify ONCE after the paint:
       the notify walks clients taking updateMutex per client - doing that per
       tile multiplied lock traffic by tile count for no benefit. */
    sraRegionPtr region = sraRgnCreateRect(x, y, x + width, y + height);
    if (!ctx->dirtyRegion) {
        ctx->dirtyRegion = region;
    } else {
        sraRgnOr(ctx->dirtyRegion, region);
        sraRgnDestroy(region);
    }
}

void
macVNCCompositorSetScreen(rfbScreenInfoPtr screen)
{
    /* Blocks until any in-flight composite finishes, so returning here
       guarantees no callback will touch this screen again. */
    pthread_mutex_lock(&compositorMutex);
    compositorScreen = screen;
    pthread_mutex_unlock(&compositorMutex);
}

rfbBool
macVNCCompositorSubmitFrame(const MacVNCDisplayGeometry *geometry,
                            const uint8_t *pixels,
                            size_t stride)
{
    if (!geometry || !pixels)
        return TRUE; /* nothing to composite; not a retryable condition */

    pthread_mutex_lock(&compositorMutex);
    /* Read INSIDE the lock: the pointer was loaded before a teardown detached
       it once, and then pointed at freed memory. */
    rfbScreenInfoPtr screen = compositorScreen;
    if (!screen || !screen->frameBuffer) {
        pthread_mutex_unlock(&compositorMutex);
        return TRUE; /* server torn down mid-flight; nothing to retry into */
    }

    /* PAINT without touching any client's sendMutex. The framebuffer is the
       shared truth; writing it must not depend on how busy viewers are.
       Round-5 required all client sendMutexes via trylock to keep slow clients
       from corrupting a paint - but rfbSendFramebufferUpdate copies out of the
       framebuffer under updateMutex which serializes against OUR marking
       (rfbMarkRectAsModified), not against our painting... that hole existed
       there too and nobody saw tearing in practice because paints are rare
       relative to sends; still, correctness is now carried by ONE lock:
       everything that reads or writes screen->frameBuffer from our side holds
       compositorMutex (this function), and LibVNCServer's own copy path holds
       updateMutex while reading. The residual race with a concurrent server
       read is unchanged from pre-round-5 behaviour and bounded to one frame. */

    CompositeContext ctx = { screen, NULL };
    macVNCCompositeDisplayFrame((uint8_t *)screen->frameBuffer,
                                screen->width,
                                screen->height,
                                geometry,
                                pixels,
                                stride,
                                TILE_SIZE,
                                markCompositeDirty,
                                &ctx);

    if (ctx.dirtyRegion) {
        /* Notify outside the paint but still under compositorMutex: this wakes
           client threads, which then serialize against a NEXT paint rather than
           against this one. Marking cannot starve painting any more - that is
           the whole point of the reorder. */
        rfbMarkRegionAsModified(screen, ctx.dirtyRegion);
        sraRgnDestroy(ctx.dirtyRegion);
    }
    pthread_mutex_unlock(&compositorMutex);
    return TRUE;
}
