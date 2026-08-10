#include "FrameMailbox.h"

#include <assert.h>
#include <string.h>

bool
macVNCFrameMailboxInit(MacVNCFrameMailbox *mailbox,
                       MacVNCFrameMailboxRelease releaseFrame,
                       MacVNCFrameMailboxActivity beginActivity,
                       MacVNCFrameMailboxActivity endActivity,
                       void *activityContext)
{
    if (!mailbox || !releaseFrame || !beginActivity || !endActivity)
        return false;
    memset(mailbox, 0, sizeof(*mailbox));
    if (pthread_mutex_init(&mailbox->mutex, NULL) != 0)
        return false;
    mailbox->releaseFrame = releaseFrame;
    mailbox->beginActivity = beginActivity;
    mailbox->endActivity = endActivity;
    mailbox->activityContext = activityContext;
    return true;
}

bool
macVNCFrameMailboxSubmit(MacVNCFrameMailbox *mailbox,
                         void *frame,
                         void *stream,
                         uint64_t generation)
{
    assert(mailbox);
    assert(frame);
    bool scheduleDrain = false;
    /* Account for the admission itself. This keeps quiescence nonzero if a
       producer races the drain's empty-to-unscheduled transition. */
    mailbox->beginActivity(mailbox->activityContext);
    pthread_mutex_lock(&mailbox->mutex);
    if (mailbox->pending.frame)
        mailbox->releaseFrame(mailbox->pending.frame);
    mailbox->pending = (MacVNCFrameMailboxItem){
        .frame = frame,
        .stream = stream,
        .generation = generation,
    };
    if (!mailbox->drainScheduled) {
        mailbox->drainScheduled = true;
        /* Enter quiescence accounting before publishing the scheduling result. */
        mailbox->beginActivity(mailbox->activityContext);
        scheduleDrain = true;
    }
    pthread_mutex_unlock(&mailbox->mutex);
    mailbox->endActivity(mailbox->activityContext);
    return scheduleDrain;
}

bool
macVNCFrameMailboxTake(MacVNCFrameMailbox *mailbox,
                       MacVNCFrameMailboxItem *item)
{
    assert(mailbox);
    assert(item);
    pthread_mutex_lock(&mailbox->mutex);
    bool available = mailbox->pending.frame != NULL;
    if (available) {
        *item = mailbox->pending;
        memset(&mailbox->pending, 0, sizeof(mailbox->pending));
    }
    pthread_mutex_unlock(&mailbox->mutex);
    return available;
}

bool
macVNCFrameMailboxEndDrainIteration(MacVNCFrameMailbox *mailbox)
{
    assert(mailbox);
    pthread_mutex_lock(&mailbox->mutex);
    bool continueDraining = mailbox->pending.frame != NULL;
    if (!continueDraining)
        mailbox->drainScheduled = false;
    pthread_mutex_unlock(&mailbox->mutex);
    /* This is the drain's final mailbox access. A racing producer enters its
       own activity before taking the lock, so the activity count cannot reach
       zero between unscheduling and replacement scheduling. */
    if (!continueDraining)
        mailbox->endActivity(mailbox->activityContext);
    return continueDraining;
}

void
macVNCFrameMailboxDestroy(MacVNCFrameMailbox *mailbox)
{
    if (!mailbox)
        return;
    pthread_mutex_lock(&mailbox->mutex);
    assert(!mailbox->drainScheduled);
    if (mailbox->pending.frame) {
        mailbox->releaseFrame(mailbox->pending.frame);
        memset(&mailbox->pending, 0, sizeof(mailbox->pending));
    }
    pthread_mutex_unlock(&mailbox->mutex);
    pthread_mutex_destroy(&mailbox->mutex);
}
