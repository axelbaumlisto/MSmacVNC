#import "MacVNCCompositor.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#import "CompositeFramebuffer.h"

/* Tile size (pixels) for dirty-region comparison. */
#define TILE_SIZE 64

/* Serialises compositing so two displays' frames cannot interleave writes into
   the shared canvas. */
static pthread_mutex_t compositorMutex = PTHREAD_MUTEX_INITIALIZER;

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
       single client that stops reading its socket (congested link, suspended
       viewer, or a hostile peer stalling TCP) would otherwise block the
       compositor — freezing the screen for ALL clients indefinitely. If any
       client is mid-send we back out cleanly and simply skip this frame; the
       next captured frame retries. */
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

/* Returns TRUE when the frame was composited. FALSE means "not now" (a client
   was mid-send): the caller must retry this frame rather than drop it. */
rfbBool
macVNCCompositorSubmitFrame(rfbScreenInfoPtr screen,
                            CMSampleBufferRef sampleBuffer,
                            const MacVNCDisplayGeometry *geometry)
{
    if (!screen || !screen->frameBuffer || !geometry)
        return TRUE; /* server torn down mid-flight; nothing to retry into */

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer)
        return TRUE; /* nothing to composite; not a retryable condition */
    if ((int)CVPixelBufferGetWidth(pixelBuffer) != geometry->input.pixelWidth ||
        (int)CVPixelBufferGetHeight(pixelBuffer) != geometry->input.pixelHeight) {
        rfbErr("Unexpected display %u frame size %zux%zu (expected %dx%d)\n",
               geometry->input.displayID,
               CVPixelBufferGetWidth(pixelBuffer),
               CVPixelBufferGetHeight(pixelBuffer),
               geometry->input.pixelWidth,
               geometry->input.pixelHeight);
        return TRUE; /* wrong geometry: retrying cannot help */
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    const uint8_t *source = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer);

    pthread_mutex_lock(&compositorMutex);
    LockedClientSet lockedClients;
    if (!lockCurrentClients(screen, &lockedClients)) {
        pthread_mutex_unlock(&compositorMutex);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        /* Either OOM or (far more commonly) a client is mid-send. Report
           "not composited" so the caller re-submits this frame instead of
           losing its pixels (the screen may go static right after). */
        return FALSE;
    }

    macVNCCompositeDisplayFrame((uint8_t *)screen->frameBuffer,
                                screen->width,
                                screen->height,
                                geometry,
                                source,
                                sourceStride,
                                TILE_SIZE,
                                markCompositeDirty,
                                screen);

    unlockCurrentClients(&lockedClients);
    pthread_mutex_unlock(&compositorMutex);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    return TRUE;
}
