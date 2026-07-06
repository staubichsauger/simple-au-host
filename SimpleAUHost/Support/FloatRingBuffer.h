#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>

typedef struct SAHFloatRingBuffer {
    float *storage;
    uint32_t capacity;
    _Atomic uint64_t read_index;
    _Atomic uint64_t write_index;
} SAHFloatRingBuffer;
typedef struct SAHAtomicCounter {
    _Atomic uint64_t value;
} SAHAtomicCounter;

// `buffer` must be zero-initialized before its first init call. Init may be
// called again on an initialized buffer to resize; it frees previous storage.
bool SAHFloatRingBufferInit(SAHFloatRingBuffer *buffer, uint32_t minimumCapacity);
void SAHFloatRingBufferDeinit(SAHFloatRingBuffer *buffer);
void SAHFloatRingBufferClear(SAHFloatRingBuffer *buffer);
uint32_t SAHFloatRingBufferAvailableRead(const SAHFloatRingBuffer *buffer);
uint32_t SAHFloatRingBufferAvailableWrite(const SAHFloatRingBuffer *buffer);
uint32_t SAHFloatRingBufferRead(SAHFloatRingBuffer *buffer, float *output, uint32_t count);
uint32_t SAHFloatRingBufferWrite(SAHFloatRingBuffer *buffer, const float *input, uint32_t count);
void SAHAtomicCounterReset(SAHAtomicCounter *counter);
uint64_t SAHAtomicCounterLoad(const SAHAtomicCounter *counter);
void SAHAtomicCounterIncrement(SAHAtomicCounter *counter);
void SAHAtomicCounterAdd(SAHAtomicCounter *counter, uint64_t amount);
void SAHAtomicCounterStoreMax(SAHAtomicCounter *counter, uint64_t candidate);
