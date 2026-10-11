#include "CoreSpiceBSIM45.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
 for(int role=0;role<=1;role++)for(size_t n=0;n<cs_bsim45_parameter_count(role);n++) {
  CSBSIM45ParameterInfo p;
  assert(cs_bsim45_parameter_at(role,n,&p)==CS_BSIM45_OK);
  printf("%d %s %d %d\n",role,p.name,p.selector,p.kind);
 }
 return 0;
}
