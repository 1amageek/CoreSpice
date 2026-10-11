/* Independent behavioral proof. No original stamp is used to form companion or
   NQS residual expectations. White-box access only measures owner internals and
   separately qualified scalar coefficients, never substitutes for public calls. */
#include <assert.h>
#include <float.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "bsim4def.h"
#include "bsim4ext.h"
static size_t allocations,releases,setups,temperatures;
static void *counted_calloc(size_t n,size_t size){allocations++;return calloc(n,size);}
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
#include "static_fixture.h"
static size_t cells,companions,nqsChecks,historyChecks,perturbations;
static int close_value(double a,double b,double absolute,double relative){return isfinite(a)&&isfinite(b)&&fabs(a-b)<=absolute+relative*fmax(fabs(a),fabs(b));}
static void equal(double a,double b,double absolute,double relative,const char *label,int id,int point,int row,int col){
 if(!close_value(a,b,absolute,relative)){fprintf(stderr,"%s fixture=%d point=%d row=%d col=%d actual=%.17g expected=%.17g\n",label,id,point,row,col,a,b);abort();}
}
static void unchanged(CSBSIM45History before){CSBSIM45History after;assert(cs_bsim45_history(owner,&after)==CS_BSIM45_OK);assert(!memcmp(&before,&after,sizeof(before)));historyChecks++;}
static CSBSIM45TransientResult trial(double bias[13],double deficit,int method,double dt){CSBSIM45TransientResult r;assert(cs_bsim45_evaluate_transient(owner,bias,13,deficit,1e-12,method,dt,&r)==CS_BSIM45_OK);return r;}
static void lifecycle(double bias[13],double deficit,int method,double dt){
 CSBSIM45History before;assert(cs_bsim45_history(owner,&before)==CS_BSIM45_OK);
 CSBSIM45TransientResult a=trial(bias,deficit,method,dt),b=trial(bias,deficit,method,dt);
 assert(!memcmp(a.states,b.states,sizeof(a.states)));assert(!memcmp(a.residual,b.residual,sizeof(a.residual)));assert(!memcmp(a.jacobian,b.jacobian,sizeof(a.jacobian)));
 assert(cs_bsim45_commit(owner,a.token)==CS_BSIM45_HISTORY);unchanged(before);
 CSBSIM45TrialToken forged=b.token;forged.owner++;assert(cs_bsim45_commit(owner,forged)==CS_BSIM45_HISTORY);unchanged(before);
 assert(cs_bsim45_reject(owner,b.token)==CS_BSIM45_OK);assert(cs_bsim45_commit(owner,b.token)==CS_BSIM45_HISTORY);unchanged(before);
 a=trial(bias,deficit,method,dt);CSBSIM45StaticResult s;assert(cs_bsim45_evaluate_static(owner,bias,13,1e-12,&s)==CS_BSIM45_OK);assert(cs_bsim45_commit(owner,a.token)==CS_BSIM45_HISTORY);unchanged(before);
 a=trial(bias,deficit,method,dt);CSBSIM45ACResult ac;assert(cs_bsim45_evaluate_ac(owner,bias,13,1e-12,1e12,&ac)==CS_BSIM45_OK);assert(cs_bsim45_commit(owner,a.token)==CS_BSIM45_HISTORY);unchanged(before);
 a=trial(bias,deficit,method,dt);memset(&b,0x5a,sizeof(b));CSBSIM45TransientResult sentinel=b;
 assert(cs_bsim45_evaluate_transient(owner,bias,13,deficit,1e-12,method,0,&b)==CS_BSIM45_PARAMETER);assert(!memcmp(&b,&sentinel,sizeof(b)));assert(cs_bsim45_commit(owner,a.token)==CS_BSIM45_HISTORY);unchanged(before);
 const double invalid[]={NAN,INFINITY,-1,0,DBL_TRUE_MIN};
 for(int n=0;n<5;n++){assert(cs_bsim45_evaluate_transient(owner,bias,13,deficit,1e-12,method,invalid[n],&b)==CS_BSIM45_PARAMETER);assert(!memcmp(&b,&sentinel,sizeof(b)));unchanged(before);}
 a=trial(bias,deficit,method,dt);assert(cs_bsim45_evaluate_ac(owner,bias,13,1e-12,NAN,&ac)==CS_BSIM45_PARAMETER);assert(cs_bsim45_commit(owner,a.token)==CS_BSIM45_HISTORY);unchanged(before);
 a=trial(bias,deficit,method,dt);assert(cs_bsim45_initialize_history(owner,bias,12,1e-12)==CS_BSIM45_PARAMETER);assert(cs_bsim45_commit(owner,a.token)==CS_BSIM45_HISTORY);unchanged(before);
}
static void extrinsic_charge(CSBSIM45StaticResult r,CSBSIM45PreparedInfo p,double out[13]) {
 memcpy(out,r.charge,13*sizeof(double));BSIM4instance *i=&owner->instance;
 int d=i->BSIM4mode>0?p.drainPrime:p.sourcePrime,s=i->BSIM4mode>0?p.sourcePrime:p.drainPrime;
 out[p.gatePrime]-=p.polarity*i->BSIM4qgate;out[p.bodyPrime]-=p.polarity*i->BSIM4qbulk;
 out[d]-=p.polarity*i->BSIM4qdrn;out[s]-=p.polarity*i->BSIM4qsrc;
}
static void nqs_companion(CSBSIM45TransientResult r,CSBSIM45StaticResult equilibrium,CSBSIM45PreparedInfo p,
 double previousCharge[13],double previousCurrent[13],double deficit,int method,double coefficient,int id,int point) {
 BSIM4instance *i=&owner->instance;double charge[13];extrinsic_charge(equilibrium,p,charge);
 double qeq=i->BSIM4qchqs,area=owner->model.BSIM4coxe*i->pParam->BSIM4weffCV*i->BSIM4nf*i->pParam->BSIM4leffCV;
 double partition=fabs(qeq)<=1e-5*area?(owner->model.BSIM4xpart<0.5?0.4:owner->model.BSIM4xpart>0.5?0:0.5):i->BSIM4qdrn/qeq;
 if(i->BSIM4mode<0)partition=1-partition;
 double weights[13]={0};weights[p.gatePrime]=-1;weights[p.drainPrime]=partition;weights[p.sourcePrime]=1-partition;
 for(int row=0;row<13;row++){
  if(row==p.chargeNode)continue;
  double current=coefficient*(charge[row]-previousCharge[row])-(method==2?previousCurrent[row]:0);
  double expected=equilibrium.current[row]+current+weights[row]*deficit*i->BSIM4gtau;
  equal(r.residual[row],expected,1e-12,2e-6,"NQS physical companion",id,point,row,0);
  equal(r.jacobian[row*13+p.chargeNode],weights[row]*i->BSIM4gtau,1e-12,2e-6,"NQS partition coefficient",id,point,row,p.chargeNode);
  previousCharge[row]=charge[row];previousCurrent[row]=current;companions++;
 }
 equal(r.jacobian[p.chargeNode*13+p.chargeNode],1e-9*coefficient+i->BSIM4gtau,1e-12,2e-6,"NQS deficit coefficient",id,point,p.chargeNode,p.chargeNode);
}
static void integration_convergence(void) {
 for(int method=1;method<=2;method++){
  double errors[3];
  for(int refinement=0;refinement<3;refinement++){
   int count=32<<refinement;double states[3][29]={0},dt=1e-9/count,voltage=0;
   CKTcircuit c={0};c.CKTmode=MODETRAN;c.CKTstate0=states[0];c.CKTstate1=states[1];
   for(int step=0;step<count;step++){
    c.integrationMethod=step==0?CS_BSIM45_BE:method;c.CKTag[0]=(c.integrationMethod==CS_BSIM45_BE?1.:2.)/dt;
    double g,eq;states[0][11]=0;assert(NIintegrate(&c,&g,&eq,1e-12,11)==OK);
    voltage=(1e-3-eq)/(1e-3+g);states[0][11]=voltage*1e-12;
    assert(NIintegrate(&c,&g,&eq,1e-12,11)==OK);memcpy(states[1],states[0],sizeof(states[0]));
   }
   errors[refinement]=fabs(voltage-(1-exp(-1.)));
  }
  for(int n=0;n<2;n++){double ratio=errors[n]/errors[n+1];assert(method==1?(ratio>1.8&&ratio<2.2):(ratio>3.7&&ratio<4.3));}
  printf("RC method=%d error32=%.17g error64=%.17g error128=%.17g\n",method,errors[0],errors[1],errors[2]);
 }
}
static void integration_admission(void) {
 double states[3][29]={0};CKTcircuit c={0};c.CKTmode=MODETRAN;
 c.integrationMethod=CS_BSIM45_BE;c.CKTag[0]=1e10;c.CKTstate0=states[0];c.CKTstate1=states[1];
 for(int slot=-1;slot<=30;slot++){
  if(slot>=11&&slot<=25&&(slot&1))continue;
  double g=17,eq=19;double before[29];memcpy(before,states[0],sizeof(before));
  assert(NIintegrate(&c,&g,&eq,1e-12,slot)==E_BADPARM);
  assert(g==17&&eq==19&&!memcmp(before,states[0],sizeof(before)));
 }
 double g=17,eq=19;states[0][11]=DBL_MAX;states[0][12]=23;
 assert(NIintegrate(&c,&g,&eq,1e-12,11)==E_NONFINITE);assert(g==17&&eq==19&&states[0][12]==23);
 states[0][11]=0;c.integrationMethod=0;assert(NIintegrate(&c,&g,&eq,1e-12,11)==E_BADPARM);
 c.integrationMethod=CS_BSIM45_BE;c.CKTag[0]=NAN;assert(NIintegrate(&c,&g,&eq,1e-12,11)==E_BADPARM);
 c.CKTag[0]=1e10;assert(NIintegrate(&c,&g,&eq,NAN,11)==E_BADPARM);
 assert(g==17&&eq==19&&states[0][12]==23);
}
static void invalid_requests(double bias[13]) {
 CSBSIM45History before;assert(cs_bsim45_history(owner,&before)==CS_BSIM45_OK);
 CSBSIM45TransientResult out,sentinel;memset(&sentinel,0x5a,sizeof(sentinel));out=sentinel;
 double bad[13];memcpy(bad,bias,sizeof(bad));bad[0]=1;
 #define REFUSE(request) do { \
  CSBSIM45TransientResult valid=trial(bias,0,CS_BSIM45_BE,1e-10); \
  assert((request)==CS_BSIM45_PARAMETER); \
  assert(cs_bsim45_commit(owner,valid.token)==CS_BSIM45_HISTORY); \
  assert(!memcmp(&out,&sentinel,sizeof(out)));unchanged(before); \
 } while(0)
 REFUSE(cs_bsim45_evaluate_transient(owner,bias,13,0,1e-12,0,1e-10,&out));
 REFUSE(cs_bsim45_evaluate_transient(owner,bias,13,0,1e-12,3,1e-10,&out));
 REFUSE(cs_bsim45_evaluate_transient(owner,bias,13,NAN,1e-12,CS_BSIM45_BE,1e-10,&out));
 REFUSE(cs_bsim45_evaluate_transient(owner,bias,13,0,NAN,CS_BSIM45_BE,1e-10,&out));
 REFUSE(cs_bsim45_evaluate_transient(owner,bias,13,0,-1,CS_BSIM45_BE,1e-10,&out));
 REFUSE(cs_bsim45_evaluate_transient(owner,bias,12,0,1e-12,CS_BSIM45_BE,1e-10,&out));
 REFUSE(cs_bsim45_evaluate_transient(owner,NULL,13,0,1e-12,CS_BSIM45_BE,1e-10,&out));
 REFUSE(cs_bsim45_evaluate_transient(owner,bias,13,0,1e-12,CS_BSIM45_BE,1e-10,NULL));
 REFUSE(cs_bsim45_evaluate_transient(owner,bad,13,0,1e-12,CS_BSIM45_BE,1e-10,&out));
 bad[0]=0;bad[1]=NAN;
 REFUSE(cs_bsim45_evaluate_transient(owner,bad,13,0,1e-12,CS_BSIM45_BE,1e-10,&out));
 #undef REFUSE
 assert(cs_bsim45_evaluate_transient(NULL,bias,13,0,1e-12,CS_BSIM45_BE,1e-10,&out)==CS_BSIM45_PARAMETER);
 assert(!memcmp(&out,&sentinel,sizeof(out)));unchanged(before);
}
static void additional_lifecycle(void) {
 CSBSIM45Owner *owners[2];CSBSIM45PreparedInfo infos[2];double biases[2][13];
 for(int n=0;n<2;n++){
  StaticFixture f=fixture(48+n);CSBSIM45Conditions conditions={cs_bsim45_owner_size(),100,128,f.ambient,300.15,0};
  assert(cs_bsim45_create("4.5.0",2,f.polarity,&conditions,&owner)==CS_BSIM45_OK);fixture_parameters(f);assert(cs_bsim45_prepare(owner)==CS_BSIM45_OK);
  assert(cs_bsim45_prepared_info(owner,&infos[n])==CS_BSIM45_OK);fixture_bias(infos[n],f.polarity,0,biases[n]);assert(cs_bsim45_initialize_history(owner,biases[n],13,1e-12)==CS_BSIM45_OK);owners[n]=owner;
 }
 CSBSIM45TransientResult trials[2];
 for(int n=0;n<2;n++){owner=owners[n];trials[n]=trial(biases[n],1e-6,CS_BSIM45_BE,1e-10);}
 assert(trials[0].token.generation==trials[1].token.generation);
 for(int n=0;n<2;n++){
  owner=owners[n];CSBSIM45History before;assert(cs_bsim45_history(owner,&before)==CS_BSIM45_OK);
  assert(cs_bsim45_commit(owner,trials[1-n].token)==CS_BSIM45_HISTORY);unchanged(before);assert(cs_bsim45_commit(owner,trials[n].token)==CS_BSIM45_OK);
 }
 owner=owners[0];invalid_requests(biases[0]);CSBSIM45TransientResult sentinel;memset(&sentinel,0x5a,sizeof(sentinel));CSBSIM45TransientResult out=sentinel;
 CSBSIM45History before;assert(cs_bsim45_history(owner,&before)==CS_BSIM45_OK);owner->trialGeneration=UINT64_MAX;
 assert(cs_bsim45_evaluate_transient(owner,biases[0],13,0,1e-12,CS_BSIM45_BE,1e-10,&out)==CS_BSIM45_RESOURCE);assert(!memcmp(&out,&sentinel,sizeof(out)));unchanged(before);
 owner->trialGeneration=2;double bad[13];memcpy(bad,biases[0],sizeof(bad));bad[infos[0].gatePrime]=DBL_MAX;
 assert(cs_bsim45_evaluate_transient(owner,bad,13,0,1e-12,CS_BSIM45_BE,1e-10,&out)==CS_BSIM45_NONFINITE);assert(!memcmp(&out,&sentinel,sizeof(out)));unchanged(before);assert(owner->state==-1);
 cs_bsim45_destroy(owner);
 owner=owners[1];CSBSIM45TransientResult old=trial(biases[1],1e-6,CS_BSIM45_TRAPEZOIDAL,1e-10);
 assert(cs_bsim45_initialize_history(owner,biases[1],13,1e-12)==CS_BSIM45_OK);assert(cs_bsim45_commit(owner,old.token)==CS_BSIM45_HISTORY);
 assert(cs_bsim45_history(owner,&before)==CS_BSIM45_OK);for(int n=12;n<=26;n+=2)assert(before.accepted[n]==0);assert(!memcmp(before.accepted,before.older,sizeof(before.accepted)));
 for(int method=1;method<=2;method++){
  double errors[3];for(int refinement=0;refinement<3;refinement++){
   int count=16<<refinement;assert(cs_bsim45_initialize_history(owner,biases[1],13,1e-12)==CS_BSIM45_OK);
   CSBSIM45StaticResult stat;assert(cs_bsim45_evaluate_static(owner,biases[1],13,1e-12,&stat)==CS_BSIM45_OK);double q0=owner->instance.BSIM4qchqs;
   double finalBias[13];fixture_bias(infos[1],1,5,finalBias);assert(cs_bsim45_evaluate_static(owner,finalBias,13,1e-12,&stat)==CS_BSIM45_OK);
   double q1=owner->instance.BSIM4qchqs,tau=1e-9/owner->instance.BSIM4gtau,dt=tau/count;
   CSBSIM45TransientResult result;
   for(int step=0;step<count;step++){
    int integration=step==0?CS_BSIM45_BE:method;result=trial(finalBias,0,integration,dt);double coordinate=-result.residual[infos[1].chargeNode]/result.jacobian[infos[1].chargeNode*13+infos[1].chargeNode];
    result=trial(finalBias,coordinate,integration,dt);equal(result.residual[infos[1].chargeNode],0,1e-12,0,"NQS solved deficit",-1,step,0,0);assert(cs_bsim45_commit(owner,result.token)==CS_BSIM45_OK);
   }
   errors[refinement]=fabs(result.states[25]/(q1-q0)-exp(-1.));
  }
  for(int n=0;n<2;n++){double ratio=errors[n]/errors[n+1];assert(method==1?(ratio>1.8&&ratio<2.2):(ratio>3.7&&ratio<4.3));}
  printf("NQS_SOLVE method=%d error16=%.17g error32=%.17g error64=%.17g\n",method,errors[0],errors[1],errors[2]);
 }
 cs_bsim45_destroy(owner);
}
static void conservation(CSBSIM45TransientResult r,CSBSIM45PreparedInfo p,int id,int point){
 double sum=0,norm=0;for(int row=0;row<13;row++)if(!p.chargeNode||row!=p.chargeNode){sum+=r.residual[row];norm+=fabs(r.residual[row]);}
 equal(sum,0,2e-15+256*DBL_EPSILON*norm,0,"KCL",id,point,0,0);
 for(int col=0;col<13;col++){sum=norm=0;for(int row=0;row<13;row++)if(!p.chargeNode||row!=p.chargeNode){sum+=r.jacobian[row*13+col];norm+=fabs(r.jacobian[row*13+col]);}equal(sum,0,2e-15+256*DBL_EPSILON*norm,0,"column conservation",id,point,0,col);}
 for(int row=0;row<13;row++){sum=norm=0;for(int col=0;col<13;col++)if(!p.chargeNode||col!=p.chargeNode){sum+=r.jacobian[row*13+col];norm+=fabs(r.jacobian[row*13+col]);}equal(sum,0,2e-15+256*DBL_EPSILON*norm,0,"gauge",id,point,row,0);}
}
/* Differentiate dynamic charge/deficit contributions separately from static I.
   Static G is independently qualified by verify_static.py. Constant history
   terms have zero voltage derivative; neither a 9 A junction current nor a
   previous TR companion may set the precision of a 1e-7 S dynamic derivative. */
static void dynamic_vector(CSBSIM45TransientResult r,CSBSIM45PreparedInfo p,double deficit,double coefficient,double out[13]) {
 memset(out,0,13*sizeof(double));double sign=p.polarity;
 out[p.bodyPrime]+=sign*coefficient*r.states[11];out[p.gatePrime]+=sign*coefficient*r.states[13];
 out[p.drainPrime]+=sign*coefficient*r.states[15];out[p.sourcePrime]+=sign*coefficient*r.states[28];
 if(owner->instance.BSIM4rgateMod==3)out[p.gateMid]+=sign*coefficient*r.states[17];
 if(owner->instance.BSIM4rbodyMod){out[p.sourceBody]+=sign*coefficient*r.states[19];out[p.drainBody]+=sign*coefficient*r.states[21];}
 if(p.chargeNode){
  for(int row=0;row<13;row++)if(row!=p.chargeNode)out[row]+=deficit*r.jacobian[row*13+p.chargeNode];
  out[p.chargeNode]=-sign*coefficient*r.states[23]+deficit*r.jacobian[p.chargeNode*13+p.chargeNode];
 }
}
static void differences(double bias[13],double deficit,int method,double dt,CSBSIM45PreparedInfo p,int id,int point,int compact){
 CSBSIM45StaticResult stat;assert(cs_bsim45_evaluate_static(owner,bias,13,1e-12,&stat)==CS_BSIM45_OK);
 CSBSIM45TransientResult center=trial(bias,deficit,method,dt);CSBSIM45History before;assert(cs_bsim45_history(owner,&before)==CS_BSIM45_OK);
 double pclm=owner->geometry.BSIM4pclm;
 /* Original VDS=0 selects CLM-disabled diffVds<=1e-10. The local extension
    keeps only that predicate fixed; its center must remain byte-identical. */
 if(point==6&&p.chargeNode){
  owner->geometry.BSIM4pclm=0;CSBSIM45TransientResult branch=trial(bias,deficit,method,dt);
  assert(!memcmp(center.residual,branch.residual,sizeof(branch.residual)));
  assert(!memcmp(center.jacobian,branch.jacobian,sizeof(branch.jacobian)));
  assert(!memcmp(center.states,branch.states,sizeof(branch.states)));
 }
 double coefficient=(method==1?1.:2.)/dt,base[13];dynamic_vector(center,p,deficit,coefficient,base);
 for(int col=1;col<=p.nodeCount;col++){
  if(compact&&col!=p.gatePrime&&col!=p.chargeNode)continue;
  int passed[13]={0};const double steps[]={1e-2,3e-3,1e-3,3e-4,1e-4,1e-5,1e-6};
  for(size_t k=0;k<sizeof(steps)/sizeof(steps[0]);k++){
   double step=steps[k]*(col==p.chargeNode?1e-3:1),old=bias[col],vectors[4][13];
   int direction=point==6&&col==p.drainPrime?owner->model.BSIM4type:point==6&&col==p.sourcePrime?-owner->model.BSIM4type:0;
   for(int sample=0;sample<4;sample++){
    double offset=direction?direction*(sample+1):sample<2?-(sample+1):sample-1,coordinate=deficit;
    CSBSIM45TransientResult r;
    if(col==p.chargeNode){coordinate+=offset*step;r=trial(bias,coordinate,method,dt);}
    else {bias[col]=old+offset*step;r=trial(bias,coordinate,method,dt);bias[col]=old;}
    dynamic_vector(r,p,coordinate,coefficient,vectors[sample]);
   }
   perturbations+=4;
   for(int row=0;row<13;row++){
    double fd=direction?(48*((long double)vectors[0][row]-base[row])-36*((long double)vectors[1][row]-base[row])+16*((long double)vectors[2][row]-base[row])-3*((long double)vectors[3][row]-base[row]))/(12*direction*step):
     (((long double)vectors[1][row]-vectors[3][row])+8*((long double)vectors[2][row]-vectors[0][row]))/(12*step);
    double expected=center.jacobian[row*13+col]-stat.conductance[row*13+col];
    int good=close_value(expected,fd,1e-10,2e-4);
    if(good&&passed[row])passed[row]=2;else if(passed[row]!=2)passed[row]=good;
   }
  }
  for(int row=0;row<13;row++)if(passed[row]!=2){fprintf(stderr,"Dynamic FD fixture=%d point=%d method=%d row=%d col=%d J=%.17g\n",id,point,method,row,col,center.jacobian[row*13+col]-stat.conductance[row*13+col]);abort();}else cells++;
 }
 owner->geometry.BSIM4pclm=pclm;unchanged(before);
}

int main(int argc,char **argv){
 int end=argc>1?atoi(argv[1]):580,compact=argc>2;
 for(int id=0;id<end;id++){
  StaticFixture f=fixture(id);CSBSIM45Conditions conditions={cs_bsim45_owner_size(),100,128,f.ambient,300.15,0};
  assert(cs_bsim45_create("4.5.0",2,f.polarity,&conditions,&owner)==CS_BSIM45_OK);fixture_parameters(f);assert(cs_bsim45_prepare(owner)==CS_BSIM45_OK);
  CSBSIM45PreparedInfo p;assert(cs_bsim45_prepared_info(owner,&p)==CS_BSIM45_OK);double bias[13];fixture_bias(p,f.polarity,0,bias);
  CSBSIM45TransientResult uninitialized;assert(cs_bsim45_evaluate_transient(owner,bias,13,0,1e-12,CS_BSIM45_BE,1e-10,&uninitialized)==CS_BSIM45_HISTORY);
  for(int method=1;method<=2;method++){
   fixture_bias(p,f.polarity,0,bias);assert(cs_bsim45_initialize_history(owner,bias,13,1e-12)==CS_BSIM45_OK);
   CSBSIM45History initial;assert(cs_bsim45_history(owner,&initial)==CS_BSIM45_OK);assert(!memcmp(initial.accepted,initial.older,sizeof(initial.accepted)));
   CSBSIM45StaticResult previous;assert(cs_bsim45_evaluate_static(owner,bias,13,1e-12,&previous)==CS_BSIM45_OK);
   double previousCurrent[13]={0},previousExtrinsic[13];extrinsic_charge(previous,p,previousExtrinsic);
   for(int point=1;point<7;point++){
    fixture_bias(p,f.polarity,point,bias);double dt=point%3==0?1e-10:point%3==1?2e-10:5e-11,deficit=f.nqs?f.polarity*point*1e-6:0;
    lifecycle(bias,deficit,method,dt);
    CSBSIM45StaticResult equilibrium;assert(cs_bsim45_evaluate_static(owner,bias,13,1e-12,&equilibrium)==CS_BSIM45_OK);
    CSBSIM45TransientResult r=trial(bias,deficit,method,dt);
    if(f.nqs)nqs_companion(r,equilibrium,p,previousExtrinsic,previousCurrent,deficit,method,(method==1?1.:2.)/dt,id,point);
    conservation(r,p,id,point);
    double coefficient=(method==1?1.:2.)/dt;
    if(!f.nqs){for(int row=0;row<13;row++){
     double displacement=coefficient*(equilibrium.charge[row]-previous.charge[row])-(method==2?previousCurrent[row]:0);
     equal(r.residual[row],equilibrium.current[row]+displacement,1e-12,2e-6,"QS companion",id,point,row,0);companions++;previousCurrent[row]=displacement;
     for(int col=0;col<13;col++)equal(r.jacobian[row*13+col],equilibrium.conductance[row*13+col]+coefficient*equilibrium.capacitance[row*13+col],1e-10,2e-6,"QS derivative",id,point,row,col);
    }}else {
     /* Independent lumped relaxation equation: dQdef/dt + Qdef/tau
        - dQequilibrium/dt, with the original fixed coordinate scale. */
     double physicalDeficit=f.polarity*deficit*1e-9;
     CSBSIM45History accepted;assert(cs_bsim45_history(owner,&accepted)==CS_BSIM45_OK);
     double qdot=coefficient*(physicalDeficit-accepted.accepted[25])-(method==2?accepted.accepted[26]:0);
     double qeq=owner->instance.BSIM4qchqs;
     double eqdot=coefficient*(qeq-accepted.accepted[23])-(method==2?accepted.accepted[24]:0);
     double expected=f.polarity*(qdot+physicalDeficit*owner->instance.BSIM4gtau/1e-9-eqdot);
     equal(r.residual[p.chargeNode],expected,1e-12,2e-6,"NQS relaxation",id,point,p.chargeNode,0);nqsChecks++;
    }
    differences(bias,deficit,method,dt,p,id,point,compact);
    CSBSIM45History before,after;assert(cs_bsim45_history(owner,&before)==CS_BSIM45_OK);r=trial(bias,deficit,method,dt);
    assert(cs_bsim45_commit(owner,r.token)==CS_BSIM45_OK);assert(cs_bsim45_history(owner,&after)==CS_BSIM45_OK);
    assert(!memcmp(after.older,before.accepted,sizeof(after.older)));assert(!memcmp(after.accepted,r.states,sizeof(after.accepted)));
    assert(cs_bsim45_commit(owner,r.token)==CS_BSIM45_HISTORY);unchanged(after);previous=equilibrium;
   }
  }
  cs_bsim45_destroy(owner);
 }
 integration_admission();integration_convergence();additional_lifecycle();
 assert(allocations==(size_t)end+2&&releases==allocations&&setups==allocations&&temperatures==allocations);
 printf("PASS owners=%zu releases=%zu setups=%zu temperatures=%zu FDcells=%zu perturbations=%zu QScompanions=%zu NQS=%zu history=%zu ownerBytes=%zu\n",allocations,releases,setups,temperatures,cells,perturbations,companions,nqsChecks,historyChecks,cs_bsim45_owner_size());
 return 0;
}
