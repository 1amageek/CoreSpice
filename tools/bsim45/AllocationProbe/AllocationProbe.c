#include "AllocationProbe.h"
#include <malloc/malloc.h>
#include <stdlib.h>
/* Darwin interposition measures allocation-entry calls, not unique allocation
   events: libc may invoke another tracked entry. Zero calls remains exact.
   This fixture has one bounded synchronous thread; TLS never crosses an await. */
static _Thread_local int active;
static _Thread_local size_t expectedOwnerBytes;
static _Thread_local CSAllocationCounts counts;
static volatile uint8_t consumed;
void cs_probe_begin(size_t ownerBytes) { counts=(CSAllocationCounts){0};expectedOwnerBytes=ownerBytes;active=1; }
CSAllocationCounts cs_probe_end(void) { active=0;return counts; }
void cs_probe_consume(const uint8_t *bytes,size_t count) { if(count)consumed=bytes[0]; }
static void note(void) { if(active)counts.allocationEntryCalls++; }
static void *tracked_malloc(size_t n){note();return malloc(n);}
static void *tracked_calloc(size_t n,size_t s){note();if(active&&n==1&&s==expectedOwnerBytes)counts.exactOwnerCallocs++;return calloc(n,s);}
static void *tracked_realloc(void *p,size_t n){note();return realloc(p,n);}
static void *tracked_aligned_alloc(size_t a,size_t n){note();return aligned_alloc(a,n);}
static int tracked_posix_memalign(void **p,size_t a,size_t n){note();return posix_memalign(p,a,n);}
static void *tracked_zone_malloc(malloc_zone_t *z,size_t n){note();return malloc_zone_malloc(z,n);}
static void *tracked_zone_calloc(malloc_zone_t *z,size_t n,size_t s){note();return malloc_zone_calloc(z,n,s);}
static void *tracked_zone_realloc(malloc_zone_t *z,void *p,size_t n){note();return malloc_zone_realloc(z,p,n);}
static void *tracked_zone_memalign(malloc_zone_t *z,size_t a,size_t n){note();return malloc_zone_memalign(z,a,n);}
/* dyld excludes calls from the replacement's image, so original libc calls
   retain their semantics without recursive dlsym allocation or mutable hooks. */
#define INTERPOSE(replacement,original) \
 __attribute__((used)) static const struct { const void *replacement; const void *original; } \
 interpose_##original __attribute__((section("__DATA,__interpose"))) = {(const void *)&replacement,(const void *)&original}
INTERPOSE(tracked_malloc,malloc);INTERPOSE(tracked_calloc,calloc);INTERPOSE(tracked_realloc,realloc);
INTERPOSE(tracked_aligned_alloc,aligned_alloc);INTERPOSE(tracked_posix_memalign,posix_memalign);
INTERPOSE(tracked_zone_malloc,malloc_zone_malloc);INTERPOSE(tracked_zone_calloc,malloc_zone_calloc);
INTERPOSE(tracked_zone_realloc,malloc_zone_realloc);INTERPOSE(tracked_zone_memalign,malloc_zone_memalign);
