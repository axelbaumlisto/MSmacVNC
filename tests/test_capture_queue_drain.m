#include "CaptureQueueDrain.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>

int main(void)
{
    dispatch_queue_t sampleQueue = dispatch_queue_create(
        "net.christianbeier.macVNC.test-capture-callback", DISPATCH_QUEUE_SERIAL);
    dispatch_group_t operationGroup = dispatch_group_create();

    /* Two cycles model stop followed by restart on the same owned, drained
       sample-handler queue. */
    for (int cycle = 0; cycle < 2; ++cycle) {
        dispatch_semaphore_t callbackStarted = dispatch_semaphore_create(0);
        dispatch_semaphore_t allowCallbackToFinish = dispatch_semaphore_create(0);
        __block atomic_bool callbackFinished = false;

        dispatch_async(sampleQueue, ^{
            dispatch_semaphore_signal(callbackStarted);
            dispatch_semaphore_wait(allowCallbackToFinish, DISPATCH_TIME_FOREVER);
            atomic_store(&callbackFinished, true);
        });
        assert(dispatch_semaphore_wait(callbackStarted,
                                       dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);

        /* Model stop's sentinel: completion has occurred, but a callback that
           was already admitted to the serial sample queue is still blocked. */
        dispatch_group_enter(operationGroup);
        macVNCEndOperationAfterSerialQueueDrain(sampleQueue, operationGroup);
        assert(dispatch_group_wait(operationGroup,
                                   dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC)) != 0);
        assert(!atomic_load(&callbackFinished));

        dispatch_semaphore_signal(allowCallbackToFinish);
        assert(dispatch_group_wait(operationGroup,
                                   dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
        assert(atomic_load(&callbackFinished));

        dispatch_release(allowCallbackToFinish);
        dispatch_release(callbackStarted);
    }

    dispatch_release(operationGroup);
    dispatch_release(sampleQueue);
    puts("capture callback queue drain tests passed");
    return 0;
}
