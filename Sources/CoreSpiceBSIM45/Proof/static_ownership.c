/* White-box lifetime assertions supplement public-ABI physics tests. */
#include <assert.h>
#include <stdlib.h>
#include <float.h>
static size_t allocations,releases;
static void *tracked_calloc(size_t n,size_t size){void *p=calloc(n,size);if(p)allocations++;return p;}
static void tracked_free(void *p){if(p)releases++;free(p);}
#define calloc tracked_calloc
#define free tracked_free
#include "../Kernel/PreparationOwner.c"
#undef calloc
#undef free
static CSBSIM45Owner *owner;
static void set(int role,int id,int kind,double value){assert((role?cs_bsim45_set_model(owner,id,kind,value):cs_bsim45_set_instance(owner,id,kind,value))==CS_BSIM45_OK);}
#include "static_fixture.h"
int main(void) {
 for(int id=0;id<STATIC_FIXTURES;id++) {
  StaticFixture f=fixture(id);CSBSIM45Conditions c={cs_bsim45_owner_size(),100,128,f.ambient,300.15,0};
  assert(cs_bsim45_create("4.5.0",2,f.polarity,&c,&owner)==CS_BSIM45_OK);fixture_parameters(f);
  double bias[13]={0};CSBSIM45StaticResult out,prior;memset(&out,0x5a,sizeof(out));prior=out;
  assert(cs_bsim45_evaluate_static(owner,bias,13,0,&out)==CS_BSIM45_STATE);
  assert(!memcmp(&out,&prior,sizeof(out)));assert(cs_bsim45_prepare(owner)==CS_BSIM45_OK);
  CSBSIM45PreparedInfo p;assert(cs_bsim45_prepared_info(owner,&p)==CS_BSIM45_OK);fixture_bias(p,f.polarity,0,bias);
  CSBSIM45StaticResult initial;assert(cs_bsim45_evaluate_static(owner,bias,13,1e-12,&initial)==CS_BSIM45_OK);
  for(int history=1;history<3;history++)for(int n=0;n<29;n++)owner->states[history][n]=(history*29+n)*0.1;
  double histories[2][29];memcpy(histories,owner->states[1],sizeof(histories));
  assert(cs_bsim45_evaluate_static(owner,bias,13,1e-12,&out)==CS_BSIM45_OK&&!memcmp(&out,&initial,sizeof(out)));
  double g=123,eq=456;int priorMode=owner->circuit.CKTmode;owner->circuit.CKTmode=MODETRAN;
  assert(NIintegrate(&owner->circuit,&g,&eq,0,0)==E_BADPARM&&g==123&&eq==456);owner->circuit.CKTmode=priorMode;
  assert(NIintegrate(&owner->circuit,&g,&eq,0,INT_MAX)==E_BADPARM);
  size_t allocated=allocations;uint32_t work=owner->stressIterations;
  for(int point=0;point<STATIC_BIASES;point++) {
   fixture_bias(p,f.polarity,point,bias);assert(cs_bsim45_evaluate_static(owner,bias,13,1e-12,&out)==CS_BSIM45_OK);
   assert(!memcmp(histories,owner->states[1],sizeof(histories)));
   assert(allocated==allocations&&work==owner->stressIterations&&owner->circuit.sizeAllocated==1);
  }
  prior=out;
  int unused=p.chargeNode?p.chargeNode:(p.nodeCount<12?p.nodeCount+1:0);
  bias[unused]=1;assert(cs_bsim45_evaluate_static(owner,bias,13,0,&out)==CS_BSIM45_PARAMETER);
  assert(!memcmp(&out,&prior,sizeof(out)));fixture_bias(p,f.polarity,0,bias);
  bias[1]=INFINITY;assert(cs_bsim45_evaluate_static(owner,bias,13,0,&out)==CS_BSIM45_PARAMETER);
  assert(!memcmp(&out,&prior,sizeof(out)));fixture_bias(p,f.polarity,0,bias);
  assert(cs_bsim45_evaluate_static(owner,bias,13,0,&out)==CS_BSIM45_OK);
  prior=out;for(int n=1;n<=p.nodeCount;n++)if(n!=p.chargeNode)bias[n]=n%2?DBL_MAX:-DBL_MAX;
  assert(cs_bsim45_evaluate_static(owner,bias,13,0,&out)==CS_BSIM45_NONFINITE);
  assert(!memcmp(&out,&prior,sizeof(out))&&owner->state==-1);
  assert(!memcmp(histories,owner->states[1],sizeof(histories)));
  memset(bias,0,sizeof(bias));assert(cs_bsim45_evaluate_static(owner,bias,13,0,&out)==CS_BSIM45_STATE);
  assert(!memcmp(&out,&prior,sizeof(out)));cs_bsim45_destroy(owner);
 }
 assert(allocations==STATIC_FIXTURES&&allocations==releases);
 printf("static_owner_allocations=%zu releases=%zu evaluation_allocations=0 repeated_setup=0 histories_unchanged=1 atomic_failures=%d\n",allocations,releases,STATIC_FIXTURES);
}
