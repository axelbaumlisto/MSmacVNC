#include "FrameMailbox.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct {
    int value;
    atomic_int *released;
} TestFrame;

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    int count;
} Activity;

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    int waiting;
    bool open;
} StartGate;

static TestFrame *new_frame(int value, atomic_int *released)
{
    TestFrame *frame = malloc(sizeof(*frame));
    assert(frame);
    frame->value = value;
    frame->released = released;
    return frame;
}

static void release_frame(void *opaque)
{
    TestFrame *frame = opaque;
    atomic_fetch_add(frame->released, 1);
    free(frame);
}

static void begin_activity(void *opaque)
{
    Activity *activity = opaque;
    pthread_mutex_lock(&activity->mutex);
    ++activity->count;
    pthread_mutex_unlock(&activity->mutex);
}

static void end_activity(void *opaque)
{
    Activity *activity = opaque;
    pthread_mutex_lock(&activity->mutex);
    assert(activity->count > 0);
    --activity->count;
    pthread_cond_broadcast(&activity->condition);
    pthread_mutex_unlock(&activity->mutex);
}

static void activity_init(Activity *activity)
{
    memset(activity, 0, sizeof(*activity));
    assert(pthread_mutex_init(&activity->mutex, NULL) == 0);
    assert(pthread_cond_init(&activity->condition, NULL) == 0);
}

static void activity_wait_idle(Activity *activity)
{
    pthread_mutex_lock(&activity->mutex);
    while (activity->count != 0)
        pthread_cond_wait(&activity->condition, &activity->mutex);
    pthread_mutex_unlock(&activity->mutex);
}

static void activity_destroy(Activity *activity)
{
    assert(activity->count == 0);
    pthread_cond_destroy(&activity->condition);
    pthread_mutex_destroy(&activity->mutex);
}

static void start_gate_init(StartGate *gate, int waiting)
{
    memset(gate, 0, sizeof(*gate));
    gate->waiting = waiting;
    assert(pthread_mutex_init(&gate->mutex, NULL) == 0);
    assert(pthread_cond_init(&gate->condition, NULL) == 0);
}

static void start_gate_wait(StartGate *gate)
{
    pthread_mutex_lock(&gate->mutex);
    if (--gate->waiting == 0) {
        gate->open = true;
        pthread_cond_broadcast(&gate->condition);
    }
    while (!gate->open)
        pthread_cond_wait(&gate->condition, &gate->mutex);
    pthread_mutex_unlock(&gate->mutex);
}

static void start_gate_destroy(StartGate *gate)
{
    pthread_cond_destroy(&gate->condition);
    pthread_mutex_destroy(&gate->mutex);
}

static void test_latest_replaces_pending_and_preserves_metadata(void)
{
    atomic_int released = 0;
    Activity activity;
    activity_init(&activity);
    MacVNCFrameMailbox mailbox;
    assert(macVNCFrameMailboxInit(&mailbox, release_frame, begin_activity,
                                  end_activity, &activity));

    void *stream = (void *)0x1234;
    assert(macVNCFrameMailboxSubmit(&mailbox, new_frame(1, &released), stream, 7));
    MacVNCFrameMailboxItem item;
    assert(macVNCFrameMailboxTake(&mailbox, &item));
    assert(((TestFrame *)item.frame)->value == 1);
    assert(item.stream == stream);
    assert(item.generation == 7);

    for (int value = 2; value <= 100; ++value)
        assert(!macVNCFrameMailboxSubmit(&mailbox, new_frame(value, &released), stream, 7));
    assert(atomic_load(&released) == 98);

    release_frame(item.frame);
    assert(macVNCFrameMailboxEndDrainIteration(&mailbox));
    assert(macVNCFrameMailboxTake(&mailbox, &item));
    assert(((TestFrame *)item.frame)->value == 100);
    assert(item.stream == stream);
    assert(item.generation == 7);
    release_frame(item.frame);
    assert(!macVNCFrameMailboxEndDrainIteration(&mailbox));
    activity_wait_idle(&activity);
    assert(atomic_load(&released) == 100);

    macVNCFrameMailboxDestroy(&mailbox);
    activity_destroy(&activity);
}

typedef struct {
    MacVNCFrameMailbox *mailbox;
    StartGate *gate;
    atomic_int *released;
    atomic_int *scheduled;
    int value;
} ProducerArgs;

static void *concurrent_producer(void *opaque)
{
    ProducerArgs *args = opaque;
    start_gate_wait(args->gate);
    if (macVNCFrameMailboxSubmit(args->mailbox,
                                 new_frame(args->value, args->released),
                                 (void *)0x5678, 11))
        atomic_fetch_add(args->scheduled, 1);
    return NULL;
}

static void test_concurrent_admission_has_one_drain_owner(void)
{
    enum { ProducerCount = 32 };
    atomic_int released = 0;
    atomic_int scheduled = 0;
    Activity activity;
    activity_init(&activity);
    MacVNCFrameMailbox mailbox;
    assert(macVNCFrameMailboxInit(&mailbox, release_frame, begin_activity,
                                  end_activity, &activity));
    StartGate gate;
    start_gate_init(&gate, ProducerCount);
    pthread_t threads[ProducerCount];
    ProducerArgs args[ProducerCount];
    for (int i = 0; i < ProducerCount; ++i) {
        args[i] = (ProducerArgs){&mailbox, &gate, &released, &scheduled, i};
        assert(pthread_create(&threads[i], NULL, concurrent_producer, &args[i]) == 0);
    }
    for (int i = 0; i < ProducerCount; ++i)
        pthread_join(threads[i], NULL);

    assert(atomic_load(&scheduled) == 1);
    assert(atomic_load(&released) == ProducerCount - 1);
    MacVNCFrameMailboxItem item;
    assert(macVNCFrameMailboxTake(&mailbox, &item));
    assert(item.stream == (void *)0x5678);
    assert(item.generation == 11);
    release_frame(item.frame);
    assert(!macVNCFrameMailboxEndDrainIteration(&mailbox));
    activity_wait_idle(&activity);
    assert(atomic_load(&released) == ProducerCount);

    start_gate_destroy(&gate);
    macVNCFrameMailboxDestroy(&mailbox);
    activity_destroy(&activity);
}

typedef struct {
    MacVNCFrameMailbox *mailbox;
    StartGate *gate;
    bool continueDrain;
} EndArgs;

static void *end_drain_racer(void *opaque)
{
    EndArgs *args = opaque;
    start_gate_wait(args->gate);
    args->continueDrain = macVNCFrameMailboxEndDrainIteration(args->mailbox);
    return NULL;
}

static void test_no_lost_wakeup_at_unschedule_boundary(void)
{
    for (int iteration = 0; iteration < 500; ++iteration) {
        atomic_int released = 0;
        atomic_int scheduled = 0;
        Activity activity;
        activity_init(&activity);
        MacVNCFrameMailbox mailbox;
        assert(macVNCFrameMailboxInit(&mailbox, release_frame, begin_activity,
                                      end_activity, &activity));
        assert(macVNCFrameMailboxSubmit(&mailbox, new_frame(1, &released), NULL, 1));
        MacVNCFrameMailboxItem first;
        assert(macVNCFrameMailboxTake(&mailbox, &first));
        release_frame(first.frame);

        StartGate gate;
        start_gate_init(&gate, 2);
        EndArgs endArgs = {&mailbox, &gate, false};
        ProducerArgs producerArgs = {&mailbox, &gate, &released, &scheduled, 2};
        pthread_t endThread, producerThread;
        assert(pthread_create(&endThread, NULL, end_drain_racer, &endArgs) == 0);
        assert(pthread_create(&producerThread, NULL, concurrent_producer, &producerArgs) == 0);
        pthread_join(endThread, NULL);
        pthread_join(producerThread, NULL);

        /* Producer-first keeps the existing drain; end-first schedules a new one. */
        assert(endArgs.continueDrain || atomic_load(&scheduled) == 1);
        MacVNCFrameMailboxItem second;
        assert(macVNCFrameMailboxTake(&mailbox, &second));
        assert(((TestFrame *)second.frame)->value == 2);
        release_frame(second.frame);
        assert(!macVNCFrameMailboxEndDrainIteration(&mailbox));
        activity_wait_idle(&activity);
        assert(atomic_load(&released) == 2);

        start_gate_destroy(&gate);
        macVNCFrameMailboxDestroy(&mailbox);
        activity_destroy(&activity);
    }
}

typedef struct {
    Activity *activity;
    atomic_bool returned;
} WaiterArgs;

static void *idle_waiter(void *opaque)
{
    WaiterArgs *args = opaque;
    activity_wait_idle(args->activity);
    atomic_store(&args->returned, true);
    return NULL;
}

static void test_lifecycle_waits_for_processing(void)
{
    atomic_int released = 0;
    Activity activity;
    activity_init(&activity);
    MacVNCFrameMailbox mailbox;
    assert(macVNCFrameMailboxInit(&mailbox, release_frame, begin_activity,
                                  end_activity, &activity));
    assert(macVNCFrameMailboxSubmit(&mailbox, new_frame(9, &released),
                                    (void *)0x1111, 41));
    MacVNCFrameMailboxItem item;
    assert(macVNCFrameMailboxTake(&mailbox, &item));
    assert(item.stream == (void *)0x1111);

    WaiterArgs waiterArgs = {&activity, false};
    pthread_t waiter;
    assert(pthread_create(&waiter, NULL, idle_waiter, &waiterArgs) == 0);
    struct timespec pause = {.tv_sec = 0, .tv_nsec = 10000000};
    nanosleep(&pause, NULL);
    assert(!atomic_load(&waiterArgs.returned));

    release_frame(item.frame);
    assert(!macVNCFrameMailboxEndDrainIteration(&mailbox));
    pthread_join(waiter, NULL);
    assert(atomic_load(&waiterArgs.returned));
    assert(atomic_load(&released) == 1);

    macVNCFrameMailboxDestroy(&mailbox);
    activity_destroy(&activity);
}

int main(void)
{
    test_latest_replaces_pending_and_preserves_metadata();
    test_concurrent_admission_has_one_drain_owner();
    test_no_lost_wakeup_at_unschedule_boundary();
    test_lifecycle_waits_for_processing();
    puts("frame mailbox tests passed");
    return 0;
}
