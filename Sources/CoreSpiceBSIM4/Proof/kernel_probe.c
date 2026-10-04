#include "../include/CoreSpiceBSIM4.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <float.h>

static int checkCount;
#define CHECK(x) do {checkCount++;if(!(x)){fprintf(stderr,"FAIL %s:%d: %s\n",__FILE__,__LINE__,#x);exit(1);}}while(0)
static void parameter(CSBSIM4Handle *h,int model,const char *n,double v){CHECK(cs_bsim4_parameter(h,model,n,v)==0);}
static CSBSIM4Handle *makeScaled(int polarity,int kind,double temp,double currentScale,double chargeScale,CSBSIM4Topology *topology) {
 CSBSIM4Handle *h=NULL;CHECK(cs_bsim4_create(polarity,"4.8.3",temp,1,&h)==0);
 CHECK(cs_bsim4_set_stress_budget(h,8)==0);
 parameter(h,0,"mult_i",currentScale);parameter(h,0,"mult_q",chargeScale);
 parameter(h,0,"l",1e-6);parameter(h,0,"w",10e-6);
 parameter(h,1,"toxe",10e-9);parameter(h,1,"vth0",polarity*.7);parameter(h,1,"u0",.05);
 if(kind){parameter(h,1,"rsh",20);parameter(h,0,"nrd",1);parameter(h,0,"nrs",1);}
 if(kind>=2){parameter(h,0,"rbodymod",1);parameter(h,0,"rgatemod",3);parameter(h,0,"ad",1e-12);parameter(h,0,"as",1e-12);parameter(h,0,"pd",4e-6);parameter(h,0,"ps",4e-6);parameter(h,1,"cgso",1e-10);parameter(h,1,"cgdo",1e-10);parameter(h,1,"cgbo",1e-10);}
 if(kind==3){parameter(h,0,"trnqsmod",1);parameter(h,0,"acnqsmod",1);}
 CHECK(cs_bsim4_prepare(h,topology)==0);return h;
}
static CSBSIM4Handle *make(int polarity,int kind,double temp,CSBSIM4Topology *topology) {
 return makeScaled(polarity,kind,temp,1,1,topology);
}
static void bias(const CSBSIM4Topology *t,double b[13],int p,double d,double g,double bulk) {
 memset(b,0,13*sizeof(double));b[1]=p*d;b[2]=p*g;b[4]=p*bulk;
 b[t->drainPrime]=p*d;b[t->sourcePrime]=0;b[t->gatePrime]=p*g;b[t->gateMid]=p*g;
 b[t->bodyPrime]=p*bulk;b[t->drainBody]=p*bulk;b[t->sourceBody]=p*bulk;
}
static void coldAdmission(void) {
 CSBSIM4Handle *h=(CSBSIM4Handle *)1;CHECK(cs_bsim4_create(1,"4.8.1",300.15,0,&h)==CS_BSIM4_VERSION&&h==NULL);
 CHECK(cs_bsim4_create(1,"4.8.3",NAN,0,&h)==CS_BSIM4_PARAMETER);
 CHECK(cs_bsim4_create(1,"4.8.3",300.15,1,&h)==0);CHECK(cs_bsim4_set_stress_budget(h,8)==0);
 CHECK(cs_bsim4_parameter(h,1,"mobmod",7)==CS_BSIM4_PARAMETER);
 CHECK(cs_bsim4_parameter(h,1,"tnoimod",3)==CS_BSIM4_PARAMETER);
 CHECK(cs_bsim4_parameter(h,0,"nf",1e30)==CS_BSIM4_PARAMETER);
 CHECK(cs_bsim4_parameter(h,0,"nf",1.5)==0);
 CHECK(cs_bsim4_parameter(h,0,"u0",.05)==CS_BSIM4_PARAMETER);
 CHECK(cs_bsim4_parameter(h,1,"l",1e-6)==CS_BSIM4_PARAMETER);
 CHECK(cs_bsim4_parameter(h,0,"m",3)==CS_BSIM4_PARAMETER);
 CHECK(cs_bsim4_parameter(h,1,"toxe",0)==0);CSBSIM4Topology t;
 CHECK(cs_bsim4_prepare(h,&t)==CS_BSIM4_PARAMETER);CHECK(cs_bsim4_prepare(h,&t)==CS_BSIM4_PARAMETER);
 cs_bsim4_destroy(h);
 for(int chk=0;chk<2;chk++){CHECK(cs_bsim4_create(1,"4.8.3",300.15,1,&h)==0);CHECK(cs_bsim4_set_stress_budget(h,8)==0);parameter(h,1,"tnoimod",1);parameter(h,1,"paramchk",chk);CHECK(cs_bsim4_prepare(h,&t)==0);CHECK(t.maintainerUnsupportedNoiseMode==1);CHECK(t.drainPrime!=1&&t.sourcePrime!=3);CHECK((strstr(cs_bsim4_diagnostics(h),"TNOIMOD=1")!=NULL)==chk);cs_bsim4_destroy(h);}
 CHECK(cs_bsim4_create(1,"4.8.3",300.15,0,&h)==0);
 CHECK(cs_bsim4_set_stress_budget(h,8)==0);parameter(h,0,"nf",9);parameter(h,0,"sa",1e-6);parameter(h,0,"sb",1e-6);parameter(h,0,"sd",1e-6);
 CHECK(cs_bsim4_prepare(h,&t)==CS_BSIM4_RESOURCE);cs_bsim4_destroy(h);
 CHECK(cs_bsim4_create(1,"4.8.3",300.15,0,&h)==0);CHECK(cs_bsim4_prepare(h,&t)==CS_BSIM4_RESOURCE);cs_bsim4_destroy(h);
 CHECK(cs_bsim4_create(1,"4.8.3",300.15,0,&h)==0);CHECK(cs_bsim4_set_stress_budget(h,8)==0);parameter(h,1,"phin",-2);CHECK(cs_bsim4_prepare(h,&t)==CS_BSIM4_PARAMETER);CHECK(strstr(cs_bsim4_diagnostics(h),"Phi")!=NULL);cs_bsim4_destroy(h);
 puts("PASS CSBSIM4KernelProof/coldAdmission");
}
static void derivatives(void) {
 double points[][3]={{.2,1.2,0},{1.2,1.2,0},{-.3,.9,.12},{1,.2,-.2}};
 for(int p=-1;p<=1;p+=2)for(int kind=0;kind<4;kind++)for(int pt=0;pt<4;pt++) {
  CSBSIM4Topology t;CSBSIM4Handle *h=make(p,kind,pt==3?350.15:300.15,&t);
  CHECK(t.nodeCount==(kind==0?4:kind==1?6:kind==2?11:12));
  double b[13];bias(&t,b,p,points[pt][0],points[pt][1],points[pt][2]);
  CSBSIM4Result r,ac,hi,lo;CHECK(cs_bsim4_evaluate(h,b,0,0,0,0,&r)==0);
  double total=0;for(int row=0;row<13;row++)total+=r.charge[row];CHECK(fabs(total)<1e-24);
  CHECK(cs_bsim4_evaluate(h,b,1,1,0,0,&ac)==0);
  for(int col=1;col<=t.nodeCount;col++) {
   double step=1e-6;double up[13],dn[13];memcpy(up,b,sizeof(b));memcpy(dn,b,sizeof(b));up[col]+=step;dn[col]-=step;
   CHECK(cs_bsim4_evaluate(h,up,0,0,0,0,&hi)==0);CHECK(cs_bsim4_evaluate(h,dn,0,0,0,0,&lo)==0);
   for(int row=1;row<=t.nodeCount;row++) {
    double fd=(hi.residual[row]-lo.residual[row])/(2*step),jac=r.real[row*13+col];
    double products=fabs(hi.rhs[row])+fabs(lo.rhs[row]);for(int term=0;term<13;term++)products+=fabs(hi.real[row*13+term]*up[term])+fabs(lo.real[row*13+term]*dn[term]);
    double residualRoundoff=(32*DBL_EPSILON/(1-32*DBL_EPSILON))*products/(2*step);
    if(fabs(fd-jac)>residualRoundoff+1e-10+2e-4*fmax(fabs(fd),fabs(jac))){fprintf(stderr,"DC p%d kind%d pt%d row%d col%d fd%.12g jac%.12g\n",p,kind,pt,row,col,fd,jac);CHECK(0);}
    if(kind<3){double cfd=(hi.charge[row]-lo.charge[row])/(2*step),cj=ac.imaginary[row*13+col];if(fabs(cfd-cj)>5e-22+2e-4*fmax(fabs(cfd),fabs(cj))){fprintf(stderr,"Q p%d kind%d pt%d row%d col%d fd%.12g jac%.12g\n",p,kind,pt,row,col,cfd,cj);CHECK(0);}}
   }
  }
  cs_bsim4_destroy(h);
 }
 puts("PASS CSBSIM4KernelProof/fullNodeDerivatives");
}
static void transientDerivatives(void) {
 for(int p=-1;p<=1;p+=2)for(int kind=0;kind<4;kind++)for(int mode=2;mode<=3;mode++) {
  CSBSIM4Topology t;CSBSIM4Handle *h=make(p,kind,300.15,&t);double b[13];bias(&t,b,p,1,1.2,0);
  CHECK(cs_bsim4_initialize_history(h,b)==0);CSBSIM4Result center,hi,lo;CHECK(cs_bsim4_evaluate(h,b,mode,0,1e-9,0,&center)==0);
  for(int col=1;col<=t.nodeCount;col++){double up[13],dn[13],step=1e-6;memcpy(up,b,sizeof(b));memcpy(dn,b,sizeof(b));up[col]+=step;dn[col]-=step;
   CHECK(cs_bsim4_evaluate(h,up,mode,0,1e-9,0,&hi)==0);CHECK(cs_bsim4_evaluate(h,dn,mode,0,1e-9,0,&lo)==0);
   for(int row=1;row<=t.nodeCount;row++) {double fd=(hi.residual[row]-lo.residual[row])/(2*step),jac=center.real[row*13+col];double products=fabs(hi.rhs[row])+fabs(lo.rhs[row]);for(int term=0;term<13;term++)products+=fabs(hi.real[row*13+term]*up[term])+fabs(lo.real[row*13+term]*dn[term]);double roundoff=(32*DBL_EPSILON/(1-32*DBL_EPSILON))*products/(2*step);
    if(fabs(fd-jac)>roundoff+1e-10+2e-4*fmax(fabs(fd),fabs(jac))){fprintf(stderr,"TRAN p%d kind%d mode%d row%d col%d fd%.12g jac%.12g\n",p,kind,mode,row,col,fd,jac);CHECK(0);}}
  }cs_bsim4_destroy(h);
 }puts("PASS CSBSIM4KernelProof/transientDerivatives");
}
static void historyAndNumerics(void) {
 for(int k=0;k<4;k++) {
  CSBSIM4Topology t;CSBSIM4Handle *h=make(1,k,300.15,&t);double b[13],old[29],again[29];bias(&t,b,1,1,1.2,0);
  CSBSIM4Result r;memset(&r,0x7f,sizeof(r));CHECK(cs_bsim4_evaluate(h,b,2,0,1e-9,0,&r)==CS_BSIM4_HISTORY);
  CHECK(cs_bsim4_initialize_history(h,b)==0);CHECK(cs_bsim4_accepted_states(h,old)==0);b[2]+=.01;b[t.gatePrime]=b[2];b[t.gateMid]=b[2];
  for(int mode=2;mode<=3;mode++){CHECK(cs_bsim4_evaluate(h,b,mode,0,1e-9,0,&r)==0);CHECK(cs_bsim4_accepted_states(h,again)==0);CHECK(!memcmp(old,again,sizeof(old)));uint64_t token=r.token;double bad[13];memcpy(bad,b,sizeof(bad));bad[2]=NAN;CHECK(cs_bsim4_evaluate(h,bad,mode,0,1e-9,0,&r)==CS_BSIM4_PARAMETER);CHECK(cs_bsim4_commit(h,token)==CS_BSIM4_HISTORY);CHECK(cs_bsim4_evaluate(h,b,mode,0,1e-9,0,&r)==0);CHECK(cs_bsim4_commit(h,r.token)==0);CHECK(cs_bsim4_commit(h,r.token)==CS_BSIM4_HISTORY);CHECK(cs_bsim4_accepted_states(h,old)==0);}
  CSBSIM4Result low,high;CHECK(cs_bsim4_evaluate(h,b,1,1e3,0,0,&low)==0);CHECK(cs_bsim4_evaluate(h,b,1,1e12,0,0,&high)==0);if(k==3)CHECK(fabs(low.real[t.drainPrime*13+t.gatePrime]-high.real[t.drainPrime*13+t.gatePrime])>1e-9);
  double huge[13];memcpy(huge,b,sizeof(b));huge[2]=1e308;CSBSIM4Result untouched;memset(&untouched,0x3a,sizeof(untouched));r=untouched;
  CHECK(cs_bsim4_evaluate(h,huge,0,0,0,0,&r)==CS_BSIM4_NUMERICAL);CHECK(!memcmp(&r,&untouched,sizeof(r)));CHECK(cs_bsim4_accepted_states(h,again)==0);CHECK(!memcmp(old,again,sizeof(old)));
  cs_bsim4_destroy(h);
 }
 puts("PASS CSBSIM4KernelProof/historyAndACNQS");
}
static void chargeMultiplicity(void) {
 for(int p=-1;p<=1;p+=2)for(int direction=0;direction<2;direction++)for(int kind=2;kind<=3;kind++)for(int mode=2;mode<=3;mode++) {
  CSBSIM4Topology t;CSBSIM4Handle *h=makeScaled(p,kind,300.15,1.3,.8,&t);
  double b[13];bias(&t,b,p,direction?-.3:1,direction?.9:1.2,direction?.12:-.1);
  CHECK(cs_bsim4_initialize_history(h,b)==0);double accepted[29],after[29];CHECK(cs_bsim4_accepted_states(h,accepted)==0);
  CSBSIM4Result dc,center,hi,lo;CHECK(cs_bsim4_evaluate(h,b,0,0,0,0,&dc)==0);CHECK(cs_bsim4_evaluate(h,b,mode,0,1e-9,0,&center)==0);
  // Initialized constant bias has dQ/dt=0 at every physical terminal.
  for(int row=1;row<=t.nodeCount;row++)if(row!=t.chargeNode) {
   double difference=fabs(center.residual[row]-dc.residual[row]);
   if(difference>1e-12){fprintf(stderr,"STEADY p%d kind%d mode%d row%d residualDifference%.12g\n",p,kind,mode,row,difference);CHECK(0);}
  }
  for(int col=1;col<=t.nodeCount;col++) {
   double up[13],dn[13],step=1e-6;memcpy(up,b,sizeof(b));memcpy(dn,b,sizeof(b));up[col]+=step;dn[col]-=step;
   CHECK(cs_bsim4_evaluate(h,up,mode,0,1e-9,0,&hi)==0);CHECK(cs_bsim4_evaluate(h,dn,mode,0,1e-9,0,&lo)==0);
   for(int row=1;row<=t.nodeCount;row++) {
    double fd=(hi.residual[row]-lo.residual[row])/(2*step),jac=center.real[row*13+col];
    double products=fabs(hi.rhs[row])+fabs(lo.rhs[row]);for(int term=0;term<13;term++)products+=fabs(hi.real[row*13+term]*up[term])+fabs(lo.real[row*13+term]*dn[term]);
    double roundoff=(32*DBL_EPSILON/(1-32*DBL_EPSILON))*products/(2*step);
    if(fabs(fd-jac)>roundoff+1e-10+2e-4*fmax(fabs(fd),fabs(jac))){fprintf(stderr,"MULT p%d kind%d mode%d dir%d row%d col%d fd%.12g jac%.12g\n",p,kind,mode,direction,row,col,fd,jac);CHECK(0);}
   }
  }
  CHECK(cs_bsim4_accepted_states(h,after)==0);CHECK(!memcmp(accepted,after,sizeof(after)));cs_bsim4_destroy(h);
 }
 puts("PASS CSBSIM4KernelProof/chargeMultiplicity");
}
int main(void){coldAdmission();derivatives();transientDerivatives();historyAndNumerics();chargeMultiplicity();printf("PASS checks=%d\n",checkCount);}
