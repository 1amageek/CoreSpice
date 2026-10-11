/* Behavioral proof through the public C ABI. White-box access measures owned
   storage and qualified coefficients, not a substitute implementation path. */
#include <assert.h>
#include <float.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "bsim4def.h"
#include "bsim4ext.h"
static size_t allocations,releases,setups,temperatures,identities,oracles,integrals;
static void *counted_calloc(size_t n,size_t size){void *p=calloc(n,size);if(p)allocations++;return p;}
static void counted_free(void *p){if(p)releases++;free(p);}
static int counted_setup(SMPmatrix *m,GENmodel *g,CKTcircuit *c,int *s){setups++;return cs_bsim45_setup(m,g,c,s);}
static int counted_temp(GENmodel *m,CKTcircuit *c){temperatures++;return cs_bsim45_temp(m,c);}
#undef BSIM4setup
#undef BSIM4temp
#define BSIM4setup counted_setup
#define BSIM4temp counted_temp
#define calloc counted_calloc
#define free counted_free
#include "../Kernel/PreparationOwner.c"
#undef calloc
#undef free
static CSBSIM45Owner *owner;
static void set(int role,int id,int kind,double value){assert((role?cs_bsim45_set_model(owner,id,kind,value):cs_bsim45_set_instance(owner,id,kind,value))==CS_BSIM45_OK);}
#include "noise_fixture.h"
#include "../Kernel/noise_primitives.inc"
#ifdef COEFFICIENT_REFERENCE
extern void cs_noise_oracle_layout(size_t[5]);
extern int cs_noise_oracle(const void *,const void *,double,const double *,const double *,const double *,double,double *);
#endif
static void equal(double actual,double expected,double absolute,double relative,const char *name,int id,int source) {
 if(!isfinite(actual)||!isfinite(expected)||fabs(actual-expected)>absolute+relative*fmax(fabs(actual),fabs(expected))){fprintf(stderr,"%s fixture=%d source=%d actual=%.17g expected=%.17g\n",name,id,source,actual,expected);abort();}identities++;
}
static CSBSIM45NoiseSpectrum spectrum(double bias[13],double frequency,double real[13],double imaginary[13]) {
 CSBSIM45NoiseSpectrum out;CSBSIM45Status status=cs_bsim45_noise_spectrum(owner,bias,13,1e-12,frequency,real,imaginary,&out);
 if(status!=CS_BSIM45_OK){fprintf(stderr,"PSD rejected status=%d\n",status);abort();}return out;
}
static double gain(double real[13],double imaginary[13],int a,int b){double re=real[a]-real[b],im=imaginary[a]-imaginary[b];return re*re+im*im;}
/* The flicker law is written as the trap-density integral plus CLM correction,
   with factored carrier differences, independently of Eval1ovFNoise. */
static double flicker_power(double frequency) {
 BSIM4model *m=&owner->model;BSIM4instance *i=&owner->instance;struct bsim4SizeDependParam *p=i->pParam;
 if(m->BSIM4fnoiMod==0)return m->BSIM4kf*pow(fmax(fabs(i->BSIM4cd),1e-38),m->BSIM4af)/(pow(frequency,m->BSIM4ef)*p->BSIM4leff*p->BSIM4leff*m->BSIM4coxe);
 double q=1.6021918e-19,k=1.3806226e-23,t=owner->circuit.CKTtemp;
 double n0=m->BSIM4coxe*i->BSIM4Vgsteff/q,nl=n0*(1-i->BSIM4AbovVgst2Vtm*i->BSIM4Vdseff),length=p->BSIM4leff-2*m->BSIM4lintnoi;
 double traps=m->BSIM4oxideTrapDensityA*log1p((n0-nl)/(nl+i->BSIM4nstar))+(n0-nl)*(m->BSIM4oxideTrapDensityB+m->BSIM4oxideTrapDensityC*(n0+nl)/2);
 double clm=0;if(m->BSIM4em>0)clm=fmax(0,p->BSIM4litl*log(fmax(1e-38,((fabs(owner->states[0][3])-i->BSIM4Vdseff)/p->BSIM4litl+m->BSIM4em)/(2*i->BSIM4vsattemp/i->BSIM4ueff))));
 double cd=fabs(i->BSIM4cd),scale=1e10*pow(frequency,m->BSIM4ef);
 double strong=q*q*k*t*cd*i->BSIM4ueff*traps/(scale*i->BSIM4Abulk*m->BSIM4coxe*length*length);
 strong+=k*t*cd*cd*clm*(m->BSIM4oxideTrapDensityA+nl*(m->BSIM4oxideTrapDensityB+nl*m->BSIM4oxideTrapDensityC))/(scale*length*length*p->BSIM4weff*i->BSIM4nf*(nl+i->BSIM4nstar)*(nl+i->BSIM4nstar));
 double weak=m->BSIM4oxideTrapDensityA*k*t*cd*cd/(scale*p->BSIM4weff*i->BSIM4nf*p->BSIM4leff*i->BSIM4nstar*i->BSIM4nstar);
 return strong+weak>0?1/(1/strong+1/weak):0;
}
static void source_identities(CSBSIM45NoiseSpectrum actual,double real[13],double imaginary[13],int id) {
 BSIM4model *m=&owner->model;BSIM4instance *i=&owner->instance;struct bsim4SizeDependParam *p=i->pParam;
 double g[9]={m->BSIM4rdsMod?i->BSIM4gdtot:i->BSIM4drainConductance,m->BSIM4rdsMod?i->BSIM4gstot:i->BSIM4sourceConductance,
 i->BSIM4rgateMod?i->BSIM4grgeltd:0,i->BSIM4grbps,i->BSIM4grbpd,i->BSIM4grbpb,i->BSIM4grbsb,i->BSIM4grbdb,0};
 int pairs[13][2]={{i->BSIM4dNodePrime,1},{i->BSIM4sNodePrime,3},{i->BSIM4rgateMod==3?i->BSIM4gNodeMid:i->BSIM4gNodePrime,2},
 {i->BSIM4bNodePrime,i->BSIM4sbNode},{i->BSIM4bNodePrime,i->BSIM4dbNode},{i->BSIM4bNodePrime,4},{4,i->BSIM4sbNode},{4,i->BSIM4dbNode},
 {i->BSIM4dNodePrime,i->BSIM4sNodePrime},{i->BSIM4dNodePrime,i->BSIM4sNodePrime},{i->BSIM4gNodePrime,i->BSIM4sNodePrime},{i->BSIM4gNodePrime,i->BSIM4dNodePrime},{i->BSIM4gNodePrime,i->BSIM4bNodePrime}};
 if(m->BSIM4tnoiMod){
  double ratio=i->BSIM4Vgsteff/i->BSIM4EsatL;
  double beta=m->BSIM4rnoia*(1+ratio*ratio*m->BSIM4tnoia*p->BSIM4leff),theta=m->BSIM4rnoib*(1+ratio*ratio*m->BSIM4tnoib*p->BSIM4leff);
  int source=owner->states[0][3]>=0?1:0;g[source]/=1+theta*theta*g[source]/i->BSIM4IdovVds;
  double total=i->BSIM4gm+i->BSIM4gmbs+i->BSIM4gds,partition=beta*(i->BSIM4gm+i->BSIM4gmbs)+i->BSIM4gds;
  g[8]=(partition-theta*total)*(partition+theta*total)/i->BSIM4IdovVds;
 }else {
  double uq=i->BSIM4ueff*fabs(i->BSIM4qinv),series=!m->BSIM4rdsMod&&i->BSIM4grdsw>0?1/i->BSIM4grdsw:0;
  g[8]=m->BSIM4ntnoi*uq/(p->BSIM4leff*p->BSIM4leff+series*uq);
 }
 int bodymode=5;if(i->BSIM4rbodyMod==2)bodymode=(!m->BSIM4rbps0Given||!m->BSIM4rbpd0Given)?1:((!m->BSIM4rbsbx0Given&&!m->BSIM4rbsby0Given)||(!m->BSIM4rbdbx0Given&&!m->BSIM4rbdby0Given))?3:5;
 if(!i->BSIM4rbodyMod)for(int n=3;n<8;n++)g[n]=0;
 else {if(bodymode<5)g[6]=g[7]=0;if(bodymode==1)g[3]=g[4]=0;}
 double expected[14]={0};for(int n=0;n<9;n++)expected[n]=4*1.3806226e-23*owner->circuit.CKTtemp*g[n]*gain(real,imaginary,pairs[n][0],pairs[n][1]);
 expected[9]=flicker_power(actual.frequency)*gain(real,imaginary,pairs[9][0],pairs[9][1]);
 double currents[]={i->BSIM4Igs+(i->BSIM4mode>=0?i->BSIM4Igcs:i->BSIM4Igcd),i->BSIM4Igd+(i->BSIM4mode>=0?i->BSIM4Igcd:i->BSIM4Igcs),i->BSIM4Igb};
 for(int n=10;n<13;n++)expected[n]=2*1.6021918e-19*fabs(currents[n-10])*gain(real,imaginary,pairs[n][0],pairs[n][1]);
 for(int n=0;n<13;n++){if(n==9&&fabs(actual.density[n]-expected[n])>1e-290+2e-10*fabs(expected[n]))fprintf(stderr,"flicker mode=%d freq=%g vgs=%g vd=%g cd=%g n0=%g nl=%g nstar=%g\n",m->BSIM4fnoiMod,actual.frequency,owner->states[0][2],owner->states[0][3],i->BSIM4cd,m->BSIM4coxe*i->BSIM4Vgsteff/CHARGE,m->BSIM4coxe*i->BSIM4Vgsteff*(1-i->BSIM4AbovVgst2Vtm*i->BSIM4Vdseff)/CHARGE,i->BSIM4nstar);equal(actual.density[n],expected[n],1e-290,2e-10,"source law",id,n);expected[13]+=expected[n];}
 equal(actual.density[13],expected[13],1e-290,2e-10,"source sum",id,13);
#ifdef COEFFICIENT_REFERENCE
 double original[14];assert(cs_noise_oracle(m,i,owner->circuit.CKTtemp,owner->states[0],real,imaginary,actual.frequency,original)==0);
 for(int n=0;n<14;n++)equal(actual.density[n],original[n],1e-32,2e-7,"coefficient-isolated original",id,n);oracles++;
#endif
}
static void history_unchanged(double history[2][29],double noise[3][14]) {
 assert(!memcmp(owner->states[1],history,2*29*sizeof(double)));assert(!memcmp(owner->instance.BSIM4nVar,noise,3*14*sizeof(double)));
}
static void extreme_primitives(void) {
 double real[13]={0},imaginary[13]={0};CKTcircuit c={0};c.nodeCount=12;c.CKTtemp=300.15;
 CSBSIM45NoiseContext context={real,imaginary,&c,0};real[1]=DBL_MAX;real[2]=-DBL_MAX;
 double density,logarithm;cs_noise_single(&density,&logarithm,&context,THERMNOISE,1,2,1e-300);
 assert(!context.failed&&isfinite(density)&&density>0);
 printf("PRIMITIVE %.17g %.17g %.17g %.17g\n",real[1],real[2],1e-300,density);
 cs_noise_single(&density,&logarithm,&context,THERMNOISE,1,2,0);assert(density==0&&!context.failed);
 cs_noise_single(&density,&logarithm,&context,THERMNOISE,1,2,-1);assert(context.failed&&isnan(density));
 context.failed=0;cs_noise_single(&density,&logarithm,&context,SHOTNOISE,99,2,1);assert(context.failed&&isnan(density));
 const double cases[][4]={{1e-300,1e300,1e200,1e-200},{DBL_MIN,DBL_MAX,1e300,1e-300},{1,1+DBL_EPSILON,1e-20,1e-20},{1,1e6,1e-20,1e-26}};
 for(size_t n=0;n<sizeof(cases)/sizeof(cases[0]);n++){
  CSBSIM45NoiseSpectrum a={cases[n][0],{0}},b={cases[n][1],{0}};a.density[0]=a.density[13]=cases[n][2];b.density[0]=b.density[13]=cases[n][3];
  CSBSIM45NoiseIntegral out;assert(cs_bsim45_integrate_noise(&a,&b,&out)==0);
  printf("INTEGRAL %.17g %.17g %.17g %.17g %.17g\n",a.frequency,b.frequency,a.density[0],b.density[0],out.power[0]);
 }
 CSBSIM45NoiseSpectrum a={DBL_MIN,{0}},b={2*DBL_MIN,{0}};a.density[0]=a.density[13]=b.density[0]=b.density[13]=DBL_MIN;
 CSBSIM45NoiseIntegral out,sentinel;memset(&sentinel,0x5a,sizeof(sentinel));out=sentinel;
 assert(cs_bsim45_integrate_noise(&a,&b,&out)==CS_BSIM45_NONFINITE&&!memcmp(&out,&sentinel,sizeof(out)));
}
static void integral_identities(void) {
 for(int exponent=-4;exponent<=4;exponent++){
  CSBSIM45NoiseSpectrum lower={2,{0}},upper={200,{0}};lower.density[0]=1e-20*pow(2,exponent);upper.density[0]=1e-20*pow(200,exponent);lower.density[13]=lower.density[0];upper.density[13]=upper.density[0];
  CSBSIM45NoiseIntegral result;assert(cs_bsim45_integrate_noise(&lower,&upper,&result)==CS_BSIM45_OK);
  double exact=1e-20*(exponent==-1?log(100):(pow(200,exponent+1)-pow(2,exponent+1))/(exponent+1));equal(result.power[0],exact,1e-290,2e-13,"power-law integral",-1,exponent);equal(result.rmsVoltage,sqrt(exact),1e-290,2e-13,"integrated RMS",-1,exponent);integrals++;
 }
 const double near[]={-1-1e-12,-1+1e-12,-1e-12,1e-12};
 for(int n=0;n<4;n++){double x=near[n];CSBSIM45NoiseSpectrum a={1,{0}},b={1e6,{0}};a.density[0]=a.density[13]=1e-20;b.density[0]=b.density[13]=1e-20*pow(1e6,x);CSBSIM45NoiseIntegral out;assert(cs_bsim45_integrate_noise(&a,&b,&out)==0);double exact=1e-20*expm1((x+1)*log(1e6))/(x+1);equal(out.power[0],exact,1e-290,2e-13,"near limit integral",-1,n);integrals++;}
 CSBSIM45NoiseSpectrum a={1,{0}},b={3,{0}};CSBSIM45NoiseIntegral result;assert(cs_bsim45_integrate_noise(&a,&b,&result)==0&&result.power[13]==0&&result.rmsVoltage==0);b.density[0]=b.density[13]=4;assert(cs_bsim45_integrate_noise(&a,&b,&result)==0);equal(result.power[13],4,0,2e-15,"zero endpoint linear",-1,0);
 CSBSIM45NoiseIntegral sentinel;memset(&sentinel,0x5a,sizeof(sentinel));result=sentinel;
 a.frequency=b.frequency;assert(cs_bsim45_integrate_noise(&a,&b,&result)==CS_BSIM45_PARAMETER&&!memcmp(&sentinel,&result,sizeof(result)));
 a.frequency=1;b.density[13]=5;assert(cs_bsim45_integrate_noise(&a,&b,&result)==CS_BSIM45_PARAMETER&&!memcmp(&sentinel,&result,sizeof(result)));
 b.density[0]=b.density[13]=DBL_MAX;b.frequency=DBL_MAX;assert(cs_bsim45_integrate_noise(&a,&b,&result)==CS_BSIM45_NONFINITE&&!memcmp(&sentinel,&result,sizeof(result)));
 a.frequency=DBL_MIN;b.frequency=DBL_MAX;a.density[0]=a.density[13]=1e300;b.density[0]=b.density[13]=1e-300;assert(cs_bsim45_integrate_noise(&a,&b,&result)==0);assert(isfinite(result.rmsVoltage));
}
static void failures(void) {
 CSBSIM45Conditions c={cs_bsim45_owner_size(),100,128,300.15,300.15,1};
 for(int intent=0;intent<=1;intent++){
  c.noiseTopology=intent;assert(cs_bsim45_create("4.5.0",2,1,&c,&owner)==0);
  set(1,BSIM4_MOD_TNOIMOD,CS_BSIM45_INTEGER,1);set(1,BSIM4_MOD_FNOIMOD,CS_BSIM45_INTEGER,0);set(1,BSIM4_MOD_EF,CS_BSIM45_REAL,2);assert(cs_bsim45_prepare(owner)==0);
  CSBSIM45PreparedInfo p;assert(cs_bsim45_prepared_info(owner,&p)==0);if(intent)assert(p.drainPrime!=1&&p.sourcePrime!=3);else assert(p.drainPrime==1&&p.sourcePrime==3);
  double bias[13],real[13],imaginary[13];fixture_bias(p,1,0,bias);noise_gains(p,real,imaginary);
  assert(cs_bsim45_initialize_history(owner,bias,13,1e-12)==0);CSBSIM45History before;assert(cs_bsim45_history(owner,&before)==0);
  CSBSIM45TransientResult trial;assert(cs_bsim45_evaluate_transient(owner,bias,13,0,1e-12,CS_BSIM45_BE,1e-10,&trial)==0);
  CSBSIM45NoiseSpectrum out,sentinel;memset(&sentinel,0x5a,sizeof(sentinel));out=sentinel;
  if(!intent){assert(cs_bsim45_noise_spectrum(owner,bias,13,0,1e3,real,imaginary,&out)==CS_BSIM45_NOISE_UNPREPARED);assert(!memcmp(&out,&sentinel,sizeof(out)));}
  else {
   double invalid[]={0,-1,NAN,INFINITY};for(int n=0;n<4;n++)assert(cs_bsim45_noise_spectrum(owner,bias,13,0,invalid[n],real,imaginary,&out)==CS_BSIM45_PARAMETER&&!memcmp(&out,&sentinel,sizeof(out)));
   real[0]=1;assert(cs_bsim45_noise_spectrum(owner,bias,13,0,1e3,real,imaginary,&out)==CS_BSIM45_PARAMETER);real[0]=0;
   real[1]=NAN;assert(cs_bsim45_noise_spectrum(owner,bias,13,0,1e3,real,imaginary,&out)==CS_BSIM45_PARAMETER);noise_gains(p,real,imaginary);
   assert(cs_bsim45_noise_spectrum(owner,bias,12,0,1e3,real,imaginary,&out)==CS_BSIM45_PARAMETER);
   assert(cs_bsim45_noise_spectrum(owner,bias,13,0,1e3,NULL,imaginary,&out)==CS_BSIM45_PARAMETER);
   assert(cs_bsim45_noise_spectrum(owner,bias,13,0,1e3,real,imaginary,NULL)==CS_BSIM45_PARAMETER);
   assert(!memcmp(&out,&sentinel,sizeof(out)));
   CSBSIM45NoiseSpectrum normal=spectrum(bias,1e3,real,imaginary);
   CSBSIM45NoiseSpectrum highFrequency=spectrum(bias,DBL_MAX,real,imaginary);
   for(int n=0;n<14;n++)equal(highFrequency.density[n],normal.density[n],0,2e-14,"zero flicker frequency independence",-1,n);
   for(int n=0;n<13;n++){real[n]*=1e156;imaginary[n]*=1e156;}
   CSBSIM45NoiseSpectrum huge=spectrum(bias,1e3,real,imaginary);
   for(int n=0;n<14;n++)if(normal.density[n]>0)equal(log(huge.density[n])-log(normal.density[n]),312*log(10.),0,2e-14,"representable huge gain",-1,n);
  }
  assert(cs_bsim45_commit(owner,trial.token)==CS_BSIM45_HISTORY);CSBSIM45History after;assert(cs_bsim45_history(owner,&after)==0&&!memcmp(&before,&after,sizeof(before)));
  if(intent){noise_gains(p,real,imaginary);for(int n=1;n<=p.nodeCount;n++)real[n]=(n%2?1:-1)*DBL_MAX;assert(cs_bsim45_noise_spectrum(owner,bias,13,0,1e3,real,imaginary,&out)==CS_BSIM45_NONFINITE&&!memcmp(&out,&sentinel,sizeof(out)));assert(owner->state==-1);assert(cs_bsim45_history(owner,&after)==0&&!memcmp(&before,&after,sizeof(before)));}
  cs_bsim45_destroy(owner);
 }
}
int main(int argc,char **argv) {
#ifdef COEFFICIENT_REFERENCE
 size_t originalLayout[5],layout[]={sizeof(BSIM4model),sizeof(BSIM4instance),sizeof(struct bsim4SizeDependParam),offsetof(BSIM4instance,BSIM4gm),offsetof(BSIM4instance,BSIM4nVar)};
 cs_noise_oracle_layout(originalLayout);assert(!memcmp(layout,originalLayout,sizeof(layout)));
#endif
 int count=argc>1?atoi(argv[1]):STATIC_FIXTURES;
 for(int id=0;id<count;id++)for(int thermal=0;thermal<2;thermal++)for(int flicker=0;flicker<2;flicker++){
  StaticFixture f=fixture(id);CSBSIM45Conditions c={cs_bsim45_owner_size(),100,128,f.ambient,300.15,1};assert(cs_bsim45_create("4.5.0",2,f.polarity,&c,&owner)==0);noise_parameters(id,thermal,flicker);assert(cs_bsim45_prepare(owner)==0);
  CSBSIM45PreparedInfo p;assert(cs_bsim45_prepared_info(owner,&p)==0);double history[2][29],noise[3][14],bias[13],real[13],imaginary[13];
  for(int bank=1;bank<=2;bank++)for(int n=0;n<29;n++)owner->states[bank][n]=bank*29+n;
  for(int bank=0;bank<3;bank++)for(int n=0;n<14;n++)owner->instance.BSIM4nVar[bank][n]=bank*14+n;
  memcpy(history,owner->states[1],sizeof(history));memcpy(noise,owner->instance.BSIM4nVar,sizeof(noise));
  for(int point=0;point<7;point++){
   fixture_bias(p,f.polarity,point,bias);noise_gains(p,real,imaginary);CSBSIM45NoiseSpectrum previous={0},first={0};double total[14]={0};
   for(int frequency=0;frequency<5;frequency++){
    CSBSIM45NoiseSpectrum out=spectrum(bias,noise_frequencies[frequency],real,imaginary);source_identities(out,real,imaginary,id);history_unchanged(history,noise);
    if(!frequency)first=out;
    else {CSBSIM45NoiseIntegral interval;assert(cs_bsim45_integrate_noise(&previous,&out,&interval)==0);for(int n=0;n<14;n++)total[n]+=interval.power[n];
     double sum=0;for(int n=0;n<13;n++){double exact=n==9?first.density[n]*(-expm1((1-owner->model.BSIM4ef)*log(out.frequency)))/(owner->model.BSIM4ef-1):first.density[n]*(out.frequency-1);equal(total[n],exact,1e-290,2e-10,"sweep integral",id,n);sum+=exact;}
     equal(sqrt(total[13]),sqrt(sum),1e-18,2e-7,"sweep RMS",id,13);integrals++;
    }previous=out;
   }
   CSBSIM45NoiseSpectrum center=spectrum(bias,1e6,real,imaginary);
   for(int n=0;n<13;n++){double re=real[n],im=imaginary[n];real[n]=-2*im;imaginary[n]=2*re;}
   CSBSIM45NoiseSpectrum rotated=spectrum(bias,1e6,real,imaginary);for(int n=0;n<14;n++)equal(rotated.density[n],4*center.density[n],1e-290,2e-13,"complex rotation and scale",id,n);
   memset(real,0,sizeof(real));memset(imaginary,0,sizeof(imaginary));for(int n=1;n<=p.nodeCount;n++)if(n!=p.chargeNode)real[n]=2;
   CSBSIM45NoiseSpectrum common=spectrum(bias,1e6,real,imaginary);for(int n=0;n<14;n++)assert(common.density[n]==0);history_unchanged(history,noise);
  }
  cs_bsim45_destroy(owner);
 }
 extreme_primitives();integral_identities();failures();assert(allocations==(size_t)count*4+2&&releases==allocations&&setups==allocations&&temperatures==allocations);
 printf("PASS fixtures=%d owners=%zu releases=%zu setups=%zu temperatures=%zu identities=%zu coefficientOracles=%zu integrals=%zu evaluationAllocations=0 repeatedSetup=0 historyAndNoiseHistoryUnchanged=1 ownerBytes=%zu\n",count,allocations,releases,setups,temperatures,identities,oracles,integrals,cs_bsim45_owner_size());
}
