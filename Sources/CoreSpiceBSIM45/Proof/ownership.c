#include <assert.h>
#include <stdlib.h>
static size_t allocations, releases, allocatedBytes;
static int rejectAllocation;
static void *tracked_calloc(size_t count,size_t size) {
 if(rejectAllocation)return NULL;
 void *p=calloc(count,size);
 if(p){allocations++;allocatedBytes+=count*size;}return p;
}
static void tracked_free(void *p){if(p)releases++;free(p);}
#define calloc tracked_calloc
#define free tracked_free
#include "../Kernel/PreparationOwner.c"
#undef calloc
#undef free
#define main preparation_cases
#include "preparation.c"
#undef main
int main(void) {
 CSBSIM45Conditions c=conditions();CSBSIM45Owner *h=(void *)1;
 rejectAllocation=1;
 assert(cs_bsim45_create("4.5.0",2,1,&c,&h)==CS_BSIM45_MEMORY&&h==NULL);
 assert(allocations==0&&releases==0);rejectAllocation=0;
 h=make(c,1);double values[]={0.2,0.3,0.4};
 assert(cs_bsim45_set_initial_conditions(h,values,3)==CS_BSIM45_OK);
 values[0]=NAN;values[1]=INFINITY;
 assert(h->instance.BSIM4icVDS==0.2&&h->instance.BSIM4icVGS==0.3&&h->instance.BSIM4icVBS==0.4);
 assert(h->instance.BSIM4icVDSGiven&&h->instance.BSIM4icVGSGiven&&h->instance.BSIM4icVBSGiven);
 assert(h->model.BSIM4versionGiven&&h->model.BSIM4typeGiven);
 cs_bsim45_destroy(h);
 preparation_cases();
 assert(allocations==releases&&allocatedBytes==allocations*cs_bsim45_owner_size());
 printf("owner_allocations=%zu owner_releases=%zu bytes_per_owner=%zu\n",allocations,releases,cs_bsim45_owner_size());
 return 0;
}
