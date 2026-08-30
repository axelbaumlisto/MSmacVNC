#include "DisplayReadiness.h"

static bool
contains(const uint32_t *list, size_t count, uint32_t id)
{
    if (list == NULL)
        return false;
    for (size_t i = 0; i < count; ++i)
        if (list[i] == id)
            return true;
    return false;
}

bool
macVNCDisplaysAllActive(const uint32_t *active, size_t activeCount,
                        const uint32_t *expected, size_t expectedCount)
{
    /* Nothing expected means nothing to wait for. See the header: this is the
       "could not read the online list" path, and blocking there would cost the
       whole startup budget on every launch. */
    if (expectedCount == 0)
        return true;
    if (expected == NULL)
        return true;

    for (size_t i = 0; i < expectedCount; ++i)
        if (!contains(active, activeCount, expected[i]))
            return false;
    return true;
}

size_t
macVNCDisplaysMissing(const uint32_t *active, size_t activeCount,
                      const uint32_t *expected, size_t expectedCount,
                      uint32_t *out, size_t outCapacity)
{
    if (out == NULL || outCapacity == 0 || expected == NULL)
        return 0;

    size_t written = 0;
    for (size_t i = 0; i < expectedCount && written < outCapacity; ++i)
        if (!contains(active, activeCount, expected[i]))
            out[written++] = expected[i];
    return written;
}
