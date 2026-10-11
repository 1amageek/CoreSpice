/* Original receipts use unmodified QS charge states and original AC stamps at
   omega=1 for the static dQ/dV. Production receipts use only the public ABI.
   The oracle changes no physical formula and shares no production projection. */
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
int NIintegrate(CKTcircuit *ckt,double *g,double *eq,double cap,int q){assert(ckt->CKTag[0]==0);ckt->CKTstate0[q+1]=0;*g=*eq=0;return 0;}
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
static void emit(int id,int point,CSBSIM45StaticResult *out) {
 printf("STATIC %d %d",id,point);
 const double *arrays[]={out->current,out->charge,out->conductance,out->capacitance};int counts[]={13,13,169,169};
 for(int a=0;a<4;a++)for(int n=0;n<counts[a];n++)printf(" %.17g",arrays[a][n]);puts("");
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
  /* QS equilibrium is the oracle for B45-3, not an NQS dynamic approximation. */
  i.BSIM4trnqsMod=0;i.BSIM4acnqsMod=0;
#else
  CSBSIM45Conditions conditions={cs_bsim45_owner_size(),100,128,f.ambient,300.15,0};
  assert(cs_bsim45_create("4.5.0",2,f.polarity,&conditions,&owner)==CS_BSIM45_OK);fixture_parameters(f);
  assert(cs_bsim45_prepare(owner)==CS_BSIM45_OK);assert(cs_bsim45_prepared_info(owner,&p)==CS_BSIM45_OK);
  double bias[13];
#endif
  printf("TOPO %d %d %d %d %d %d %d %d %.17g %.17g\n",id,f.cap,f.gate,p.gatePrime,p.drainPrime,p.sourcePrime,p.bodyPrime,p.gateMid,f.ud,f.ngate);
  for(int point=0;point<STATIC_BIASES;point++) {
   fixture_bias(p,f.polarity,point,bias);CSBSIM45StaticResult result={0};
#ifdef ORIGINAL_REFERENCE
   memset(states[0],0,sizeof(states[0]));memset(&matrix,0,sizeof(matrix));memset(rhs,0,sizeof(rhs));c.CKTgmin=1e-12;c.CKTmode=MODEINITSMSIG;
   #define BIAS(name,pos,neg) states[0][i.BSIM4##name]=f.polarity*(bias[i.BSIM4##pos]-bias[i.BSIM4##neg])
   BIAS(vbd,bNodePrime,dNodePrime);BIAS(vbs,bNodePrime,sNodePrime);BIAS(vgs,gNodePrime,sNodePrime);BIAS(vds,dNodePrime,sNodePrime);
   BIAS(vdbs,dbNode,sNodePrime);BIAS(vdbd,dbNode,dNodePrime);BIAS(vsbs,sbNode,sNodePrime);BIAS(vges,gNodeExt,sNodePrime);BIAS(vgms,gNodeMid,sNodePrime);
   BIAS(vses,sNode,sNodePrime);BIAS(vdes,dNode,sNodePrime);
   #undef BIAS
   assert(BSIM4load((GENmodel*)&m,&c)==0);c.CKTmode=MODEDCOP;memset(&matrix,0,sizeof(matrix));memset(rhs,0,sizeof(rhs));assert(BSIM4load((GENmodel*)&m,&c)==0);
   for(int r=0;r<13;r++){result.current[r]=-rhs[r];for(int col=0;col<13;col++){result.conductance[r*13+col]=matrix.values[r][col][0];result.current[r]+=matrix.values[r][col][0]*bias[col];}}
   result.charge[i.BSIM4gNodePrime]+=f.polarity*states[0][i.BSIM4qg];result.charge[i.BSIM4dNodePrime]+=f.polarity*states[0][i.BSIM4qd];
   result.charge[i.BSIM4sNodePrime]+=f.polarity*states[0][i.BSIM4qs];result.charge[i.BSIM4bNodePrime]+=f.polarity*states[0][i.BSIM4qb];
   if(i.BSIM4rgateMod==3)result.charge[i.BSIM4gNodeMid]+=f.polarity*states[0][i.BSIM4qgmid];
   if(i.BSIM4rbodyMod){result.charge[i.BSIM4dbNode]+=f.polarity*states[0][i.BSIM4qbd];result.charge[i.BSIM4sbNode]+=f.polarity*states[0][i.BSIM4qbs];}
   memset(&matrix,0,sizeof(matrix));c.CKTomega=1;assert(BSIM4acLoad((GENmodel*)&m,&c)==0);
   for(int r=0;r<13;r++)for(int col=0;col<13;col++)result.capacitance[r*13+col]=matrix.values[r][col][1];
#else
   assert(cs_bsim45_evaluate_static(owner,bias,13,1e-12,&result)==CS_BSIM45_OK);
#endif
   emit(id,point,&result);
  }
#ifdef ORIGINAL_REFERENCE
  free(m.pSizeDependParamKnot);
#else
  cs_bsim45_destroy(owner);
#endif
 }
 return 0;
}
