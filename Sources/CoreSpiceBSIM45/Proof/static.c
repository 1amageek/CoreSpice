#include "CoreSpiceBSIM45.h"
#include "bsim4def.h"
#include <assert.h>
#include <float.h>
#include <stdio.h>
static CSBSIM45Owner *owner;
static void set(int role,int id,int kind,double value) {
 assert((role?cs_bsim45_set_model(owner,id,kind,value):cs_bsim45_set_instance(owner,id,kind,value))==CS_BSIM45_OK);
}
#include "static_fixture.h"
static CSBSIM45PreparedInfo setup_fixture(StaticFixture f,int symmetric) {
 CSBSIM45Conditions c={cs_bsim45_owner_size(),100,128,f.ambient,300.15,0};
 assert(cs_bsim45_create("4.5.0",2,f.polarity,&c,&owner)==CS_BSIM45_OK);fixture_parameters(f);
 if(symmetric) {
  set(1,BSIM4_MOD_UA,CS_BSIM45_REAL,0);set(1,BSIM4_MOD_UB,CS_BSIM45_REAL,0);set(1,BSIM4_MOD_UC,CS_BSIM45_REAL,0);
  set(1,BSIM4_MOD_IGCMOD,CS_BSIM45_INTEGER,0);set(1,BSIM4_MOD_IGBMOD,CS_BSIM45_INTEGER,0);set(1,BSIM4_MOD_AGIDL,CS_BSIM45_REAL,0);
 }
 assert(cs_bsim45_prepare(owner)==CS_BSIM45_OK);CSBSIM45PreparedInfo p;assert(cs_bsim45_prepared_info(owner,&p)==CS_BSIM45_OK);return p;
}
static CSBSIM45PreparedInfo setup(int id) {return setup_fixture(fixture(id),0);}
static CSBSIM45StaticResult evaluate(const double bias[13]) {
 CSBSIM45StaticResult out;assert(cs_bsim45_evaluate_static(owner,bias,13,1e-12,&out)==CS_BSIM45_OK);return out;
}
static int close_value(double a,double b,double absolute,double relative){return fabs(a-b)<=absolute+relative*fmax(fabs(a),fabs(b));}
static void sums(CSBSIM45StaticResult out,int id,int point) {
 double isum=0,qsum=0,imag=0,qmag=0;
 for(int r=0;r<13;r++){isum+=out.current[r];qsum+=out.charge[r];imag+=fabs(out.current[r]);qmag+=fabs(out.charge[r]);}
 assert(fabs(isum)<=1e-16+2e-12*imag);assert(fabs(qsum)<=1e-28+2e-12*qmag);
 const double *arrays[]={out.conductance,out.capacitance};
 for(int a=0;a<2;a++)for(int n=0;n<13;n++) {
  double row=0,col=0,mag=0;
  for(int m=0;m<13;m++){row+=arrays[a][n*13+m];col+=arrays[a][m*13+n];mag+=fabs(arrays[a][n*13+m])+fabs(arrays[a][m*13+n]);}
  double tol=(a?1e-28:1e-16)+2e-12*mag;
  if(fabs(row)>tol||fabs(col)>tol){fprintf(stderr,"Conservation fixture=%d point=%d matrix=%d node=%d row=%g col=%g\n",id,point,a,n,row,col);assert(0);}
 }
}
static int failures,printed;static long long derivativeCells,evaluations;
static void differences(CSBSIM45PreparedInfo p,double bias[13],CSBSIM45StaticResult base,int id,int point) {
 const double steps[]={1e-2,3e-3,1e-3,3e-4,1e-4,1e-5,1e-6};
 for(int col=1;col<=p.nodeCount;col++)if(col!=p.chargeNode) {
  int streak[2][13]={{0}},best[2][13]={{0}};
  double last[2][13]={{0}};
  for(int h=0;h<7;h++) {
   double original=bias[col],direction=0;
   /* Vds=0 selects the forward branch. Differentiate that branch instead of
      averaging two unequal one-sided slopes of the piecewise charge law. */
   if(point==6&&col==p.drainPrime)direction=p.polarity;
   if(point==6&&col==p.sourcePrime)direction=-p.polarity;
   bias[col]=original+(direction?direction:1)*steps[h];CSBSIM45StaticResult plus=evaluate(bias);
   bias[col]=original+(direction?2*direction:-1)*steps[h];CSBSIM45StaticResult minus=evaluate(bias);bias[col]=original;evaluations+=2;
   for(int row=0;row<13;row++)for(int a=0;a<2;a++) {
    double numerical=((a?plus.charge[row]:plus.current[row])-(a?minus.charge[row]:minus.current[row]))/(2*steps[h]);
    if(direction)numerical=(-3*(a?base.charge[row]:base.current[row])+4*(a?plus.charge[row]:plus.current[row])-(a?minus.charge[row]:minus.current[row]))/(2*direction*steps[h]);
    double analytic=(a?base.capacitance:base.conductance)[row*13+col];last[a][row]=numerical;
    if(close_value(analytic,numerical,a?1e-20:1e-10,(!a && id>=580)?1e-6:2e-4)){streak[a][row]++;if(streak[a][row]>best[a][row])best[a][row]=streak[a][row];}else streak[a][row]=0;
   }
  }
  for(int row=0;row<13;row++)for(int a=0;a<2;a++) {
   derivativeCells++;
   if(best[a][row]<2){failures++;if(printed++<20)fprintf(stderr,"Derivative fixture=%d point=%d matrix=%d row=%d col=%d analytic=%.17g lastFD=%.17g\n",id,point,a,row,col,(a?base.capacitance:base.conductance)[row*13+col],last[a][row]);}
  }
 }
}
static void admission(void) {
 CSBSIM45PreparedInfo p=setup(0);double bias[13];fixture_bias(p,-1,0,bias);CSBSIM45StaticResult out,previous;
 memset(&out,0x5a,sizeof(out));previous=out;
 assert(cs_bsim45_evaluate_static(owner,bias,12,0,&out)==CS_BSIM45_PARAMETER&&!memcmp(&out,&previous,sizeof(out)));
 bias[0]=1;assert(cs_bsim45_evaluate_static(owner,bias,13,0,&out)==CS_BSIM45_PARAMETER);bias[0]=0;
 bias[1]=NAN;assert(cs_bsim45_evaluate_static(owner,bias,13,0,&out)==CS_BSIM45_PARAMETER);
 fixture_bias(p,-1,0,bias);assert(cs_bsim45_evaluate_static(owner,bias,13,-1,&out)==CS_BSIM45_PARAMETER);
 assert(!memcmp(&out,&previous,sizeof(out)));out=evaluate(bias);
 cs_bsim45_destroy(owner);
}
static void symmetry(void) {
 for(int cap=0;cap<3;cap++) {
  StaticFixture f=fixture(0);f.cap=cap;f.mob=0;f.wpe=0;f.nf=2.5;f.gate=3;f.body=2;f.series=1;
  CSBSIM45StaticResult positive[STATIC_BIASES];
  for(int polarity=1;polarity>=-1;polarity-=2) {
   f.polarity=polarity;CSBSIM45PreparedInfo p=setup_fixture(f,1);double bias[13];
   for(int point=0;point<STATIC_BIASES;point++) {
    fixture_bias(p,polarity,point,bias);CSBSIM45StaticResult result=evaluate(bias);
    if(polarity==1)positive[point]=result;
    else {
     for(int n=0;n<13;n++){assert(close_value(result.current[n],-positive[point].current[n],1e-13,2e-7));assert(close_value(result.charge[n],-positive[point].charge[n],1e-23,2e-7));}
     for(int n=0;n<169;n++){assert(close_value(result.conductance[n],positive[point].conductance[n],1e-10,2e-7));assert(close_value(result.capacitance[n],positive[point].capacitance[n],1e-20,2e-7));}
    }
   }
   memset(bias,0,sizeof(bias));CSBSIM45StaticResult zero;
   assert(cs_bsim45_evaluate_static(owner,bias,13,0,&zero)==CS_BSIM45_OK);
   for(int n=0;n<13;n++)assert(fabs(zero.current[n])<1e-16);
   cs_bsim45_destroy(owner);
  }
 }
}
int main(int argc,char **argv) {
 int begin=argc>1?atoi(argv[1]):0,end=argc>2?atoi(argv[2]):STATIC_FIXTURES;int memoryCheck=argc>3&&!strcmp(argv[3],"--memory-check");admission();symmetry();
 for(int id=begin;id<end;id++) {
  int priorFailures=failures;CSBSIM45PreparedInfo p=setup(id);StaticFixture f=fixture(id);double bias[13];
  for(int point=0;point<STATIC_BIASES;point++) {
   fixture_bias(p,f.polarity,point,bias);CSBSIM45StaticResult base=evaluate(bias);sums(base,id,point);if(!memoryCheck)differences(p,bias,base,id,point);
   CSBSIM45StaticResult again=evaluate(bias);assert(!memcmp(&base,&again,sizeof(base)));
   for(int n=1;n<=p.nodeCount;n++)if(n!=p.chargeNode)bias[n]+=0.37;
   CSBSIM45StaticResult shifted=evaluate(bias);
   for(int n=0;n<13;n++){assert(close_value(base.current[n],shifted.current[n],1e-13,2e-7));assert(close_value(base.charge[n],shifted.charge[n],1e-23,2e-7));}
  }
  if(failures>priorFailures)fprintf(stderr,"fixture_summary=%d cap=%d failures=%d\n",id,f.cap,failures-priorFailures);
  cs_bsim45_destroy(owner);
 }
 printf("fixtures=%d points=%d derivative_cells=%lld perturbation_evaluations=%lld failures=%d\n",end-begin,(end-begin)*STATIC_BIASES,derivativeCells,evaluations,failures);
 return failures?1:0;
}
