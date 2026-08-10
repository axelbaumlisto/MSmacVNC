#import <Foundation/Foundation.h>

#include "mac.h"
#include "ScreenCapturer.h"

#include <assert.h>
#include <pthread.h>
#include <stdio.h>

extern rfbBool preventDimming;
extern rfbBool preventSleep;

enum { STOP_THREAD_COUNT = 8 };

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    int ready;
    int participants;
    bool go;
} StartGate;

typedef struct {
    StartGate *gate;
    rfbBool result;
} StartContext;

static void waitAtGate(StartGate *gate)
{
    pthread_mutex_lock(&gate->mutex);
    ++gate->ready;
    pthread_cond_broadcast(&gate->condition);
    while (!gate->go)
        pthread_cond_wait(&gate->condition, &gate->mutex);
    pthread_mutex_unlock(&gate->mutex);
}

static void openGateWhenReady(StartGate *gate)
{
    pthread_mutex_lock(&gate->mutex);
    while (gate->ready < gate->participants)
        pthread_cond_wait(&gate->condition, &gate->mutex);
    gate->go = true;
    pthread_cond_broadcast(&gate->condition);
    pthread_mutex_unlock(&gate->mutex);
}

static void *startServer(void *opaque)
{
    StartContext *context = opaque;
    waitAtGate(context->gate);
    context->result = vncServerStart(0, "test-password", 12);
    return NULL;
}

static void *stopServer(void *opaque)
{
    waitAtGate(opaque);
    vncServerStop();
    return NULL;
}

int main(void)
{
    @autoreleasepool {
        viewOnly = TRUE;
        preventDimming = FALSE;
        preventSleep = FALSE;
        displayNumber = -2;

        CGDirectDisplayID displays[32];
        CGDisplayCount displayCount = 0;
        CGError displayError = CGGetActiveDisplayList(32, displays, &displayCount);
        if (displayError != kCGErrorSuccess || displayCount == 0) {
            puts("SKIP server initialization failure cleanup: no active display");
            return 77;
        }

        macVNCFailCaptureInitializationAfter(displayCount > 1 ? 1 : 0);

        StartGate gate = {
            .mutex = PTHREAD_MUTEX_INITIALIZER,
            .condition = PTHREAD_COND_INITIALIZER,
            .participants = STOP_THREAD_COUNT + 1,
        };
        StartContext startContext = {.gate = &gate, .result = TRUE};
        pthread_t startThread;
        pthread_t stopThreads[STOP_THREAD_COUNT];
        assert(pthread_create(&startThread, NULL, startServer, &startContext) == 0);
        for (size_t i = 0; i < STOP_THREAD_COUNT; ++i)
            assert(pthread_create(&stopThreads[i], NULL, stopServer, &gate) == 0);

        openGateWhenReady(&gate);
        assert(pthread_join(startThread, NULL) == 0);
        for (size_t i = 0; i < STOP_THREAD_COUNT; ++i)
            assert(pthread_join(stopThreads[i], NULL) == 0);

        assert(!startContext.result);
        assert(macVNCCaptureInitializationFaultWasConsumed());
        assert(vncServerGetPort() == -1);
        assert(vncConnectedClients == 0);
        assert(!macVNCServerHasLifecycleResourcesForTesting());

        /* Repeated calls remain no-ops after the concurrent stop wave. */
        vncServerStop();
        vncServerStop();
        assert(vncServerGetPort() == -1);
        assert(!macVNCServerHasLifecycleResourcesForTesting());

        pthread_cond_destroy(&gate.condition);
        pthread_mutex_destroy(&gate.mutex);
    }

    puts("server initialization failure cleanup tests passed");
    return 0;
}
