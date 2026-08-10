#pragma once

#include <dispatch/dispatch.h>

/* The caller must enter operationGroup before initiating asynchronous stop.
   This schedules the matching leave after every block already admitted to the
   owned serial sample-handler queue has finished. */
void macVNCEndOperationAfterSerialQueueDrain(dispatch_queue_t sampleHandlerQueue,
                                              dispatch_group_t operationGroup);
