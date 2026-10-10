#include "../Sources/NativeHeapMetrics/include/NativeHeapMetrics.h"
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

_Static_assert(ATOMIC_LONG_LOCK_FREE == 2 && ATOMIC_LLONG_LOCK_FREE == 2
               && ATOMIC_BOOL_LOCK_FREE == 2, "Allocation hooks require always-lock-free atomics");
_Static_assert(!__has_feature(ptrauth_calls), "This fixture requires the non-arm64e Darwin ABI");

// The child process owns these counters. Hooks allocate no storage and preserve allocator ownership.
static _Atomic uint64_t calls_malloc, calls_calloc, calls_realloc, calls_free, bytes_requested;
static _Atomic uint64_t overflowed, active;
static _Atomic bool enabled;
static _Atomic uint64_t calls_memcpy, calls_memmove, calls_bcopy, bytes_copied;

static bool enter(void);
static void leave(void);

// API entries include nested original calls; no pointer is retained or inspected.
static bool enter_copy(void) { bool count = enter(); return count; }
static void leave_copy(void) { leave(); }


static void add(_Atomic uint64_t *counter, uint64_t value) {
    uint64_t previous = atomic_fetch_add_explicit(counter, value, memory_order_relaxed);
    if (previous > UINT64_MAX - value) atomic_store_explicit(&overflowed, 1, memory_order_relaxed);
}

static bool enter(void) {
    atomic_fetch_add_explicit(&active, 1, memory_order_seq_cst);
    return atomic_load_explicit(&enabled, memory_order_seq_cst);
}

static void leave(void) {
    atomic_fetch_sub_explicit(&active, 1, memory_order_seq_cst);
}

static void *counted_malloc(size_t size) {
    bool count = enter();
    void *result = malloc(size);
    if (count) { add(&calls_malloc, 1); add(&bytes_requested, size); }
    leave();
    return result;
}

static void *counted_calloc(size_t count, size_t size) {
    bool record = enter();
    void *result = calloc(count, size);
    if (record) {
        add(&calls_calloc, 1);
        if (size != 0 && count > UINT64_MAX / size) atomic_store_explicit(&overflowed, 1, memory_order_relaxed);
        else add(&bytes_requested, count * size);
    }
    leave();
    return result;
}

static void *counted_realloc(void *pointer, size_t size) {
    bool count = enter();
    void *result = realloc(pointer, size);
    if (count) { add(&calls_realloc, 1); add(&bytes_requested, size); }
    leave();
    return result;
}

static void counted_free(void *pointer) {
    bool count = enter();
    free(pointer);
    if (count) add(&calls_free, 1);
    leave();
}

static void *counted_memcpy(void *dst, const void *src, size_t size) {
    bool count = enter_copy(); void *result = memcpy(dst, src, size);
    if (count) { add(&calls_memcpy, 1); add(&bytes_copied, size); }
    leave_copy(); return result;
}
static void *counted_memmove(void *dst, const void *src, size_t size) {
    bool count = enter_copy(); void *result = memmove(dst, src, size);
    if (count) { add(&calls_memmove, 1); add(&bytes_copied, size); }
    leave_copy(); return result;
}
static void counted_bcopy(const void *src, void *dst, size_t size) {
    bool count = enter_copy(); bcopy(src, dst, size);
    if (count) { add(&calls_bcopy, 1); add(&bytes_copied, size); }
    leave_copy();
}
// Darwin dyld keeps references from the interposer image directed at original symbols.
#define INTERPOSE(replacement, original) \
    __attribute__((used, section("__DATA,__interpose,interposing"))) \
    static const struct { const void *replacement; const void *original; } pair_##original = \
        { (const void *)(uintptr_t)&replacement, (const void *)(uintptr_t)&original }

INTERPOSE(counted_malloc, malloc);
INTERPOSE(counted_calloc, calloc);
INTERPOSE(counted_realloc, realloc);
INTERPOSE(counted_free, free);
INTERPOSE(counted_memcpy, memcpy);
INTERPOSE(counted_memmove, memmove);
INTERPOSE(counted_bcopy, bcopy);

__attribute__((visibility("default")))
int mos_allocation_capture(MOSAllocationSnapshot *result, int resume) {
    if (result == NULL) return 1;
    atomic_store_explicit(&enabled, false, memory_order_seq_cst);
    bool drained = false;
    for (unsigned index = 0; index < 1000000; ++index) {
        if (atomic_load_explicit(&active, memory_order_seq_cst) == 0) { drained = true; break; }
    }
    if (!drained) { *result = (MOSAllocationSnapshot){ .status = 2 }; return 2; }
    *result = (MOSAllocationSnapshot){
        atomic_load_explicit(&calls_malloc, memory_order_relaxed),
        atomic_load_explicit(&calls_calloc, memory_order_relaxed),
        atomic_load_explicit(&calls_realloc, memory_order_relaxed),
        atomic_load_explicit(&calls_free, memory_order_relaxed),
        atomic_load_explicit(&bytes_requested, memory_order_relaxed),
        atomic_load_explicit(&calls_memcpy, memory_order_relaxed),
        atomic_load_explicit(&calls_memmove, memory_order_relaxed),
        atomic_load_explicit(&calls_bcopy, memory_order_relaxed),
        atomic_load_explicit(&bytes_copied, memory_order_relaxed),
        atomic_load_explicit(&overflowed, memory_order_relaxed), 0
    };
    if (result->overflow) { result->status = 3; return 3; }
    atomic_store_explicit(&enabled, resume != 0, memory_order_seq_cst);
    return 0;
}
