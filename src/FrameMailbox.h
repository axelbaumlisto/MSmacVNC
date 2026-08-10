#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <pthread.h>

typedef void (*MacVNCFrameMailboxRelease)(void *frame);
typedef void (*MacVNCFrameMailboxActivity)(void *context);

typedef struct {
    void *frame;
    void *stream;
    uint64_t generation;
} MacVNCFrameMailboxItem;

typedef struct {
    pthread_mutex_t mutex;
    MacVNCFrameMailboxItem pending;
    bool drainScheduled;
    MacVNCFrameMailboxRelease releaseFrame;
    MacVNCFrameMailboxActivity beginActivity;
    MacVNCFrameMailboxActivity endActivity;
    void *activityContext;
} MacVNCFrameMailbox;

bool macVNCFrameMailboxInit(MacVNCFrameMailbox *mailbox,
                            MacVNCFrameMailboxRelease releaseFrame,
                            MacVNCFrameMailboxActivity beginActivity,
                            MacVNCFrameMailboxActivity endActivity,
                            void *activityContext);

/* Consumes the caller's owned frame reference. Returns true only when the
   caller must schedule a drain. Existing pending ownership is replaced. */
bool macVNCFrameMailboxSubmit(MacVNCFrameMailbox *mailbox,
                              void *frame,
                              void *stream,
                              uint64_t generation);

/* Transfers the pending frame reference to the sole drain consumer. */
bool macVNCFrameMailboxTake(MacVNCFrameMailbox *mailbox,
                            MacVNCFrameMailboxItem *item);

/* Called after the consumer releases the item it took. Returns true if a new
   pending item must be consumed by the same drain. The empty/unschedule and
   producer scheduling decisions share the mailbox lock, preventing lost work. */
bool macVNCFrameMailboxEndDrainIteration(MacVNCFrameMailbox *mailbox);

/* The owner must quiesce the drain before destroying the mailbox. */
void macVNCFrameMailboxDestroy(MacVNCFrameMailbox *mailbox);
