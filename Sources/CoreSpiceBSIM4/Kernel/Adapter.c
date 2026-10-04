#include "../include/CoreSpiceBSIM4.h"
#include "bsim4def.h"
#include <limits.h>

extern const IFparm BSIM4pTable[],BSIM4mPTable[];
extern const int BSIM4pTSize,BSIM4mPTSize;
extern int BSIM4setup(SMPmatrix *,GENmodel *,CKTcircuit *,int *);
extern int BSIM4temp(GENmodel *,CKTcircuit *);
extern int BSIM4load(GENmodel *,CKTcircuit *);
extern int BSIM4acLoad(GENmodel *,CKTcircuit *);
extern int BSIM4param(int,IFvalue *,GENinstance *,IFvalue *);
extern int BSIM4mParam(int,IFvalue *,GENmodel *);

/* One allocation owns every mutable object. Original matrix-element pointers
   borrow its embedded matrix until serialized, exactly-once destruction. */
struct CSBSIM4Handle {
 BSIM4model model; BSIM4instance instance; struct bsim4SizeDependParam geometry;
 CKTcircuit circuit; SMPmatrix matrix;
 double trial[29],accepted[29],older[29],rhs[13],bias[13];
 int prepared,historyReady,trialTransient;
 uint64_t generation,trialToken; uint32_t maximumStressIterations;
};
void cs_diagnostic(CKTcircuit *c,const char *format,...) {
 if(c->diagnosticOverflow)return;
 size_t remaining=sizeof(c->diagnostic)-c->diagnosticCount;
 va_list args;va_start(args,format);
 int n=vsnprintf(c->diagnostic+c->diagnosticCount,remaining,format,args);va_end(args);
 if(n<0||(size_t)n>=remaining){c->diagnosticOverflow=1;return;}
 c->diagnosticCount+=(size_t)n;
}
void cs_fatal(CKTcircuit *c,const char *format,IFuid *names) {
 cs_diagnostic(c,format,names[1],names[0]);
}
void *cs_allocate_size(CKTcircuit *c,size_t bytes) {
 if(c->sizeAllocated||bytes>c->sizeCapacity)return NULL;
 c->sizeAllocated=1;memset(c->sizeStorage,0,bytes);return c->sizeStorage;
}
int NIintegrate(CKTcircuit *c,double *g,double *eq,double capacitance,int charge) {
 if(charge<0||charge+1>=29)return E_BADPARM;
 double coefficient=c->CKTag[0];
 c->CKTstate0[charge+1]=coefficient*(c->CKTstate0[charge]-c->CKTstate1[charge])
                         -(c->method==2?c->CKTstate1[charge+1]:0);
 *g=coefficient*capacitance;*eq=c->CKTstate0[charge+1]-coefficient*c->CKTstate0[charge];
 return isfinite(*g)&&isfinite(*eq)&&isfinite(c->CKTstate0[charge+1])?OK:E_BADPARM;
}
int cs_bsim4_create(int polarity,const char *version,double temperature,int noiseRequested,CSBSIM4Handle **out) {
 if(!out)return CS_BSIM4_PARAMETER;*out=NULL;
 if(!version||strcmp(version,"4.8.3"))return CS_BSIM4_VERSION;
 if((polarity!=1&&polarity!=-1)||!isfinite(temperature)||temperature<=0||(noiseRequested!=0&&noiseRequested!=1))return CS_BSIM4_PARAMETER;
 CSBSIM4Handle *h=calloc(1,sizeof(*h));if(!h)return CS_BSIM4_MEMORY;
 h->model.BSIM4instances=&h->instance;h->model.BSIM4modName="CoreSpiceBSIM4";
 h->model.BSIM4type=polarity;h->model.BSIM4typeGiven=1;
 h->model.BSIM4version=4.83;h->model.BSIM4versionGiven=1;
 h->instance.BSIM4modPtr=&h->model;h->instance.BSIM4name="M1";
 h->instance.BSIM4dNode=1;h->instance.BSIM4gNodeExt=2;h->instance.BSIM4sNode=3;h->instance.BSIM4bNode=4;
 CKTcircuit *c=&h->circuit;c->CKTtemp=temperature;c->CKTnomTemp=300.15;c->nodeCount=4;c->noiseRequested=noiseRequested;
 c->CKTstate0=h->trial;c->CKTstate1=h->accepted;c->CKTstate2=h->older;
 c->CKTstates[0]=h->trial;c->CKTstates[1]=h->accepted;c->CKTstates[2]=h->older;
 c->CKTrhs=h->rhs;c->CKTrhsOld=h->bias;c->sizeStorage=&h->geometry;c->sizeCapacity=sizeof(h->geometry);
 c->CKTabstol=1e-12;c->CKTreltol=1e-3;c->CKTvoltTol=1e-6;*out=h;return CS_BSIM4_OK;
}
void cs_bsim4_destroy(CSBSIM4Handle *h){free(h);}
const char *cs_bsim4_diagnostics(const CSBSIM4Handle *h){return h?h->circuit.diagnostic:NULL;}
static int selector_valid(const char *name,double v) {
 if(!strcmp(name,"mobmod"))return v>=0&&v<=6;
 if(!strcmp(name,"diomod")||!strcmp(name,"capmod")||!strcmp(name,"rbodymod")||!strcmp(name,"igcmod")||!strcmp(name,"tnoimod"))return v>=0&&v<=2;
 if(!strcmp(name,"rgatemod")||!strcmp(name,"tempmod"))return v>=0&&v<=3;
 if(!strcmp(name,"geomod"))return v>=0&&v<=10;
 if(!strcmp(name,"rgeomod"))return v>=0&&v<=8;
 if(!strcmp(name,"binunit"))return v==1||v==2;
 if(!strcmp(name,"paramchk")||!strcmp(name,"rdsmod")||!strcmp(name,"permod")||!strcmp(name,"fnoimod")||!strcmp(name,"trnqsmod")||!strcmp(name,"acnqsmod")||!strcmp(name,"mtrlmod")||!strcmp(name,"mtrlcompatmod")||!strcmp(name,"gidlmod")||!strcmp(name,"igbmod")||!strcmp(name,"wpemod")||!strcmp(name,"cvchargemod")||!strcmp(name,"min")||!strcmp(name,"off"))return v==0||v==1;
 return 1;
}
int cs_bsim4_parameter(CSBSIM4Handle *h,int model,const char *name,double v) {
 if(!h||h->prepared||!name||(model!=0&&model!=1)||!isfinite(v))return CS_BSIM4_PARAMETER;
 if(!strcmp(name,"version")||!strcmp(name,"nmos")||!strcmp(name,"pmos"))return CS_BSIM4_PARAMETER;
 if(!strcmp(name,"nf")&&(v<1||v>INT_MAX))return CS_BSIM4_PARAMETER;
 if(!strcmp(name,"ngcon")&&v!=1&&v!=2)return CS_BSIM4_PARAMETER;
 const IFparm *table=model?BSIM4mPTable:BSIM4pTable;int count=model?BSIM4mPTSize:BSIM4pTSize;
 for(int n=0;n<count;n++)if(table[n].writable&&!strcmp(name,table[n].keyword)) {
  IFvalue value={0};int kind=table[n].dataType;
  if(kind==IF_REAL)value.rValue=v;
  else if(kind==IF_INTEGER||kind==IF_FLAG){if(v<INT_MIN||v>INT_MAX||trunc(v)!=v||!selector_valid(name,v))return CS_BSIM4_PARAMETER;value.iValue=(int)v;}
  else return CS_BSIM4_PARAMETER;
  return model?BSIM4mParam(table[n].id,&value,(GENmodel*)&h->model):BSIM4param(table[n].id,&value,(GENinstance*)&h->instance,NULL);
 }
 return CS_BSIM4_PARAMETER;
}
int cs_bsim4_set_stress_budget(CSBSIM4Handle *h,uint32_t maximumIterations) {
 if(!h||h->prepared||!maximumIterations)return CS_BSIM4_RESOURCE;
 h->maximumStressIterations=maximumIterations;return CS_BSIM4_OK;
}
int cs_bsim4_initial_conditions(CSBSIM4Handle *h,const double values[3]) {
 if(!h||h->prepared||!values)return CS_BSIM4_PARAMETER;
 for(int n=0;n<3;n++)if(!isfinite(values[n]))return CS_BSIM4_PARAMETER;
 IFvalue v={0};v.v.numValue=3;v.v.vec.rVec=(double *)values;
 return BSIM4param(BSIM4_IC,&v,(GENinstance*)&h->instance,NULL);
}
int cs_bsim4_prepare(CSBSIM4Handle *h,CSBSIM4Topology *out) {
 if(!h||h->prepared||!out)return CS_BSIM4_PARAMETER;
 if(!h->maximumStressIterations)return CS_BSIM4_RESOURCE;
 BSIM4instance *i=&h->instance;BSIM4model *m=&h->model;
 if((i->BSIM4lGiven&&i->BSIM4l<=0)||(i->BSIM4wGiven&&i->BSIM4w<=0)||i->BSIM4drainArea<0||i->BSIM4sourceArea<0||i->BSIM4drainPerimeter<0||i->BSIM4sourcePerimeter<0||i->BSIM4drainSquares<0||i->BSIM4sourceSquares<0||m->BSIM4sheetResistance<0)return CS_BSIM4_PARAMETER;
 h->prepared=-1;int states=0;int status=BSIM4setup(&h->matrix,(GENmodel*)m,&h->circuit,&states);
 if(!status&&i->BSIM4sa>0&&i->BSIM4sb>0&&(i->BSIM4nf==1||(i->BSIM4nf>1&&i->BSIM4sd>0))&&ceil(i->BSIM4nf)>h->maximumStressIterations)return CS_BSIM4_RESOURCE;
 if(!status)status=BSIM4temp((GENmodel*)m,&h->circuit);
 if(h->circuit.diagnosticOverflow)return CS_BSIM4_DIAGNOSTICS;
 if(status||states!=29)return CS_BSIM4_PARAMETER;
 if(!isfinite(i->pParam->BSIM4leff)||!isfinite(i->pParam->BSIM4weff)||!isfinite(i->pParam->BSIM4leffCV)||!isfinite(i->pParam->BSIM4weffCV))return CS_BSIM4_NUMERICAL;
 h->prepared=1;
 *out=(CSBSIM4Topology){h->circuit.nodeCount,i->BSIM4dNodePrime,i->BSIM4sNodePrime,i->BSIM4gNodePrime,i->BSIM4gNodeMid,i->BSIM4bNodePrime,i->BSIM4dbNode,i->BSIM4sbNode,i->BSIM4qNode,h->circuit.noiseRequested,m->BSIM4tnoiMod==1};
 return CS_BSIM4_OK;
}
static int set_bias(CSBSIM4Handle *h,const double b[13]) {
 if(!h||h->prepared!=1||!b||b[0]!=0)return CS_BSIM4_PARAMETER;
 for(int n=0;n<13;n++)if(!isfinite(b[n])||(n>h->circuit.nodeCount&&b[n]!=0))return CS_BSIM4_PARAMETER;
 memcpy(h->bias,b,sizeof(h->bias));return CS_BSIM4_OK;
}
static void clear_stamp(CSBSIM4Handle *h){memset(&h->matrix,0,sizeof(h->matrix));memset(h->rhs,0,sizeof(h->rhs));h->circuit.CKTnoncon=0;}
static int small_signal(CSBSIM4Handle *h) {
 BSIM4instance *i=&h->instance;double sign=h->model.BSIM4type;
 int positive[]={i->BSIM4bNodePrime,i->BSIM4bNodePrime,i->BSIM4gNodePrime,i->BSIM4dNodePrime,i->BSIM4dbNode,i->BSIM4dbNode,i->BSIM4sbNode,i->BSIM4gNodeExt,i->BSIM4gNodeMid,i->BSIM4sNode,i->BSIM4dNode};
 for(int n=0;n<11;n++)h->trial[n]=sign*(h->bias[positive[n]]-h->bias[(n==0||n==5)?i->BSIM4dNodePrime:i->BSIM4sNodePrime]);
 h->trial[27]=sign*h->bias[i->BSIM4qNode];h->circuit.CKTmode=MODEINITSMSIG;
 return BSIM4load((GENmodel*)&h->model,&h->circuit);
}
int cs_bsim4_initialize_history(CSBSIM4Handle *h,const double b[13]) {
 if(!h)return CS_BSIM4_PARAMETER;h->trialTransient=0;int status=set_bias(h,b);if(status)return status;
 memset(h->trial,0,sizeof(h->trial));h->circuit.CKTgmin=0;clear_stamp(h);
 if(small_signal(h))return CS_BSIM4_NUMERICAL;
 if(h->circuit.diagnosticOverflow)return CS_BSIM4_DIAGNOSTICS;
 for(int n=0;n<29;n++)if(!isfinite(h->trial[n]))return CS_BSIM4_NUMERICAL;
 memcpy(h->accepted,h->trial,sizeof(h->accepted));memcpy(h->older,h->trial,sizeof(h->older));h->historyReady=1;return CS_BSIM4_OK;
}
int cs_bsim4_evaluate(CSBSIM4Handle *h,const double b[13],int mode,double omega,double dt,double gmin,CSBSIM4Result *out) {
 if(!h)return CS_BSIM4_PARAMETER;h->trialTransient=0;if(!out)return CS_BSIM4_PARAMETER;
 int status=set_bias(h,b);if(status)return status;
 if(mode<0||mode>3||!isfinite(gmin)||gmin<0||!isfinite(omega)||omega<0)return CS_BSIM4_PARAMETER;
 int transient=mode>=2;
 if(transient&&(!h->historyReady||!isfinite(dt)||dt<=0||!isfinite((mode==2?1.:2.)/dt)))return CS_BSIM4_HISTORY;
 CKTcircuit *c=&h->circuit;memcpy(h->trial,h->accepted,sizeof(h->trial));c->CKTgmin=gmin;
 c->CKTmode=transient?MODETRAN:MODEDCOP;c->method=mode==3?2:1;c->CKTdelta=dt;c->CKTag[0]=transient?(mode==2?1.:2.)/dt:0;
 /* Refresh OP-derived NQS coefficients at this exact bias before a DC stamp.
    A prior call's gtau must never select the current evaluation's Jacobian. */
 if(!transient){clear_stamp(h);if(small_signal(h))return CS_BSIM4_NUMERICAL;c->CKTmode=MODEDCOP;}
 clear_stamp(h);if(BSIM4load((GENmodel*)&h->model,c))return CS_BSIM4_NUMERICAL;
 CSBSIM4Result result={0};
 for(int r=0;r<13;r++) {result.rhs[r]=h->rhs[r];result.residual[r]=-h->rhs[r];for(int col=0;col<13;col++){result.real[r*13+col]=h->matrix.values[r][col][0];result.residual[r]+=result.real[r*13+col]*b[col];}}
 if(!transient&&small_signal(h))return CS_BSIM4_NUMERICAL;
 BSIM4instance *i=&h->instance;double scale=h->model.BSIM4type*i->BSIM4mult_q;
 result.charge[i->BSIM4gNodePrime]+=scale*h->trial[13];result.charge[i->BSIM4dNodePrime]+=scale*h->trial[15];result.charge[i->BSIM4sNodePrime]+=scale*h->trial[28];result.charge[i->BSIM4bNodePrime]+=scale*h->trial[11];
 if(i->BSIM4rgateMod==3)result.charge[i->BSIM4gNodeMid]+=scale*h->trial[17];
 if(i->BSIM4rbodyMod){result.charge[i->BSIM4dbNode]+=scale*h->trial[21];result.charge[i->BSIM4sbNode]+=scale*h->trial[19];}
 memcpy(result.states,h->trial,sizeof(h->trial));double multi=i->BSIM4mult_i;double point[]={multi*i->BSIM4cd,multi*i->BSIM4gm,multi*i->BSIM4gds,multi*i->BSIM4gmbs,i->BSIM4von,i->BSIM4vdsat,multi*i->BSIM4csub,(double)i->BSIM4mode};memcpy(result.operatingPoint,point,sizeof(point));double intrinsic[]={i->BSIM4mult_q*i->BSIM4qgate,i->BSIM4mult_q*i->BSIM4qdrn,i->BSIM4mult_q*i->BSIM4qbulk,i->BSIM4mult_q*i->BSIM4qsrc};memcpy(result.intrinsicCharges,intrinsic,sizeof(intrinsic));
 if(mode==1){clear_stamp(h);c->CKTomega=omega;if(BSIM4acLoad((GENmodel*)&h->model,c))return CS_BSIM4_NUMERICAL;for(int r=0;r<13;r++)for(int col=0;col<13;col++){result.real[r*13+col]=h->matrix.values[r][col][0];result.imaginary[r*13+col]=h->matrix.values[r][col][1];}}
 if(c->diagnosticOverflow)return CS_BSIM4_DIAGNOSTICS;
 const double *arrays[]={result.residual,result.rhs,result.charge,result.real,result.imaginary,result.states,result.operatingPoint,result.intrinsicCharges};int counts[]={13,13,13,169,169,29,8,4};
 for(int a=0;a<8;a++)for(int n=0;n<counts[a];n++)if(!isfinite(arrays[a][n]))return CS_BSIM4_NUMERICAL;
 if(h->generation==UINT64_MAX)return CS_BSIM4_HISTORY;
 result.token=++h->generation;h->trialToken=result.token;h->trialTransient=transient;*out=result;return CS_BSIM4_OK;
}
void cs_bsim4_invalidate_trial(CSBSIM4Handle *h){if(h)h->trialTransient=0;}
int cs_bsim4_commit(CSBSIM4Handle *h,uint64_t token) {
 if(!h||!h->trialTransient||token!=h->trialToken)return CS_BSIM4_HISTORY;
 memcpy(h->older,h->accepted,sizeof(h->older));memcpy(h->accepted,h->trial,sizeof(h->accepted));h->trialTransient=0;return CS_BSIM4_OK;
}
int cs_bsim4_accepted_states(const CSBSIM4Handle *h,double out[29]) {
 if(!h||!out||!h->historyReady)return CS_BSIM4_HISTORY;memcpy(out,h->accepted,sizeof(h->accepted));return CS_BSIM4_OK;
}
