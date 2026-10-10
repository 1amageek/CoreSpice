#include "NativeHeapMetrics.h"
#include <malloc/malloc.h>
#include <sys/resource.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
extern void *__memcpy_chk(void *, const void *, size_t, size_t);
extern void *__memmove_chk(void *, const void *, size_t, size_t);

typedef int (*MOSCaptureFunction)(MOSAllocationSnapshot *, int);
static _Atomic(MOSCaptureFunction) capture_function;

int mos_native_allocation_initialize(void) {
    MOSCaptureFunction function = (MOSCaptureFunction)dlsym(RTLD_DEFAULT, "mos_allocation_capture");
    if (function == NULL) return 1;
    atomic_store_explicit(&capture_function, function, memory_order_release);
    return 0;
}

MOSAllocationSnapshot mos_native_allocation_capture(int resume) {
    MOSAllocationSnapshot result = { .status = 1 };
    MOSCaptureFunction function = atomic_load_explicit(&capture_function, memory_order_acquire);
    if (function != NULL) result.status = function(&result, resume);
    return result;
}

int mos_native_allocation_calibrate(void) {
    MOSAllocationSnapshot before = mos_native_allocation_capture(1);
    if (before.status != 0) return before.status;
    void *(*volatile allocate)(size_t) = malloc;
    void (*volatile release)(void *) = free;
    void *memory = allocate(257);
    int allocated = memory != NULL;
    if (memory != NULL) *((volatile unsigned char *)memory) = 91;
    release(memory);
    unsigned char source[64], target[64];
    for (unsigned i = 0; i < 64; ++i) { source[i] = (unsigned char)(i + 1); target[i] = 0; }
    void *(*volatile copy)(void *, const void *, size_t) = memcpy;
    void *(*volatile move)(void *, const void *, size_t) = memmove;
    void (*volatile bcopy_call)(const void *, void *, size_t) = bcopy;
    void *(*volatile checked_copy)(void *, const void *, size_t, size_t) = __memcpy_chk;
    void *(*volatile checked_move)(void *, const void *, size_t, size_t) = __memmove_chk;
    copy(target, source, 37);
    for (unsigned i = 0; i < 37; ++i) if (target[i] != source[i]) return 6;
    move(target + 1, target, 23);
    for (unsigned i = 0; i < 23; ++i) if (target[i + 1] != source[i]) return 6;
    bcopy_call(source, target, 17);
    for (unsigned i = 0; i < 17; ++i) if (target[i] != source[i]) return 6;
    checked_copy(target, source + 1, 13, 64);
    for (unsigned i = 0; i < 13; ++i) if (target[i] != source[i + 1]) return 6;
    checked_move(target + 1, target, 11, 63);
    for (unsigned i = 0; i < 11; ++i) if (target[i + 1] != source[i + 1]) return 6;
    MOSAllocationSnapshot after = mos_native_allocation_capture(0);
    if (!allocated || after.status != 0) return 4;
    return after.malloc_calls - before.malloc_calls == 1
        && after.free_calls - before.free_calls == 1
        && after.calloc_calls == before.calloc_calls
        && after.realloc_calls == before.realloc_calls
        && after.requested_bytes - before.requested_bytes == 257
        && (after.memcpy_calls - before.memcpy_calls)
            + (after.memmove_calls - before.memmove_calls)
            + (after.bcopy_calls - before.bcopy_calls) == 5
        && after.copied_bytes - before.copied_bytes == 101 ? 0 : 5;
}

MOSNativeHeapSnapshot mos_native_heap_snapshot(void) {
    malloc_statistics_t heap = {0};
    malloc_zone_statistics(NULL, &heap);
    struct rusage usage = {0};
    int status = getrusage(RUSAGE_SELF, &usage);
    MOSNativeHeapSnapshot result = {
        heap.blocks_in_use, heap.size_in_use, heap.max_size_in_use,
        heap.size_allocated, status == 0 ? (uint64_t)usage.ru_maxrss : 0, status
    };
    return result;
}
