/* Original raw transient oracle and public-ABI production receipts. */
#include "CoreSpiceBSIM45.h"
#include "bsim4def.h"
#include <assert.h>
#include <stdio.h>
#ifdef ORIGINAL_REFERENCE
static TSKtask task;
static ReferenceCircuit frontCircuit={&task};ReferenceCircuit *ft_curckt=&frontCircuit;
static void report_error(int severity,const char *format,IFuid *names){assert(0);}
static ReferenceFrontend frontend={report_error};ReferenceFrontend *SPfrontEnd=&frontend;
static BSIM4model m;static BSIM4instance i;static CKTcircuit c;static SMPmatrix matrix;
static double states[3][29],rhs[13],bias[13];
static void set(int role,int id,int kind,double value) {
 IFvalue v={0};if(kind==CS_BSIM45_REAL)v.rValue=value;else v.iValue=(int)value;
 assert((role?BSIM4mParam(id,&v,(GENmodel*)&m):BSIM4param(id,&v,(GENinstance*)&i,NULL))==0);
}
extern int BSIM4acLoad(GENmodel *,CKTcircuit *);
#else
static CSBSIM45Owner *owner;
static void set(int role,int id,int kind,double value){assert((role?cs_bsim45_set_model(owner,id,kind,value):cs_bsim45_set_instance(owner,id,kind,value))==CS_BSIM45_OK);}
#endif
#include "static_fixture.h"
static void emit(int id,int point,CSBSIM45TransientResult *out) {
 printf("TRAN %d %d",id,point);
 const double *arrays[]={out->residual,out->jacobian,out->states};int counts[]={13,169,29};
 for(int a=0;a<3;a++)for(int n=0;n<counts[a];n++)printf(" %.17g",arrays[a][n]);puts("");
}
int main(int argc,char **argv) {
 int end=argc>1?atoi(argv[1]):STATIC_FIXTURES;
 for(int id=0;id<end;id++) {
  StaticFixture f=fixture(id);CSBSIM45PreparedInfo p={0};
#ifdef ORIGINAL_REFERENCE
  memset(&m,0,sizeof(m));memset(&i,0,sizeof(i));memset(&c,0,sizeof(c));memset(&matrix,0,sizeof(matrix));memset(states,0,sizeof(states));
  m.BSIM4instances=&i;m.BSIM4modName="Reference";m.BSIM4type=f.polarity;m.BSIM4typeGiven=1;m.BSIM4version="4.5.0";m.BSIM4versionGiven=1;
  i.BSIM4modPtr=&m;i.BSIM4name="M1";i.BSIM4dNode=1;i.BSIM4gNodeExt=2;i.BSIM4sNode=3;i.BSIM4bNode=4;
  c.nodeCount=4;c.CKTtemp=f.ambient;c.CKTnomTemp=300.15;c.CKTstate0=states[0];c.CKTstate1=states[1];c.CKTstate2=states[2];c.CKTstates[0]=states[0];c.CKTstates[1]=states[1];c.CKTstates[2]=states[2];c.CKTrhs=rhs;c.CKTrhsOld=bias;
  fixture_parameters(f);int nstates=0;assert(BSIM4setup(&matrix,(GENmodel*)&m,&c,&nstates)==0);assert(BSIM4temp((GENmodel*)&m,&c)==0);
  p.nodeCount=c.nodeCount;p.drainPrime=i.BSIM4dNodePrime;p.sourcePrime=i.BSIM4sNodePrime;p.gatePrime=i.BSIM4gNodePrime;p.gateMid=i.BSIM4gNodeMid;
  p.bodyPrime=i.BSIM4bNodePrime;p.drainBody=i.BSIM4dbNode;p.sourceBody=i.BSIM4sbNode;p.chargeNode=i.BSIM4qNode;
#else
  CSBSIM45Conditions conditions={cs_bsim45_owner_size(),100,128,f.ambient,300.15,0};
  assert(cs_bsim45_create("4.5.0",2,f.polarity,&conditions,&owner)==CS_BSIM45_OK);fixture_parameters(f);
  assert(cs_bsim45_prepare(owner)==CS_BSIM45_OK);assert(cs_bsim45_prepared_info(owner,&p)==CS_BSIM45_OK);
  double bias[13];
#endif
  printf("TOPO %d %d %d %d %d %d %d %d %.17g %.17g %d\n",id,f.cap,f.gate,p.gatePrime,p.drainPrime,p.sourcePrime,p.bodyPrime,p.gateMid,f.ud,f.ngate,p.chargeNode);
  for(int method=1;method<=2;method++)for(int point=0;point<STATIC_BIASES;point++) {
   fixture_bias(p,f.polarity,point,bias);CSBSIM45TransientResult result={0};
   double dt=point%3==0?1e-10:point%3==1?2e-10:5e-11;double deficit=f.nqs&&point?f.polarity*point*1e-6:0;
#ifdef ORIGINAL_REFERENCE
   if(point==0){memset(states[0],0,sizeof(states[0]));c.CKTag[0]=0;c.CKTintegrateMethod=TRAPEZOIDAL;c.CKTorder=1;c.CKTag[1]=0;}
   memset(&matrix,0,sizeof(matrix));memset(rhs,0,sizeof(rhs));c.CKTgmin=1e-12;c.CKTmode=point==0?MODEINITSMSIG:MODETRAN;
   if(point==0){
   #define BIAS(name,pos,neg) states[0][i.BSIM4##name]=f.polarity*(bias[i.BSIM4##pos]-bias[i.BSIM4##neg])
   BIAS(vbd,bNodePrime,dNodePrime);BIAS(vbs,bNodePrime,sNodePrime);BIAS(vgs,gNodePrime,sNodePrime);BIAS(vds,dNodePrime,sNodePrime);
   BIAS(vdbs,dbNode,sNodePrime);BIAS(vdbd,dbNode,dNodePrime);BIAS(vsbs,sbNode,sNodePrime);BIAS(vges,gNodeExt,sNodePrime);BIAS(vgms,gNodeMid,sNodePrime);
   BIAS(vses,sNode,sNodePrime);BIAS(vdes,dNode,sNodePrime);
   #undef BIAS
   } else {bias[p.chargeNode]=deficit;c.CKTorder=method;c.CKTag[0]=(method==1?1.:2.)/dt;c.CKTag[1]=method==1?-c.CKTag[0]:1;}
   assert(BSIM4load((GENmodel*)&m,&c)==0);
   if(point==0){c.CKTmode=MODEDCOP;memset(&matrix,0,sizeof(matrix));memset(rhs,0,sizeof(rhs));assert(BSIM4load((GENmodel*)&m,&c)==0);}
   for(int r=0;r<13;r++){result.residual[r]=-rhs[r];for(int col=0;col<13;col++){result.jacobian[r*13+col]=matrix.values[r][col][0];result.residual[r]+=matrix.values[r][col][0]*bias[col];}}
   memcpy(result.states,states[0],sizeof(result.states));memcpy(states[2],states[1],sizeof(states[2]));memcpy(states[1],states[0],sizeof(states[1]));
#else
   if(point==0){assert(cs_bsim45_initialize_history(owner,bias,13,1e-12)==CS_BSIM45_OK);CSBSIM45History history;assert(cs_bsim45_history(owner,&history)==CS_BSIM45_OK);memcpy(result.states,history.accepted,sizeof(result.states));}
   else {assert(cs_bsim45_evaluate_transient(owner,bias,13,deficit,1e-12,method,dt,&result)==CS_BSIM45_OK);assert(cs_bsim45_commit(owner,result.token)==CS_BSIM45_OK);}
#endif
   if(point)emit(id,method*10+point,&result);
  }
#ifdef ORIGINAL_REFERENCE
  free(m.pSizeDependParamKnot);
#else
  cs_bsim45_destroy(owner);
#endif
 }
 return 0;
}
