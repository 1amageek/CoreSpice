/* Compile with original headers/layout and untouched original b4noi.c.
   Copy only to isolate original nVar writes; physical coefficients are unchanged. */
#include "bsim4def.h"
#include <string.h>
#include <stddef.h>
ReferenceFrontend *SPfrontEnd;
void cs_noise_oracle_layout(size_t out[5]){out[0]=sizeof(BSIM4model);out[1]=sizeof(BSIM4instance);out[2]=sizeof(struct bsim4SizeDependParam);out[3]=offsetof(BSIM4instance,BSIM4gm);out[4]=offsetof(BSIM4instance,BSIM4nVar);}
extern int BSIM4noise(int,int,GENmodel *,CKTcircuit *,Ndata *,double *);
int cs_noise_oracle(const void *model,const void *instance,double temperature,const double *states,
 const double *real,const double *imaginary,double frequency,double out[14]) {
 BSIM4model m=*(const BSIM4model*)model;BSIM4instance i=*(const BSIM4instance*)instance;
 m.BSIM4instances=&i;m.BSIM4nextModel=NULL;i.BSIM4nextInstance=NULL;i.BSIM4modPtr=&m;
 CKTcircuit c={0};c.CKTtemp=temperature;c.CKTstates[0]=(double*)states;c.CKTrhs=(double*)real;c.CKTirhs=(double*)imaginary;
 NOISEAN job={frequency,1};c.CKTcurJob=&job;Ndata data={0};data.freq=frequency;data.prtSummary=1;data.outpVector=out;
 double sum=0;return BSIM4noise(N_DENS,N_CALC,(GENmodel*)&m,&c,&data,&sum);
}
