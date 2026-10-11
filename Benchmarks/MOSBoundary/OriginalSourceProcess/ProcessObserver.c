#include "../Sources/NativeHeapMetrics/include/NativeHeapMetrics.h"
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Constructor/destructor own these fields; worker hooks use only interposer atomics.
static int report_fd = -1;
static int admission_status = 1;
static MOSAllocationSnapshot baseline;

__attribute__((constructor)) static void begin_process_measurement(void) {
    const char *path = getenv("MOS_PROCESS_METRICS_PATH");
    if (path == NULL) return;
    report_fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (report_fd < 0) return;
    admission_status = mos_native_allocation_initialize();
    if (admission_status != 0) return;
    admission_status = mos_native_allocation_calibrate();
    if (admission_status != 0) return;
    baseline = mos_native_allocation_capture(1);
    admission_status = baseline.status;
}

__attribute__((destructor)) static void finish_process_measurement(void) {
    if (report_fd < 0) return;
    MOSAllocationSnapshot final = mos_native_allocation_capture(0);
    MOSNativeHeapSnapshot heap = mos_native_heap_snapshot();
    int status = admission_status != 0 ? admission_status : final.status;
    if (status == 0 && heap.rusage_status != 0) status = 7;
    int written = dprintf(report_fd,
        "{\"status\":%d,\"calibrationPassed\":%s,\"mallocCalls\":%" PRIu64
        ",\"callocCalls\":%" PRIu64 ",\"reallocCalls\":%" PRIu64 ",\"freeCalls\":%" PRIu64
        ",\"requestedBytes\":%" PRIu64 ",\"copyCalls\":%" PRIu64 ",\"copiedBytes\":%" PRIu64
        ",\"heapLiveBytesAtExit\":%" PRIu64 ",\"zoneAllocatedBytesAtExit\":%" PRIu64
        ",\"processPeakResidentBytes\":%" PRIu64 "}\n",
        status, admission_status == 0 ? "true" : "false",
        final.malloc_calls - baseline.malloc_calls, final.calloc_calls - baseline.calloc_calls,
        final.realloc_calls - baseline.realloc_calls, final.free_calls - baseline.free_calls,
        final.requested_bytes - baseline.requested_bytes,
        (final.memcpy_calls - baseline.memcpy_calls) + (final.memmove_calls - baseline.memmove_calls)
            + (final.bcopy_calls - baseline.bcopy_calls),
        final.copied_bytes - baseline.copied_bytes, heap.bytes_in_use,
        heap.zone_bytes_allocated, heap.process_peak_resident_bytes);
    // A truncated/missing report is rejected by the runner; never report partial evidence.
    if (written < 0 || fsync(report_fd) != 0) (void)ftruncate(report_fd, 0);
    (void)close(report_fd);
    report_fd = -1;
}
