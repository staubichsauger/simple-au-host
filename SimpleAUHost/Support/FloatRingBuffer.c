#include "FloatRingBuffer.h"

#include <stdlib.h>
#include <string.h>

static uint32_t SAHRoundUpPowerOfTwo(uint32_t value) {
    if (value < 2) {
        return 2;
    }

    value -= 1;
    value |= value >> 1;
    value |= value >> 2;
    value |= value >> 4;
    value |= value >> 8;
    value |= value >> 16;
    return value + 1;
}

bool SAHFloatRingBufferInit(SAHFloatRingBuffer *buffer, uint32_t minimumCapacity) {
    if (buffer == NULL) {
        return false;
    }

    SAHFloatRingBufferDeinit(buffer);

    buffer->capacity = SAHRoundUpPowerOfTwo(minimumCapacity);
    buffer->storage = (float *)calloc(buffer->capacity, sizeof(float));
    if (buffer->storage == NULL) {
        buffer->capacity = 0;
        return false;
    }

    atomic_store_explicit(&buffer->read_index, 0, memory_order_relaxed);
    atomic_store_explicit(&buffer->write_index, 0, memory_order_relaxed);
    return true;
}

void SAHFloatRingBufferDeinit(SAHFloatRingBuffer *buffer) {
    if (buffer == NULL) {
        return;
    }

    if (buffer->storage != NULL) {
        free(buffer->storage);
        buffer->storage = NULL;
    }

    buffer->capacity = 0;
    atomic_store_explicit(&buffer->read_index, 0, memory_order_relaxed);
    atomic_store_explicit(&buffer->write_index, 0, memory_order_relaxed);
}

void SAHFloatRingBufferClear(SAHFloatRingBuffer *buffer) {
    if (buffer == NULL) {
        return;
    }

    uint64_t write_index = atomic_load_explicit(&buffer->write_index, memory_order_acquire);
    atomic_store_explicit(&buffer->read_index, write_index, memory_order_release);
}

uint32_t SAHFloatRingBufferWrite(SAHFloatRingBuffer *buffer, const float *input, uint32_t count) {
    if (buffer == NULL || buffer->storage == NULL || input == NULL || count == 0) {
        return 0;
    }

    uint64_t read_index = atomic_load_explicit(&buffer->read_index, memory_order_acquire);
    uint64_t write_index = atomic_load_explicit(&buffer->write_index, memory_order_relaxed);
    uint64_t available = (uint64_t)buffer->capacity - (write_index - read_index);
    uint32_t write_count = count < available ? count : (uint32_t)available;
    if (write_count == 0) {
        return 0;
    }

    uint32_t mask = buffer->capacity - 1;
    uint32_t offset = (uint32_t)write_index & mask;
    uint32_t first_chunk = write_count;
    if (offset + write_count > buffer->capacity) {
        first_chunk = buffer->capacity - offset;
    }

    memcpy(buffer->storage + offset, input, first_chunk * sizeof(float));
    if (write_count > first_chunk) {
        memcpy(buffer->storage, input + first_chunk, (write_count - first_chunk) * sizeof(float));
    }

    atomic_store_explicit(&buffer->write_index, write_index + write_count, memory_order_release);
    return write_count;
}

uint32_t SAHFloatRingBufferRead(SAHFloatRingBuffer *buffer, float *output, uint32_t count) {
    if (buffer == NULL || buffer->storage == NULL || output == NULL || count == 0) {
        return 0;
    }

    uint64_t write_index = atomic_load_explicit(&buffer->write_index, memory_order_acquire);
    uint64_t read_index = atomic_load_explicit(&buffer->read_index, memory_order_relaxed);
    uint64_t available = write_index - read_index;
    uint32_t read_count = count < available ? count : (uint32_t)available;
    if (read_count == 0) {
        return 0;
    }

    uint32_t mask = buffer->capacity - 1;
    uint32_t offset = (uint32_t)read_index & mask;
    uint32_t first_chunk = read_count;
    if (offset + read_count > buffer->capacity) {
        first_chunk = buffer->capacity - offset;
    }

    memcpy(output, buffer->storage + offset, first_chunk * sizeof(float));
    if (read_count > first_chunk) {
        memcpy(output + first_chunk, buffer->storage, (read_count - first_chunk) * sizeof(float));
    }

    atomic_store_explicit(&buffer->read_index, read_index + read_count, memory_order_release);
    return read_count;
}

void SAHAtomicCounterReset(SAHAtomicCounter *counter) {
    if (counter == NULL) {
        return;
    }

    atomic_store_explicit(&counter->value, 0, memory_order_relaxed);
}

uint64_t SAHAtomicCounterLoad(const SAHAtomicCounter *counter) {
    if (counter == NULL) {
        return 0;
    }

    return atomic_load_explicit(&counter->value, memory_order_relaxed);
}

void SAHAtomicCounterIncrement(SAHAtomicCounter *counter) {
    if (counter == NULL) {
        return;
    }

    atomic_fetch_add_explicit(&counter->value, 1, memory_order_relaxed);
}
