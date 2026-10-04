#include "../include/CoreSpiceBSIM3.h"
#include "bsim3def.h"
#include <limits.h>

extern const IFparm BSIM3pTable[],BSIM3mPTable[];
extern const int BSIM3pTSize,BSIM3mPTSize;

/* One owner allocation, no pointer retention from callers. Matrix element
   pointers borrow its embedded matrix until exactly-once destruction. */
struct CSBSIM3Handle {
    BSIM3model model;
    BSIM3instance instance;
    struct bsim3SizeDependParam geometry;
    CKTcircuit circuit;
    SMPmatrix matrix;
    double trial[17],accepted[17],older[17],rhs[8],bias[8];
    int prepared,historyReady,trialTransient;
    uint64_t generation,trialToken;
};

void cs_diagnostic(CKTcircuit *c,const char *format,...) {
    if(c->diagnosticOverflow)return;
    size_t remaining=sizeof(c->diagnostic)-c->diagnosticCount;
    va_list arguments;va_start(arguments,format);
    int written=vsnprintf(c->diagnostic+c->diagnosticCount,remaining,format,arguments);
    va_end(arguments);
    if(written<0||(size_t)written>=remaining){c->diagnosticOverflow=1;return;}
    c->diagnosticCount+=(size_t)written;
}
void cs_fatal(CKTcircuit *c,const char *format,IFuid *names) {
    // Original namarray stores model then instance, while every format names instance then model.
    cs_diagnostic(c,format,names[1],names[0]);
}
void *cs_allocate_size(CKTcircuit *c,size_t bytes) {
    if(c->sizeAllocated||bytes>c->sizeCapacity)return NULL;
    c->sizeAllocated=1;memset(c->sizeStorage,0,bytes);return c->sizeStorage;
}
int NIintegrate(CKTcircuit *c,double *conductance,double *equivalent,double capacitance,int charge) {
    if(charge<0||charge>=16)return E_BADPARM;
    double coefficient=c->CKTag[0];
    c->CKTstate0[charge+1]=coefficient*(c->CKTstate0[charge]-c->CKTstate1[charge])
        -(c->method==2?c->CKTstate1[charge+1]:0.0);
    *conductance=coefficient*capacitance;
    *equivalent=c->CKTstate0[charge+1]-coefficient*c->CKTstate0[charge];
    return isfinite(c->CKTstate0[charge+1])?OK:E_BADPARM;
}

CSBSIM3Handle *cs_bsim3_create(int polarity,double temperature) {
    if((polarity!=1&&polarity!=-1)||!isfinite(temperature)||temperature<=0)return NULL;
    CSBSIM3Handle *h=calloc(1,sizeof(*h));if(!h)return NULL;
    h->model.BSIM3instances=&h->instance;h->model.BSIM3modName="CoreSpiceBSIM3";
    h->model.BSIM3type=polarity;h->model.BSIM3typeGiven=1;
    h->instance.BSIM3modPtr=&h->model;h->instance.BSIM3name="M1";
    h->instance.BSIM3dNode=1;h->instance.BSIM3gNode=2;
    h->instance.BSIM3sNode=3;h->instance.BSIM3bNode=4;
    CKTcircuit *c=&h->circuit;c->CKTtemp=temperature;c->CKTnomTemp=300.15;c->nodeCount=4;
    c->CKTstate0=h->trial;c->CKTstate1=h->accepted;c->CKTstate2=h->older;
    c->CKTrhs=h->rhs;c->CKTrhsOld=h->bias;
    c->sizeStorage=&h->geometry;c->sizeCapacity=sizeof(h->geometry);
    c->CKTabstol=1e-12;c->CKTreltol=1e-3;c->CKTvoltTol=1e-6;
    return h;
}
void cs_bsim3_destroy(CSBSIM3Handle *h){free(h);}
const char *cs_bsim3_diagnostics(const CSBSIM3Handle *h){return h->circuit.diagnostic;}

static int selector_valid(const char *name,double value) {
    if(strcmp(name,"capmod")==0)return value>=0&&value<=3;
    if(strcmp(name,"mobmod")==0)return value>=1&&value<=3;
    if(strcmp(name,"noimod")==0)return value>=1&&value<=6;
    if(strcmp(name,"binunit")==0)return value==1||value==2;
    if(strcmp(name,"nqsmod")==0||strcmp(name,"acnqsmod")==0||strcmp(name,"off")==0||strcmp(name,"paramchk")==0)return value==0||value==1;
    return 1;
}
int cs_bsim3_parameter(CSBSIM3Handle *h,int model,const char *name,double value) {
    if(h->prepared||!isfinite(value))return CS_BSIM3_PARAMETER;
    const IFparm *table=model?BSIM3mPTable:BSIM3pTable;
    int count=model?BSIM3mPTSize:BSIM3pTSize;
    /* Polarity/version are owned by the typed configuration, never aliases. */
    if(!strcmp(name,"nmos")||!strcmp(name,"pmos")||!strcmp(name,"version"))return CS_BSIM3_PARAMETER;
    for(int n=0;n<count;n++)if(table[n].writable&&!strcmp(name,table[n].keyword)) {
        IFvalue v={0};int kind=table[n].dataType;
        if(kind==IF_REAL)v.rValue=value;
        else if(kind==IF_INTEGER||kind==IF_FLAG) {
            if(value<INT_MIN||value>INT_MAX||trunc(value)!=value||!selector_valid(name,value))return CS_BSIM3_PARAMETER;
            v.iValue=(int)value;
        }else return CS_BSIM3_PARAMETER;
        return model?BSIM3mParam(table[n].id,&v,(GENmodel*)&h->model)
            :BSIM3param(table[n].id,&v,(GENinstance*)&h->instance,NULL);
    }
    return CS_BSIM3_PARAMETER;
}
int cs_bsim3_initial_conditions(CSBSIM3Handle *h,const double values[3]) {
    if(h->prepared)return CS_BSIM3_PARAMETER;
    for(int n=0;n<3;n++)if(!isfinite(values[n]))return CS_BSIM3_PARAMETER;
    IFvalue value={0};value.v.numValue=3;value.v.vec.rVec=(double *)values;
    return BSIM3param(BSIM3_IC,&value,(GENinstance*)&h->instance,NULL);
}
int cs_bsim3_prepare(CSBSIM3Handle *h,CSBSIM3Topology *topology) {
    if(h->prepared)return CS_BSIM3_PARAMETER;
    BSIM3instance *i=&h->instance;BSIM3model *m=&h->model;
    if((i->BSIM3lGiven&&i->BSIM3l<=0)||(i->BSIM3wGiven&&i->BSIM3w<=0)
       ||i->BSIM3drainArea<0||i->BSIM3sourceArea<0||i->BSIM3drainPerimeter<0
       ||i->BSIM3sourcePerimeter<0||i->BSIM3drainSquares<0||i->BSIM3sourceSquares<0
       ||(m->BSIM3toxGiven&&m->BSIM3tox<=0)||(m->BSIM3toxmGiven&&m->BSIM3toxm<=0)
       ||m->BSIM3sheetResistance<0)return CS_BSIM3_PARAMETER;
    h->prepared=-1; // One preparation attempt, including rejected partial setup.
    int states=0;int status=BSIM3setup(&h->matrix,(GENmodel*)m,&h->circuit,&states);
    if(!status)status=BSIM3temp((GENmodel*)m,&h->circuit);
    if(h->circuit.diagnosticOverflow)return CS_BSIM3_DIAGNOSTICS;
    if(status||states!=17)return CS_BSIM3_PARAMETER;
    if(!isfinite(i->pParam->BSIM3leff)||!isfinite(i->pParam->BSIM3weff)
       ||!isfinite(i->pParam->BSIM3leffCV)||!isfinite(i->pParam->BSIM3weffCV))return CS_BSIM3_NUMERICAL;
    h->prepared=1;
    *topology=(CSBSIM3Topology){h->circuit.nodeCount,i->BSIM3dNodePrime,i->BSIM3sNodePrime,i->BSIM3qNode};
    return CS_BSIM3_OK;
}
static int set_bias(CSBSIM3Handle *h,const double values[8]) {
    if(h->prepared!=1||values[0]!=0)return CS_BSIM3_PARAMETER;
    for(int n=0;n<8;n++)if(!isfinite(values[n])||(n>h->circuit.nodeCount&&values[n]!=0))return CS_BSIM3_PARAMETER;
    memcpy(h->bias,values,sizeof(h->bias));return CS_BSIM3_OK;
}
static void clear_stamp(CSBSIM3Handle *h){memset(&h->matrix,0,sizeof(h->matrix));memset(h->rhs,0,sizeof(h->rhs));h->circuit.CKTnoncon=0;}
static int small_signal(CSBSIM3Handle *h) {
    BSIM3instance *i=&h->instance;double sign=h->model.BSIM3type;
    h->trial[0]=sign*(h->bias[4]-h->bias[i->BSIM3dNodePrime]);
    h->trial[1]=sign*(h->bias[4]-h->bias[i->BSIM3sNodePrime]);
    h->trial[2]=sign*(h->bias[2]-h->bias[i->BSIM3sNodePrime]);
    h->trial[3]=sign*(h->bias[i->BSIM3dNodePrime]-h->bias[i->BSIM3sNodePrime]);
    h->trial[16]=sign*h->bias[i->BSIM3qNode];
    h->circuit.CKTmode=MODEINITSMSIG;
    return BSIM3load((GENmodel*)&h->model,&h->circuit);
}
int cs_bsim3_initialize_history(CSBSIM3Handle *h,const double bias[8]) {
    h->trialTransient=0;int status=set_bias(h,bias);if(status)return status;
    memset(h->trial,0,sizeof(h->trial));h->circuit.CKTgmin=0;
    if(small_signal(h))return CS_BSIM3_NUMERICAL;
    for(int n=0;n<17;n++)if(!isfinite(h->trial[n]))return CS_BSIM3_NUMERICAL;
    memcpy(h->accepted,h->trial,sizeof(h->accepted));memcpy(h->older,h->trial,sizeof(h->older));
    h->historyReady=1;return CS_BSIM3_OK;
}
int cs_bsim3_evaluate(CSBSIM3Handle *h,const double bias[8],int mode,double omega,double dt,double gmin,CSBSIM3Result *out) {
    h->trialTransient=0;memset(out,0,sizeof(*out));
    int status=set_bias(h,bias);if(status)return status;
    if(mode<0||mode>3||!isfinite(gmin)||gmin<0||!isfinite(omega)||omega<0)return CS_BSIM3_PARAMETER;
    int transient=mode>=2;
    if(transient&&(!h->historyReady||!isfinite(dt)||dt<=0||!isfinite((mode==2?1.0:2.0)/dt)))return CS_BSIM3_HISTORY;
    CKTcircuit *c=&h->circuit;
    memcpy(h->trial,h->accepted,sizeof(h->trial));c->CKTgmin=gmin;
    c->CKTmode=transient?MODETRAN:MODEDCOP;c->method=mode==3?2:1;
    c->CKTdelta=dt;c->CKTag[0]=transient?(mode==2?1.0:2.0)/dt:0;
    clear_stamp(h);
    if(BSIM3load((GENmodel*)&h->model,c))return CS_BSIM3_NUMERICAL;
    for(int r=0;r<8;r++) {
        out->rhs[r]=h->rhs[r];out->residual[r]=-h->rhs[r];
        for(int col=0;col<8;col++){out->real[r*8+col]=h->matrix.values[r][col][0];out->residual[r]+=out->real[r*8+col]*bias[col];}
    }
    if(!transient&&small_signal(h))return CS_BSIM3_NUMERICAL;
    BSIM3instance *i=&h->instance;double sign=h->model.BSIM3type;
    out->charge[2]=sign*h->trial[6];out->charge[i->BSIM3dNodePrime]=sign*h->trial[8];
    out->charge[4]=sign*h->trial[4];out->charge[i->BSIM3sNodePrime]=-sign*(h->trial[6]+h->trial[8]+h->trial[4]);
    memcpy(out->states,h->trial,sizeof(h->trial));
    double point[]={i->BSIM3cd,i->BSIM3gm,i->BSIM3gds,i->BSIM3gmbs,i->BSIM3von,i->BSIM3vdsat,i->BSIM3csub,(double)i->BSIM3mode};
    memcpy(out->operatingPoint,point,sizeof(point));
    if(mode==1){clear_stamp(h);c->CKTomega=omega;if(BSIM3acLoad((GENmodel*)&h->model,c))return CS_BSIM3_NUMERICAL;
        for(int r=0;r<8;r++)for(int col=0;col<8;col++){out->real[r*8+col]=h->matrix.values[r][col][0];out->imaginary[r*8+col]=h->matrix.values[r][col][1];}}
    /* Validate every externally meaningful value and trial state before publishing. */
    const double *arrays[]={out->residual,out->rhs,out->charge,out->real,out->imaginary,out->states,out->operatingPoint};
    const int counts[]={8,8,8,64,64,32,8};
    for(int a=0;a<7;a++)for(int n=0;n<counts[a];n++)if(!isfinite(arrays[a][n]))return CS_BSIM3_NUMERICAL;
    if(h->generation==UINT64_MAX)return CS_BSIM3_HISTORY;
    out->token=++h->generation;h->trialToken=out->token;h->trialTransient=transient;return CS_BSIM3_OK;
}
int cs_bsim3_commit(CSBSIM3Handle *h,uint64_t token) {
    if(!h->trialTransient||token!=h->trialToken)return CS_BSIM3_HISTORY;
    memcpy(h->older,h->accepted,sizeof(h->older));memcpy(h->accepted,h->trial,sizeof(h->accepted));
    h->trialTransient=0;return CS_BSIM3_OK;
}
void cs_bsim3_accepted_states(const CSBSIM3Handle *h,double states[32]) {memset(states,0,32*sizeof(double));memcpy(states,h->accepted,sizeof(h->accepted));}


extern int cs_bsim3_noise_density(BSIM3model *,BSIM3instance *,CKTcircuit *,double,double[4]);
int cs_bsim3_noise_spectrum(CSBSIM3Handle *h,const double bias[8],double frequency,
                           double gmin,double densities[4]) {
    h->trialTransient=0;
    memset(densities,0,4*sizeof(double));
    if(!isfinite(frequency)||frequency<=0)return CS_BSIM3_PARAMETER;
    CSBSIM3Result point;
    int status=cs_bsim3_evaluate(h,bias,0,0,0,gmin,&point);
    if(status)return status;
    double values[4];
    status=cs_bsim3_noise_density(&h->model,&h->instance,&h->circuit,frequency,values);
    if(status)return status;
    for(int n=0;n<4;n++)if(!isfinite(values[n])||values[n]<0)return CS_BSIM3_NUMERICAL;
    memcpy(densities,values,sizeof(values));return CS_BSIM3_OK;
}
