/* This file is compiled twice: once against untouched Berkeley setup/temp/check
   and once against the public production preparation ABI. Both emit receipts;
   the test driver compares values and topology, not console diagnostics. */
#include "CoreSpiceBSIM45.h"
#include "bsim4def.h"
#include <assert.h>
#include <stdio.h>
#ifdef ORIGINAL_REFERENCE
/* Original frontend symbols are confined to this standalone proof process. */
static JOB noiseJob={"Noise Analysis",NULL};
static TSKtask task;
static ReferenceCircuit frontCircuit={&task};
ReferenceCircuit *ft_curckt=&frontCircuit;
static void report_error(int severity,const char *format,IFuid *names) {
 fprintf(stderr,"Original fatal: %s\n",format);
}
static ReferenceFrontend frontend={report_error};
ReferenceFrontend *SPfrontEnd=&frontend;
static BSIM4model m;
static BSIM4instance i;
static CKTcircuit c;
static SMPmatrix matrix;
static void set(int role,int id,int kind,double value) {
 IFvalue v={0};if(kind==CS_BSIM45_REAL)v.rValue=value;else v.iValue=(int)value;
 assert((role?BSIM4mParam(id,&v,(GENmodel*)&m):BSIM4param(id,&v,(GENinstance*)&i,NULL))==0);
}
#else
static CSBSIM45Owner *owner;
static void set(int role,int id,int kind,double value) {
 assert((role?cs_bsim45_set_model(owner,id,kind,value):cs_bsim45_set_instance(owner,id,kind,value))==CS_BSIM45_OK);
}
#endif
int main(void) {
 int number=0;
 for(int polarity=-1;polarity<=1;polarity+=2)for(int mob=0;mob<3;mob++)for(int cap=0;cap<3;cap++)
 for(int diode=0;diode<3;diode++)for(int temp=0;temp<3;temp++)for(int wpe=0;wpe<2;wpe++)for(int hot=0;hot<2;hot++) {
  double ambient=hot?350:300.15;int mode=number%4;
#ifdef ORIGINAL_REFERENCE
  memset(&m,0,sizeof(m));memset(&i,0,sizeof(i));memset(&c,0,sizeof(c));memset(&matrix,0,sizeof(matrix));
  m.BSIM4instances=&i;m.BSIM4modName="Reference";m.BSIM4type=polarity;m.BSIM4typeGiven=1;
  m.BSIM4version="4.5.0";m.BSIM4versionGiven=1;i.BSIM4modPtr=&m;i.BSIM4name="M1";
  i.BSIM4dNode=1;i.BSIM4gNodeExt=2;i.BSIM4sNode=3;i.BSIM4bNode=4;
  c.CKTtemp=ambient;c.CKTnomTemp=300.15;c.nodeCount=4;task.jobs=mode==3?&noiseJob:NULL;
#else
  CSBSIM45Conditions conditions={cs_bsim45_owner_size(),100,128,ambient,300.15,mode==3};
  assert(cs_bsim45_create("4.5.0",2,polarity,&conditions,&owner)==CS_BSIM45_OK);
#endif
  set(1,BSIM4_MOD_MOBMOD,CS_BSIM45_INTEGER,mob);set(1,BSIM4_MOD_CAPMOD,CS_BSIM45_INTEGER,cap);
  set(1,BSIM4_MOD_DIOMOD,CS_BSIM45_INTEGER,diode);set(1,BSIM4_MOD_TEMPMOD,CS_BSIM45_INTEGER,temp);
  set(1,BSIM4_MOD_AT,CS_BSIM45_REAL,0);
  set(1,BSIM4_MOD_WPEMOD,CS_BSIM45_REAL,wpe);set(1,BSIM4_MOD_RGATEMOD,CS_BSIM45_INTEGER,mode);
  set(1,BSIM4_MOD_RBODYMOD,CS_BSIM45_INTEGER,number%3);set(1,BSIM4_MOD_RDSMOD,CS_BSIM45_INTEGER,mode%2);
  set(1,BSIM4_MOD_TNOIMOD,CS_BSIM45_INTEGER,1);set(1,BSIM4_MOD_TRNQSMOD,CS_BSIM45_INTEGER,mode%2);
  set(1,BSIM4_MOD_KU0,CS_BSIM45_REAL,1e-8);set(1,BSIM4_MOD_KVTH0WE,CS_BSIM45_REAL,0.02);
  if(mode) {
   set(0,BSIM4_L,CS_BSIM45_REAL,0.5e-6);set(0,BSIM4_W,CS_BSIM45_REAL,6e-6);
   set(0,BSIM4_NF,CS_BSIM45_REAL,2.5);set(0,BSIM4_SA,CS_BSIM45_REAL,1e-6);
   set(0,BSIM4_SB,CS_BSIM45_REAL,2e-6);set(0,BSIM4_SD,CS_BSIM45_REAL,0.2e-6);set(0,BSIM4_SC,CS_BSIM45_REAL,1e-6);
  }
  CSBSIM45PreparedInfo p={0};
#ifdef ORIGINAL_REFERENCE
  int states=0;assert(BSIM4setup(&matrix,(GENmodel*)&m,&c,&states)==0);assert(BSIM4temp((GENmodel*)&m,&c)==0);
  p.nodeCount=c.nodeCount;p.drainPrime=i.BSIM4dNodePrime;p.sourcePrime=i.BSIM4sNodePrime;p.gatePrime=i.BSIM4gNodePrime;p.gateMid=i.BSIM4gNodeMid;
  p.bodyPrime=i.BSIM4bNodePrime;p.drainBody=i.BSIM4dbNode;p.sourceBody=i.BSIM4sbNode;p.chargeNode=i.BSIM4qNode;
  p.length=i.BSIM4l;p.width=i.BSIM4w;p.fingers=i.BSIM4nf;p.effectiveLength=i.pParam->BSIM4leff;p.effectiveWidth=i.pParam->BSIM4weff;
  p.effectiveCVLength=i.pParam->BSIM4leffCV;p.effectiveCVWidth=i.pParam->BSIM4weffCV;
  p.threshold=i.BSIM4vth0;p.mobility=i.BSIM4u0temp;p.saturationVelocity=i.BSIM4vsattemp;p.nominalKelvin=m.BSIM4tnom;p.ud=m.BSIM4ud;p.sca=i.BSIM4sca;p.criticalVoltage=m.BSIM4vcrit;
#else
  assert(cs_bsim45_prepare(owner)==CS_BSIM45_OK);assert(cs_bsim45_prepared_info(owner,&p)==CS_BSIM45_OK);
#endif
  printf("CASE %d %d %d %d %d %d %d %d %d %d %.17g %.17g %.17g %.17g %.17g %.17g %.17g %.17g %.17g %.17g %.17g %.17g %.17g %.17g\n",
   number++,p.nodeCount,p.drainPrime,p.sourcePrime,p.gatePrime,p.gateMid,p.bodyPrime,p.drainBody,p.sourceBody,p.chargeNode,
   p.length,p.width,p.fingers,p.effectiveLength,p.effectiveWidth,p.effectiveCVLength,p.effectiveCVWidth,p.threshold,p.mobility,p.saturationVelocity,p.nominalKelvin,p.ud,p.sca,p.criticalVoltage);
#ifdef ORIGINAL_REFERENCE
  free(m.pSizeDependParamKnot);
#else
  cs_bsim45_destroy(owner);
#endif
 }
 assert(number==648);return 0;
}
