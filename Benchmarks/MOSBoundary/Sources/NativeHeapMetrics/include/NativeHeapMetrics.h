#include <stdint.h>

typedef struct {
    uint64_t blocks_in_use;
    uint64_t bytes_in_use;
    uint64_t max_bytes_in_use;
    uint64_t zone_bytes_allocated;
    uint64_t process_peak_resident_bytes;
    int rusage_status;
} MOSNativeHeapSnapshot;

MOSNativeHeapSnapshot mos_native_heap_snapshot(void);

typedef struct {
    uint64_t malloc_calls;
    uint64_t calloc_calls;
    uint64_t realloc_calls;
    uint64_t free_calls;
    uint64_t requested_bytes;
    uint64_t memcpy_calls;
    uint64_t memmove_calls;
    uint64_t bcopy_calls;
    uint64_t copied_bytes;
    uint64_t overflow;
    int status;
} MOSAllocationSnapshot;

int mos_native_allocation_initialize(void);
int mos_native_allocation_calibrate(void);
MOSAllocationSnapshot mos_native_allocation_capture(int resume);
