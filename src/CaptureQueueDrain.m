#include "CaptureQueueDrain.h"

void
macVNCEndOperationAfterSerialQueueDrain(dispatch_queue_t sampleHandlerQueue,
                                         dispatch_group_t operationGroup)
{
    dispatch_barrier_async(sampleHandlerQueue, ^{
        dispatch_group_leave(operationGroup);
    });
}
