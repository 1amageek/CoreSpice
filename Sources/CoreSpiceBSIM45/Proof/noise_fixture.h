/* Shared inputs only; no expected noise values or production projection. */
#include "static_fixture.h"
static void noise_parameters(int id,int thermal,int flicker) {
 fixture_parameters(fixture(id));
 set(1,BSIM4_MOD_TNOIMOD,CS_BSIM45_INTEGER,thermal);
 set(1,BSIM4_MOD_FNOIMOD,CS_BSIM45_INTEGER,flicker);
 set(1,BSIM4_MOD_KF,CS_BSIM45_REAL,1e-25);
 set(1,BSIM4_MOD_AF,CS_BSIM45_REAL,1.1);
 set(1,BSIM4_MOD_EF,CS_BSIM45_REAL,1.2);
 set(1,BSIM4_MOD_EM,CS_BSIM45_REAL,id%2?0:4.1e7);
 if(id%3>=1){set(1,BSIM4_MOD_RBPS0,CS_BSIM45_REAL,50);set(1,BSIM4_MOD_RBPD0,CS_BSIM45_REAL,60);}
 if(id%3==2){set(1,BSIM4_MOD_RBSBX0,CS_BSIM45_REAL,100);set(1,BSIM4_MOD_RBDBX0,CS_BSIM45_REAL,120);}
}
static void noise_gains(CSBSIM45PreparedInfo p,double real[13],double imaginary[13]) {
 memset(real,0,13*sizeof(double));memset(imaginary,0,13*sizeof(double));
 for(int n=1;n<=p.nodeCount;n++)if(n!=p.chargeNode){real[n]=(n%3-1)*0.75+0.125*n;imaginary[n]=((n*7)%5-2)*0.4;}
}
static const double noise_frequencies[]={1,1e3,1e6,1e9,1e12};
