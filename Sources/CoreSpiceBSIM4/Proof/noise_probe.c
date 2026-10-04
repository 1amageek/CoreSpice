#include "../include/CoreSpiceBSIM4.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int checks=0;
#define CHECK(condition) do { checks++; if(!(condition)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#condition);exit(1);} }while(0)
static void close_value(double actual,double expected) { CHECK(fabs(actual-expected)<=1e-30+2e-12*fmax(fabs(actual),fabs(expected))); }
static CSBSIM4Handle *model(int noise,int thermal,int flicker,int polarity,CSBSIM4Topology *topology) {
 CSBSIM4Handle *handle=NULL;CHECK(cs_bsim4_create(polarity,"4.8.3",300.15,noise,&handle)==0);
 CHECK(cs_bsim4_set_stress_budget(handle,8)==0);
 const char *names[]={"toxe","u0","vth0","tnoimod","fnoimod","kf"};
 double values[]={1e-8,.05,polarity*.7,thermal,flicker,1e-25};
 for(int n=0;n<6;n++)CHECK(cs_bsim4_parameter(handle,1,names[n],values[n])==0);
 CHECK(cs_bsim4_parameter(handle,0,"l",1e-6)==0);CHECK(cs_bsim4_parameter(handle,0,"w",1e-5)==0);
 CHECK(cs_bsim4_prepare(handle,topology)==0);return handle;
}
static void bias(const CSBSIM4Topology *t,int polarity,double b[13]) {
 memset(b,0,13*sizeof(double));b[1]=polarity;b[2]=polarity*1.2;b[4]=-polarity*.1;
 b[t->drainPrime]=b[1];b[t->sourcePrime]=b[3];b[t->gatePrime]=b[2];b[t->gateMid]=b[2];
 b[t->bodyPrime]=b[4];b[t->drainBody]=b[4];b[t->sourceBody]=b[4];b[0]=0;
}
int main(void) {
 for(int polarity=-1;polarity<=1;polarity+=2)for(int thermal=0;thermal<3;thermal++)for(int flicker=0;flicker<2;flicker++) {
  CSBSIM4Topology topology;CSBSIM4Handle *handle=model(1,thermal,flicker,polarity,&topology);
  double b[13],real[13]={0},imaginary[13]={0},spectrum[14];bias(&topology,polarity,b);
  real[topology.drainPrime]=1;imaginary[topology.gatePrime]=.3;
  CHECK(cs_bsim4_noise_spectrum(handle,b,1e10,1e-12,real,imaginary,spectrum)==0);
  for(int n=0;n<14;n++)CHECK(isfinite(spectrum[n])&&spectrum[n]>=0);
  CHECK(spectrum[8]>0);CHECK(spectrum[9]>0);
  CHECK(cs_bsim4_initialize_history(handle,b)==0);double before[29],after[29];CHECK(cs_bsim4_accepted_states(handle,before)==0);
  CSBSIM4Result trial;CHECK(cs_bsim4_evaluate(handle,b,2,0,1e-9,1e-12,&trial)==0);
  CHECK(cs_bsim4_noise_spectrum(handle,b,1e10,1e-12,real,imaginary,spectrum)==0);
  CHECK(cs_bsim4_commit(handle,trial.token)==CS_BSIM4_HISTORY);CHECK(cs_bsim4_accepted_states(handle,after)==0);
  CHECK(memcmp(before,after,sizeof(before))==0);
  double sentinel[14];for(int n=0;n<14;n++)sentinel[n]=123;
  CHECK(cs_bsim4_noise_spectrum(handle,b,0,1e-12,real,imaginary,sentinel)!=0);
  for(int n=0;n<14;n++)CHECK(sentinel[n]==123);
  real[0]=1;CHECK(cs_bsim4_noise_spectrum(handle,b,1e10,1e-12,real,imaginary,sentinel)!=0);real[0]=0;
  real[topology.drainPrime]=1e308;CHECK(cs_bsim4_noise_spectrum(handle,b,1e10,1e-12,real,imaginary,sentinel)==CS_BSIM4_NUMERICAL);
  cs_bsim4_destroy(handle);
 }
 CSBSIM4Topology topology;CSBSIM4Handle *handle=model(1,2,0,1,&topology);
 double b[13],real[13]={0},imaginary[13]={0},density[14];bias(&topology,1,b);
 real[topology.drainPrime]=1;CHECK(cs_bsim4_noise_spectrum(handle,b,1e10,0,real,imaginary,density)==0);double A=density[13];
 real[topology.drainPrime]=0;real[topology.gatePrime]=1;CHECK(cs_bsim4_noise_spectrum(handle,b,1e10,0,real,imaginary,density)==0);double B=density[13];CHECK(A>0&&B>0);
 real[topology.drainPrime]=1;real[topology.gatePrime]=0;imaginary[topology.gatePrime]=1;
 CHECK(cs_bsim4_noise_spectrum(handle,b,1e10,0,real,imaginary,density)==0);close_value(density[13],A+B-2*sqrt(A*B));
 imaginary[topology.gatePrime]=-1;CHECK(cs_bsim4_noise_spectrum(handle,b,1e10,0,real,imaginary,density)==0);close_value(density[13],A+B+2*sqrt(A*B));
 cs_bsim4_destroy(handle);handle=model(0,1,0,1,&topology);bias(&topology,1,b);
 CHECK(cs_bsim4_noise_spectrum(handle,b,1e3,0,real,imaginary,density)==CS_BSIM4_NOISE_UNPREPARED);cs_bsim4_destroy(handle);
 printf("CSBSIM4NoiseProof/originalModes 12 configurations\nCSBSIM4NoiseProof/complexInterference\nCSBSIM4NoiseProof/historyFailureLifetime\nchecks=%d\n",checks);return 0;
}
