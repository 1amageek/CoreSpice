#include "CoreSpiceBSIM45.h"
#include "bsim4def.h"
#include <assert.h>
#include <limits.h>
#include <stdio.h>

static CSBSIM45Conditions conditions(void) {
 return (CSBSIM45Conditions){cs_bsim45_owner_size(),100,CS_BSIM45_MAX_DIAGNOSTICS,300.15,300.15,0};
}
static CSBSIM45Owner *make(CSBSIM45Conditions c,int polarity) {
 CSBSIM45Owner *h=NULL;
 assert(cs_bsim45_create("4.5.0",2,polarity,&c,&h)==CS_BSIM45_OK&&h);
 return h;
}
static void model(CSBSIM45Owner *h,int id,int kind,double v){assert(cs_bsim45_set_model(h,id,kind,v)==CS_BSIM45_OK);}
static void instance(CSBSIM45Owner *h,int id,int kind,double v){assert(cs_bsim45_set_instance(h,id,kind,v)==CS_BSIM45_OK);}
static CSBSIM45PreparedInfo prepared(CSBSIM45Owner *h) {
 CSBSIM45PreparedInfo p={0};int status=cs_bsim45_prepare(h);
 if(status) {
  for(size_t n=0;n<cs_bsim45_diagnostic_count(h);n++){CSBSIM45Diagnostic d;cs_bsim45_diagnostic_at(h,n,&d);fprintf(stderr,"%d:%d %s\n",d.sourceSite,d.code,d.text);}
 }
 assert(status==CS_BSIM45_OK);assert(cs_bsim45_prepared_info(h,&p)==CS_BSIM45_OK);return p;
}
static void defaults_and_conditions(void) {
 for(int polarity=-1;polarity<=1;polarity+=2) {
  CSBSIM45Owner *h=make(conditions(),polarity);CSBSIM45PreparedInfo p=prepared(h);
  assert(p.length==5e-6&&p.width==5e-6&&p.fingers==1&&p.ud==1e14);
  assert(p.effectiveLength==5e-6&&p.effectiveWidth==5e-6&&p.stateCount==29&&p.polarity==polarity);
  assert(p.nodeCount==4&&p.drainPrime==1&&p.sourcePrime==3&&p.gatePrime==2&&p.bodyPrime==4&&p.chargeNode==0);
  double vt=1.3806226e-23*300.15/1.6021918e-19;
  assert(fabs(p.criticalVoltage-vt*log(vt/(sqrt(2.0)*1e-14)))<1e-15);
  assert(p.stressIterations==0&&p.nominalKelvin==300.15&&p.ambientKelvin==300.15);
  assert(cs_bsim45_prepare(h)==CS_BSIM45_STATE);
  assert(cs_bsim45_prepared_info(h,&p)==CS_BSIM45_STATE);cs_bsim45_destroy(h);
 }
 CSBSIM45Conditions c=conditions();c.ambientKelvin=350;c.nominalKelvin=310;
 CSBSIM45Owner *h=make(c,1);model(h,BSIM4_MOD_TNOM,CS_BSIM45_REAL,26.85);
 instance(h,BSIM4_W,CS_BSIM45_REAL,6e-6);instance(h,BSIM4_NF,CS_BSIM45_REAL,1.5);
 CSBSIM45PreparedInfo p=prepared(h);assert(p.nominalKelvin==300&&p.ambientKelvin==350&&p.effectiveWidth==4e-6);
 cs_bsim45_destroy(h);
}
static void topology(void) {
 int cases=0,maxnodes=0;
 for(int gate=0;gate<=3;gate++)for(int body=0;body<=2;body++)for(int series=0;series<=1;series++)
 for(int nqs=0;nqs<=1;nqs++)for(int noise=0;noise<=1;noise++) {
  CSBSIM45Conditions c=conditions();c.noiseTopology=noise;CSBSIM45Owner *h=make(c,1);
  model(h,BSIM4_MOD_RGATEMOD,CS_BSIM45_INTEGER,gate);model(h,BSIM4_MOD_RBODYMOD,CS_BSIM45_INTEGER,body);
  model(h,BSIM4_MOD_RDSMOD,CS_BSIM45_INTEGER,series);model(h,BSIM4_MOD_TRNQSMOD,CS_BSIM45_INTEGER,nqs);
  model(h,BSIM4_MOD_TNOIMOD,CS_BSIM45_INTEGER,1);
  CSBSIM45PreparedInfo p=prepared(h);int nodes[]={p.drainPrime,p.sourcePrime,p.gatePrime,p.gateMid,p.bodyPrime,p.drainBody,p.sourceBody,p.chargeNode};
  for(int k=0;k<8;k++)assert(nodes[k]>=0&&nodes[k]<=p.nodeCount);
  assert(p.nodeCount<=12&&p.nodeCount==4+2*(series||noise)+(gate>0)+(gate==3)+3*(body>0)+nqs);
  if(p.nodeCount>maxnodes)maxnodes=p.nodeCount;
  cases++;cs_bsim45_destroy(h);
 }
 assert(maxnodes==12&&cases==96);
 printf("topology_cases=%d max_non_ground_slots=%d\n",cases,maxnodes);
}
static void failures_and_work(void) {
 CSBSIM45Conditions c=conditions();CSBSIM45Owner *h=(void *)1;
 assert(cs_bsim45_create("4.8.3",2,1,&c,&h)==CS_BSIM45_VERSION&&h==NULL);
 assert(cs_bsim45_create("4.5.0",1,1,&c,&h)==CS_BSIM45_SCHEMA&&h==NULL);
 c.maximumOwnerBytes--;assert(cs_bsim45_create("4.5.0",2,1,&c,&h)==CS_BSIM45_RESOURCE&&h==NULL);
 c=conditions();c.maximumDiagnostics=129;assert(cs_bsim45_create("4.5.0",2,1,&c,&h)==CS_BSIM45_RESOURCE&&h==NULL);
 int ids[]={BSIM4_MOD_MOBMOD,BSIM4_MOD_TNOIMOD,BSIM4_MOD_VERSION,BSIM4_MOD_NMOS,INT_MAX};
 double values[]={3,2,4.5,1,1};
 for(int k=0;k<5;k++) {
  h=make(conditions(),1);assert(cs_bsim45_set_model(h,ids[k],CS_BSIM45_INTEGER,values[k])==CS_BSIM45_PARAMETER);
  assert(cs_bsim45_prepare(h)==CS_BSIM45_STATE);cs_bsim45_destroy(h);
 }
 for(int k=0;k<4;k++) {
  h=make(conditions(),1);double values[]={NAN,INFINITY,0,(double)INT_MAX+1};
  assert(cs_bsim45_set_instance(h,BSIM4_NF,CS_BSIM45_REAL,values[k])==CS_BSIM45_PARAMETER);cs_bsim45_destroy(h);
 }
 c=conditions();c.maximumStressIterations=2;
 h=make(c,1);instance(h,BSIM4_NF,CS_BSIM45_REAL,2.5);instance(h,BSIM4_SA,CS_BSIM45_REAL,1e-6);instance(h,BSIM4_SB,CS_BSIM45_REAL,1e-6);instance(h,BSIM4_SD,CS_BSIM45_REAL,1e-6);
 assert(cs_bsim45_prepare(h)==CS_BSIM45_RESOURCE);CSBSIM45PreparedInfo p={.length=123};assert(cs_bsim45_prepared_info(h,&p)==CS_BSIM45_STATE&&p.length==123);cs_bsim45_destroy(h);
 c.maximumStressIterations=3;h=make(c,1);instance(h,BSIM4_NF,CS_BSIM45_REAL,2.5);instance(h,BSIM4_SA,CS_BSIM45_REAL,1e-6);instance(h,BSIM4_SB,CS_BSIM45_REAL,1e-6);instance(h,BSIM4_SD,CS_BSIM45_REAL,1e-6);p=prepared(h);assert(p.stressIterations==3);cs_bsim45_destroy(h);
 c.maximumStressIterations=1;h=make(c,1);instance(h,BSIM4_NF,CS_BSIM45_REAL,1000);p=prepared(h);assert(p.stressIterations==0);cs_bsim45_destroy(h);
 c=conditions();c.ambientKelvin=350;h=make(c,1);model(h,BSIM4_MOD_TEMPMOD,CS_BSIM45_INTEGER,1);assert(cs_bsim45_prepare(h)==CS_BSIM45_KERNEL);cs_bsim45_destroy(h);
 c=conditions();c.maximumDiagnostics=0;h=make(c,1);model(h,BSIM4_MOD_NDEP,CS_BSIM45_REAL,-1);
 assert(cs_bsim45_prepare(h)==CS_BSIM45_KERNEL);assert(cs_bsim45_diagnostic_count(h)==0);cs_bsim45_destroy(h);
 c=conditions();c.maximumDiagnostics=0;h=make(c,1);model(h,BSIM4_MOD_PBS,CS_BSIM45_REAL,0.01);
 assert(cs_bsim45_prepare(h)==CS_BSIM45_DIAGNOSTICS);cs_bsim45_destroy(h);
 h=make(conditions(),1);model(h,BSIM4_MOD_PBS,CS_BSIM45_REAL,0.01);p=prepared(h);assert(p.bulkPotential==0.1&&cs_bsim45_diagnostic_count(h)>0);cs_bsim45_destroy(h);
 h=make(conditions(),1);model(h,BSIM4_MOD_LINT,CS_BSIM45_REAL,1);assert(cs_bsim45_prepare(h)==CS_BSIM45_KERNEL);
 CSBSIM45Diagnostic fatal;assert(cs_bsim45_diagnostic_at(h,0,&fatal)==CS_BSIM45_OK);
 assert(fatal.code==CS_BSIM45_DIAG_FATAL&&fatal.sourceSite==40404);cs_bsim45_destroy(h);
}
static void sc_and_initial_conditions(void) {
 CSBSIM45Owner *h=make(conditions(),1);model(h,BSIM4_MOD_WPEMOD,CS_BSIM45_REAL,1);model(h,BSIM4_MOD_KVTH0WE,CS_BSIM45_REAL,0.2);
 instance(h,BSIM4_SC,CS_BSIM45_REAL,1e-6);double ic[]={0.2,0.3,0.4};assert(cs_bsim45_set_initial_conditions(h,ic,3)==CS_BSIM45_OK);ic[0]=NAN;
 CSBSIM45PreparedInfo p=prepared(h);assert(p.sc==1e-6&&fabs(p.sca-1e-12/(1e-6*(1e-6+5e-6)))<1e-15);double sca=p.sca,threshold=p.threshold;cs_bsim45_destroy(h);
 h=make(conditions(),1);model(h,BSIM4_MOD_WPEMOD,CS_BSIM45_REAL,1);model(h,BSIM4_MOD_KVTH0WE,CS_BSIM45_REAL,0.2);instance(h,BSIM4_SCA,CS_BSIM45_REAL,sca);p=prepared(h);assert(fabs(p.threshold-threshold)<1e-14);cs_bsim45_destroy(h);
}
int main(void) {
 defaults_and_conditions();topology();failures_and_work();sc_and_initial_conditions();
 for(int k=0;k<1000;k++){CSBSIM45Owner *h=make(conditions(),1);prepared(h);cs_bsim45_destroy(h);}
 cs_bsim45_destroy(NULL);puts("BSIM45 preparation proof passed");return 0;
}
