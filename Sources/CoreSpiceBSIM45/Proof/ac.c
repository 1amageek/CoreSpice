/* Independent full physical matrix identities and exclusive-owner invariants.
   Expected NQS is composed from the qualified static Jacobians plus a channel
   transfer function; it never calls or reproduces the original AC stamp. */
#include <assert.h>
#include <stdlib.h>
#include <float.h>
#include <stdio.h>
static size_t allocations,releases,cells,qsCases,nqsCases,failures,oracleCases,setups,temperatures;
#ifdef COEFFICIENT_REFERENCE
extern int cs_bsim45_oracle_acLoad(void *,void *);
#endif
static void *tracked_calloc(size_t n,size_t size){void *p=calloc(n,size);if(p)allocations++;return p;}
static void tracked_free(void *p){if(p)releases++;free(p);}
#include "../Kernel/bsim4def.h"
#include "../Kernel/bsim4ext.h"
static int counted_setup(SMPmatrix *m,GENmodel *g,CKTcircuit *c,int *n){setups++;return cs_bsim45_setup(m,g,c,n);}
static int counted_temperature(GENmodel *g,CKTcircuit *c){temperatures++;return cs_bsim45_temp(g,c);}
#undef BSIM4setup
#undef BSIM4temp
#define BSIM4setup counted_setup
#define BSIM4temp counted_temperature
#define calloc tracked_calloc
#define free tracked_free
#include "../Kernel/PreparationOwner.c"
#undef calloc
#undef free
static CSBSIM45Owner *owner;
static void set(int role,int id,int kind,double value){assert((role?cs_bsim45_set_model(owner,id,kind,value):cs_bsim45_set_instance(owner,id,kind,value))==CS_BSIM45_OK);}
#include "static_fixture.h"
static void close_value(double actual,double expected,int id,int point,int frequency,int cell,const char *law) {
 cells++;
 if(!isfinite(actual)||!isfinite(expected)||fabs(actual-expected)>1e-12+2e-6*fmax(fabs(actual),fabs(expected))) {
  if(failures++<24)fprintf(stderr,"%s id=%d point=%d frequency=%d cell=%d actual=%.17g expected=%.17g\n",law,id,point,frequency,cell,actual,expected);
 }
}
static void conserve(const double *a,int id,int point,int frequency) {
 for(int r=0;r<13;r++) {
  long double row=0,col=0,scaleRow=0,scaleCol=0;
  for(int n=0;n<13;n++){row+=a[r*13+n];col+=a[n*13+r];scaleRow+=fabs(a[r*13+n]);scaleCol+=fabs(a[n*13+r]);}
  if(fabsl(row)>1e-12+2e-12*scaleRow||fabsl(col)>1e-12+2e-12*scaleCol){
   if(failures++<24)fprintf(stderr,"conservation id=%d point=%d frequency=%d row=%d KCL=%Lg gauge=%Lg\n",id,point,frequency,r,row,col);
  }
 }
}
static CSBSIM45ACResult expected_nqs(CSBSIM45StaticResult s,double omega) {
 BSIM4instance *i=&owner->instance;int nodes[]={i->BSIM4gNodePrime,i->BSIM4dNodePrime,i->BSIM4sNodePrime,i->BSIM4bNodePrime};
 if(i->BSIM4mode<0){int n=nodes[1];nodes[1]=nodes[2];nodes[2]=n;}
 /* Long-double complex division is independent of production double factors. */
 long double x=(long double)omega*i->BSIM4taunet,den=1+x*x;
 long double hr=1/den,hi=-x/den;
 double g[]={i->BSIM4gm,i->BSIM4gds,-(i->BSIM4gm+i->BSIM4gds+i->BSIM4gmbs),i->BSIM4gmbs};
 double cd[]={i->BSIM4cdgb,i->BSIM4cddb,i->BSIM4cdsb,i->BSIM4cdbb};
 double cs[]={i->BSIM4csgb,i->BSIM4csdb,i->BSIM4cssb,i->BSIM4csbb};
 CSBSIM45ACResult result;
 for(int n=0;n<169;n++){result.real[n]=s.conductance[n];result.imaginary[n]=omega*s.capacitance[n];}
 for(int c=0;c<4;c++)for(int r=0;r<4;r++) {
  double channelG=r==1?g[c]:r==2?-g[c]:0;
  double channelC=r==1?cd[c]:r==2?cs[c]:r==0?-(cd[c]+cs[c]):0;
  int n=nodes[r]*13+nodes[c];
  result.real[n]+=(double)(channelG*(hr-1)-omega*channelC*hi);
  result.imaginary[n]+=(double)(channelG*hi+omega*channelC*(hr-1));
 }
 return result;
}
int main(int argc,char **argv) {
 /* Extreme transfer values are checked separately from near-zero matrix
    entries where subtracting a static intrinsic capacitance loses precision. */
 const double taus[]={0,DBL_MIN,1e-12,1,1e100,DBL_MAX};
 const double omegas[]={0,DBL_MIN,1,1e12,1e200,DBL_MAX};
 for(int t=0;t<6;t++)for(int f=0;f<6;f++) {
  double hr,lag,scale;cs_bsim45_relaxation(omegas[f],taus[t],&hr,&lag,&scale);
  assert(isfinite(hr)&&isfinite(lag)&&isfinite(scale));
  printf("RELAX %.17g %.17g %.17g %.17g %.17g\n",omegas[f],taus[t],hr,lag,scale);
 }
 int end=argc>1?atoi(argv[1]):STATIC_FIXTURES;int memoryCheck=argc>2&&!strcmp(argv[2],"--memory-check");
 const double frequencies[]={0,1,1e3,1e9,1e12,1e16,1e100,DBL_MAX/16};
 for(int id=0;id<end;id++) {
  StaticFixture f=fixture(id);CSBSIM45Conditions c={cs_bsim45_owner_size(),100,128,f.ambient,300.15,0};
  assert(cs_bsim45_create("4.5.0",2,f.polarity,&c,&owner)==CS_BSIM45_OK);fixture_parameters(f);
  double bias[13]={0};CSBSIM45ACResult out,prior;memset(&out,0x5a,sizeof(out));prior=out;
  assert(cs_bsim45_evaluate_ac(owner,bias,13,0,1,&out)==CS_BSIM45_STATE);assert(!memcmp(&out,&prior,sizeof(out)));
  assert(cs_bsim45_prepare(owner)==CS_BSIM45_OK);CSBSIM45PreparedInfo p;assert(cs_bsim45_prepared_info(owner,&p)==CS_BSIM45_OK);
  for(int history=1;history<3;history++)for(int n=0;n<29;n++)owner->states[history][n]=(history*29+n)*0.123;
  double histories[2][29];memcpy(histories,owner->states[1],sizeof(histories));
  size_t allocated=allocations;uint32_t work=owner->stressIterations;
  for(int point=0;point<STATIC_BIASES;point++) {
   fixture_bias(p,f.polarity,point,bias);CSBSIM45StaticResult s;
   assert(cs_bsim45_evaluate_static(owner,bias,13,1e-12,&s)==CS_BSIM45_OK);
   int nqs=owner->instance.BSIM4acnqsMod;
   for(int freq=0;freq<8;freq++) {
    if(memoryCheck&&freq!=0&&freq!=3&&freq!=7)continue;
    double omega=frequencies[freq];owner->instance.BSIM4acnqsMod=0;
    assert(cs_bsim45_evaluate_ac(owner,bias,13,1e-12,omega,&out)==CS_BSIM45_OK);qsCases++;
    for(int n=0;n<169;n++){close_value(out.real[n],s.conductance[n],id,point,freq,n,"QS real");close_value(out.imaginary[n],omega*s.capacitance[n],id,point,freq,n,"QS imag");}
    conserve(out.real,id,point,freq);conserve(out.imaginary,id,point,freq);
    owner->instance.BSIM4acnqsMod=nqs;
    if(nqs) {
     assert(cs_bsim45_evaluate_ac(owner,bias,13,1e-12,omega,&out)==CS_BSIM45_OK);nqsCases++;
     if(freq<6) { CSBSIM45ACResult expected=expected_nqs(s,omega);
     for(int n=0;n<169;n++){close_value(out.real[n],expected.real[n],id,point,freq,n,"NQS real");close_value(out.imaginary[n],expected.imaginary[n],id,point,freq,n,"NQS imag");} }
     conserve(out.real,id,point,freq);conserve(out.imaginary,id,point,freq);
    }
#ifdef COEFFICIENT_REFERENCE
    if(freq<6) {
     memset(&owner->matrix,0,sizeof(owner->matrix));
     assert(cs_bsim45_oracle_acLoad(&owner->model,&owner->circuit)==0);oracleCases++;
     for(int r=0;r<13;r++)for(int col=0;col<13;col++)if(!p.chargeNode||(r!=p.chargeNode&&col!=p.chargeNode)) {
      close_value(out.real[r*13+col],owner->matrix.values[r][col][0],id,point,freq,r*13+col,"original coefficient-isolated real");
      close_value(out.imaginary[r*13+col],owner->matrix.values[r][col][1],id,point,freq,r*13+col,"original coefficient-isolated imag");
     }
    }
#endif
    prior=out;double other[13];fixture_bias(p,f.polarity,(point+1)%7,other);
    if(!memoryCheck||freq==0) {
    assert(cs_bsim45_evaluate_ac(owner,other,13,1e-12,1e6,&out)==CS_BSIM45_OK);
    assert(cs_bsim45_evaluate_ac(owner,bias,13,1e-12,omega,&out)==CS_BSIM45_OK);assert(!memcmp(&out,&prior,sizeof(out))); }
    assert(!memcmp(histories,owner->states[1],sizeof(histories)));
    assert(allocated==allocations&&work==owner->stressIterations&&owner->circuit.sizeAllocated==1&&setups==(size_t)(id+1)&&temperatures==(size_t)(id+1));
   }
  }
  /* Invalid requests are atomic for every owned byte as well as caller output. */
  CSBSIM45Owner saved=*owner;prior=out;
  assert(cs_bsim45_evaluate_ac(owner,bias,13,0,-1,&out)==CS_BSIM45_PARAMETER);
  assert(cs_bsim45_evaluate_ac(owner,bias,13,0,INFINITY,&out)==CS_BSIM45_PARAMETER);
  assert(cs_bsim45_evaluate_ac(owner,bias,13,0,NAN,&out)==CS_BSIM45_PARAMETER);
  assert(cs_bsim45_evaluate_ac(owner,bias,12,0,1,&out)==CS_BSIM45_PARAMETER);
  assert(cs_bsim45_evaluate_ac(owner,bias,13,-1,1,&out)==CS_BSIM45_PARAMETER);
  assert(cs_bsim45_evaluate_ac(owner,NULL,13,0,1,&out)==CS_BSIM45_PARAMETER);
  assert(cs_bsim45_evaluate_ac(owner,bias,13,0,1,NULL)==CS_BSIM45_PARAMETER);
  assert(cs_bsim45_evaluate_ac(NULL,bias,13,0,1,&out)==CS_BSIM45_PARAMETER);
  double priorBias=bias[1];bias[1]=INFINITY;
  assert(cs_bsim45_evaluate_ac(owner,bias,13,0,1,&out)==CS_BSIM45_PARAMETER);
  bias[1]=NAN;assert(cs_bsim45_evaluate_ac(owner,bias,13,0,1,&out)==CS_BSIM45_PARAMETER);bias[1]=priorBias;
  int invalid=p.chargeNode?p.chargeNode:(p.nodeCount<12?p.nodeCount+1:0);bias[invalid]=1;
  assert(cs_bsim45_evaluate_ac(owner,bias,13,0,1,&out)==CS_BSIM45_PARAMETER);bias[invalid]=0;
  assert(!memcmp(owner,&saved,sizeof(saved))&&!memcmp(&out,&prior,sizeof(out)));
  /* Force a finite final-result overflow after a valid static operating point. */
  owner->geometry.BSIM4cgbo=DBL_MAX;
  CSBSIM45StaticResult finiteStatic;
  assert(cs_bsim45_evaluate_static(owner,bias,13,0,&finiteStatic)==CS_BSIM45_OK);
  assert(cs_bsim45_evaluate_ac(owner,bias,13,0,DBL_MAX,&out)==CS_BSIM45_NONFINITE);
  assert(!memcmp(&out,&prior,sizeof(out))&&!memcmp(histories,owner->states[1],sizeof(histories))&&owner->state==-1);
  assert(cs_bsim45_evaluate_ac(owner,bias,13,0,1,&out)==CS_BSIM45_STATE);cs_bsim45_destroy(owner);
 }
 assert(allocations==(size_t)end&&allocations==releases&&setups==(size_t)end&&temperatures==(size_t)end);
 printf("fixtures=%d QS=%zu NQS=%zu cells=%zu failures=%zu allocations=%zu releases=%zu evaluation_allocations=0 repeated_setup=0 histories_unchanged=1 atomic_failures=%d coefficient_oracles=%zu setup_calls=%zu temperature_calls=%zu\n",end,qsCases,nqsCases,cells,failures,allocations,releases,end,oracleCases,setups,temperatures);
 return failures?1:0;
}
