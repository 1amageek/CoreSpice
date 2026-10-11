#include "CoreSpiceBSIM45.h"
#include "CoreSpiceBSIM4.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
 CSBSIM45Conditions c={cs_bsim45_owner_size(),10,128,300.15,300.15,0};
 CSBSIM45Owner *early=NULL;
 assert(cs_bsim45_create("4.5.0",2,1,&c,&early)==CS_BSIM45_OK);
 assert(cs_bsim45_prepare(early)==CS_BSIM45_OK);
 CSBSIM4Handle *later=NULL;
 assert(cs_bsim4_create(1,"4.8.3",300.15,0,&later)==CS_BSIM4_OK);
 assert(cs_bsim4_set_stress_budget(later,10)==CS_BSIM4_OK);
 CSBSIM4Topology topology;
 assert(cs_bsim4_prepare(later,&topology)==CS_BSIM4_OK);
 cs_bsim4_destroy(later);
 CSBSIM45PreparedInfo receipt;
 assert(cs_bsim45_prepared_info(early,&receipt)==CS_BSIM45_OK);
 assert(receipt.ud==1e14&&receipt.nodeCount==4);
 cs_bsim45_destroy(early);
 puts("Independent 4.5.0 / 4.8.3 owners linked and prepared");return 0;
}
