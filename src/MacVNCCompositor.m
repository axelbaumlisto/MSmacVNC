#import "MacVNCCompositor.h"

#include <pthread.h>
#include <stdatomic.h>
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

static void
markCompositeDirty(void *context, int x, int y, int width, int height)
{
    rfbMarkRectAsModified((rfbScreenInfoPtr)context, x, y, x + width, y + height);
}

typedef struct {
    rfbClientPtr *items;
    size_t count;
} LockedClientSet;

static rfbBool
lockCurrentClients(rfbScreenInfoPtr screen, LockedClientSet *set)
{
    memset(set, 0, sizeof(*set));
    size_t capacity = 0;
    rfbClientIteratorPtr iterator = rfbGetClientIterator(screen);
    rfbClientPtr client;
    while ((client = rfbClientIteratorNext(iterator))) {
        if (set->count == capacity) {
            size_t nextCapacity = capacity ? capacity * 2 : 4;
            rfbClientPtr *next = realloc(set->items, nextCapacity * sizeof(*next));
            if (!next) {
                rfbReleaseClientIterator(iterator);
                for (size_t i = 0; i < set->count; ++i)
                    rfbDecrClientRef(set->items[i]);
                free(set->items);
                memset(set, 0, sizeof(*set));
                return FALSE;
            }
            set->items = next;
            capacity = nextCapacity;
        }
        rfbIncrClientRef(client);
        set->items[set->count++] = client;
    }
    rfbReleaseClientIterator(iterator);

    /* Acquire every client's sendMutex with trylock, never a blocking lock.
       LibVNCServer holds sendMutex for the whole encode+socket write, so a
       single client that stops reading its socket would otherwise block the
       compositor - freezing the screen for ALL clients. If any client is
       mid-send we back out cleanly and the frame is re-submitted by
       ScreenCapturer's retry. */
    for (size_t i = 0; i < set->count; ++i) {
        if (pthread_mutex_trylock(&set->items[i]->sendMutex) != 0) {
            for (size_t j = i; j > 0; --j)
                UNLOCK(set->items[j - 1]->sendMutex);
            for (size_t j = 0; j < set->count; ++j)
                rfbDecrClientRef(set->items[j]);
            free(set->items);
            memset(set, 0, sizeof(*set));
            return FALSE;
        }
    }
    return TRUE;
}

static void
unlockCurrentClients(LockedClientSet *set)
{
    for (size_t i = set->count; i > 0; --i)
        UNLOCK(set->items[i - 1]->sendMutex);
    for (size_t i = 0; i < set->count; ++i)
        rfbDecrClientRef(set->items[i]);
    free(set->items);
    memset(set, 0, sizeof(*set));
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
                            size_t stride,
                            const MacVNCDirtyHint *hint)
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
    LockedClientSet lockedClients;
    if (!lockCurrentClients(screen, &lockedClients)) {
        pthread_mutex_unlock(&compositorMutex);
        /* Either OOM or (far more commonly) a client is mid-send. Report
           "not composited" so the caller re-submits this frame instead of
           losing its pixels (the screen may go static right after). */
        return FALSE;
    }

    macVNCCompositeDisplayFrameHinted((uint8_t *)screen->frameBuffer,
                                      screen->width,
                                      screen->height,
                                      geometry,
                                      pixels,
                                      stride,
                                      TILE_SIZE,
                                      hint,
                                      markCompositeDirty,
                                      screen);

    unlockCurrentClients(&lockedClients);
    pthread_mutex_unlock(&compositorMutex);
    return TRUE;
}
