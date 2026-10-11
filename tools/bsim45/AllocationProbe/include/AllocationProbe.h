#ifndef CS_BSIM45_ALLOCATION_PROBE_H
#define CS_BSIM45_ALLOCATION_PROBE_H
#include <stddef.h>
#include <stdint.h>
typedef struct { uint64_t allocationEntryCalls, exactOwnerCallocs; } CSAllocationCounts;
/* Native test instrumentation, confined to the synchronous calling thread. */
void cs_probe_begin(size_t ownerBytes);
CSAllocationCounts cs_probe_end(void);
void cs_probe_consume(const uint8_t *bytes, size_t count);
#endif
