#include "../include/CoreSpiceBSIM45.h"
#include "bsim4def.h"
#include <limits.h>
extern const IFparm BSIM4pTable[], BSIM4mPTable[];
extern const int BSIM4pTSize, BSIM4mPTSize;
#include "admission.inc"
/* Exactly one calloc owns all initialized storage and all original pointers.
   Matrix elements, the geometry knot and node handles borrow this allocation.
   No pointer into caller storage escapes a setter. All public access is exclusive.
   calloc supplies alignment for every member; sizeof admission precedes allocation.
   Destruction frees the whole allocation once, including terminal partial failures. */
struct CSBSIM45Owner {
 BSIM4model model;
 BSIM4instance instance;
 struct bsim4SizeDependParam geometry;
 CKTcircuit circuit;
 SMPmatrix matrix;
 double states[3][CS_BSIM45_STATE_SLOTS];
 double bias[CS_BSIM45_LOCAL_SLOTS],rhs[CS_BSIM45_LOCAL_SLOTS];
 CSBSIM45StaticResult result;
 uint32_t maximumStressIterations,stressIterations;
 int state,stateCount;
};
#include "finite.inc"
static CSBSIM45Status fail(CSBSIM45Owner *h,CSBSIM45Status status,int role,int selector,double value) {
 if(h) {
  h->state=-1;
  cs_diagnostic(&h->circuit,0,status==CS_BSIM45_RESOURCE?CS_BSIM45_DIAG_RESOURCE:CS_BSIM45_DIAG_INPUT,
                role,selector,value,"Native operation rejected (%d)",status);
 }
 return status;
}
void cs_diagnostic(CKTcircuit *c,uint32_t site,CSBSIM45DiagnosticCode code,int role,int selector,double value,const char *format,...) {
 if(code==CS_BSIM45_DIAG_FATAL)c->fatalSeen=1;
 if(c->diagnosticCount>=c->diagnosticLimit){c->diagnosticOverflow=1;return;}
 CSBSIM45Diagnostic *d=&c->diagnostics[c->diagnosticCount++];
 d->code=code; d->role=role; d->parameterID=selector; d->sourceSite=site; d->value=value;
 va_list args;va_start(args,format);int n=vsnprintf(d->text,sizeof(d->text),format,args);va_end(args);
 if(n<0||(size_t)n>=sizeof(d->text))c->diagnosticOverflow=1;
}
void cs_fatal(CKTcircuit *c,uint32_t site,const char *format,IFuid *names) {
 cs_diagnostic(c,site,CS_BSIM45_DIAG_FATAL,CS_BSIM45_KERNEL_ROLE,0,0,format,names[1],names[0]);
}
void *cs_allocate_size(CKTcircuit *c,size_t bytes) {
 if(c->sizeAllocated||bytes>c->sizeCapacity){c->allocationFailed=1;return NULL;}
 c->sizeAllocated=1;memset(c->sizeStorage,0,bytes);return c->sizeStorage;
}
size_t cs_bsim45_owner_size(void){return sizeof(CSBSIM45Owner);}
const char *cs_bsim45_release(void){return "4.5.0";}
const char *cs_bsim45_adaptation(void){return "static-v1.sc-selector-v1.cap0-chain-rule-v1.cv-drain-body-v1.ud-chain-rule-v1.spice3f5-constants";}
CSBSIM45Status cs_bsim45_create(const char *release,uint32_t schemaRevision,int polarity,const CSBSIM45Conditions *conditions,CSBSIM45Owner **out) {
 if(!out)return CS_BSIM45_PARAMETER;*out=NULL;
 if(!release||strcmp(release,cs_bsim45_release()))return CS_BSIM45_VERSION;
 if(schemaRevision!=2)return CS_BSIM45_SCHEMA;
 if(!conditions||(polarity!=1&&polarity!=-1)||!isfinite(conditions->ambientKelvin)||conditions->ambientKelvin<=0||
    !isfinite(conditions->nominalKelvin)||conditions->nominalKelvin<=0||
    (conditions->noiseTopology!=0&&conditions->noiseTopology!=1))return CS_BSIM45_PARAMETER;
 if(conditions->maximumOwnerBytes<sizeof(CSBSIM45Owner)||!conditions->maximumStressIterations||
    conditions->maximumDiagnostics>CS_BSIM45_MAX_DIAGNOSTICS)return CS_BSIM45_RESOURCE;
 CSBSIM45Owner *h=calloc(1,sizeof(*h));if(!h)return CS_BSIM45_MEMORY;
 h->maximumStressIterations=conditions->maximumStressIterations;
 h->model.BSIM4instances=&h->instance;h->model.BSIM4modName="CoreSpiceBSIM45";
 h->model.BSIM4type=polarity;h->model.BSIM4typeGiven=1;
 h->model.BSIM4version="4.5.0";h->model.BSIM4versionGiven=1;
 h->instance.BSIM4modPtr=&h->model;h->instance.BSIM4name="M1";
 h->instance.BSIM4dNode=1;h->instance.BSIM4gNodeExt=2;h->instance.BSIM4sNode=3;h->instance.BSIM4bNode=4;
 CKTcircuit *c=&h->circuit;c->CKTtemp=conditions->ambientKelvin;c->CKTnomTemp=conditions->nominalKelvin;
 c->nodeCount=4;c->noiseRequested=conditions->noiseTopology;c->diagnosticLimit=conditions->maximumDiagnostics;
 c->CKTstate0=h->states[0];c->CKTstate1=h->states[1];c->CKTstate2=h->states[2];
 c->CKTrhs=h->rhs;c->CKTrhsOld=h->bias;
 c->CKTabstol=1e-12;c->CKTreltol=1e-3;c->CKTvoltTol=1e-6;
 c->sizeStorage=&h->geometry;c->sizeCapacity=sizeof(h->geometry);
 *out=h;return CS_BSIM45_OK;
}
static int selector_valid(int role,int id,double v) {
 if(role==CS_BSIM45_MODEL) {
  switch(id) {
  case BSIM4_MOD_MOBMOD: case BSIM4_MOD_CAPMOD: case BSIM4_MOD_DIOMOD:
  case BSIM4_MOD_RBODYMOD: case BSIM4_MOD_IGCMOD: case BSIM4_MOD_TEMPMOD: return v>=0&&v<=2;
  case BSIM4_MOD_RGATEMOD: return v>=0&&v<=3;
  case BSIM4_MOD_GEOMOD: return v>=0&&v<=10;
  case BSIM4_MOD_BINUNIT: return v==1||v==2;
  case BSIM4_MOD_PARAMCHK: case BSIM4_MOD_RDSMOD: case BSIM4_MOD_PERMOD:
  case BSIM4_MOD_FNOIMOD: case BSIM4_MOD_TNOIMOD: case BSIM4_MOD_TRNQSMOD:
  case BSIM4_MOD_ACNQSMOD: case BSIM4_MOD_IGBMOD: case BSIM4_MOD_WPEMOD: return v==0||v==1;
  default:return 1;
  }
 }
 switch(id) {
 case BSIM4_RBODYMOD:return v>=0&&v<=2;
 case BSIM4_RGATEMOD:return v>=0&&v<=3;
 case BSIM4_GEOMOD:return v>=0&&v<=10;
 case BSIM4_RGEOMOD:return v>=0&&v<=8;
 case BSIM4_MIN:case BSIM4_TRNQSMOD:case BSIM4_ACNQSMOD:case BSIM4_OFF:return v==0||v==1;
 case BSIM4_NF:return v>=1&&v<=INT_MAX;
 case BSIM4_L:case BSIM4_W:return v>0;
 case BSIM4_AD:case BSIM4_AS:case BSIM4_PD:case BSIM4_PS:case BSIM4_NRD:case BSIM4_NRS:
 case BSIM4_SA:case BSIM4_SB:case BSIM4_SD:case BSIM4_SC:return v>=0;
 default:return 1;
 }
}
static CSBSIM45Status set_parameter(CSBSIM45Owner *h,int role,int id,CSBSIM45Kind kind,double v) {
 if(!h)return CS_BSIM45_PARAMETER;
 if(h->state!=0)return fail(h,CS_BSIM45_STATE,role,id,v);
 int expected=parameter_kind(role,id);
 if(!expected||kind!=expected||!isfinite(v)||
    (role==CS_BSIM45_MODEL&&(id==BSIM4_MOD_VERSION||id==BSIM4_MOD_NMOS||id==BSIM4_MOD_PMOS))||
    (kind!=CS_BSIM45_REAL&&kind!=CS_BSIM45_INTEGER&&kind!=CS_BSIM45_FLAG)||!selector_valid(role,id,v))
  return fail(h,CS_BSIM45_PARAMETER,role,id,v);
 IFvalue value={0};
 if(kind==CS_BSIM45_REAL)value.rValue=v;
 else {
  if(v<INT_MIN||v>INT_MAX||trunc(v)!=v||(kind==CS_BSIM45_FLAG&&v!=0&&v!=1))return fail(h,CS_BSIM45_PARAMETER,role,id,v);
  value.iValue=(int)v;
 }
 int status=role==CS_BSIM45_MODEL?BSIM4mParam(id,&value,(GENmodel*)&h->model):BSIM4param(id,&value,(GENinstance*)&h->instance,NULL);
 return status?fail(h,CS_BSIM45_PARAMETER,role,id,v):CS_BSIM45_OK;
}
CSBSIM45Status cs_bsim45_set_model(CSBSIM45Owner *h,int32_t id,CSBSIM45Kind kind,double v){return set_parameter(h,CS_BSIM45_MODEL,id,kind,v);}
CSBSIM45Status cs_bsim45_set_instance(CSBSIM45Owner *h,int32_t id,CSBSIM45Kind kind,double v){return set_parameter(h,CS_BSIM45_INSTANCE,id,kind,v);}
CSBSIM45Status cs_bsim45_set_initial_conditions(CSBSIM45Owner *h,const double *values,size_t count) {
 if(!h)return CS_BSIM45_PARAMETER;
 if(h->state!=0)return fail(h,CS_BSIM45_STATE,CS_BSIM45_INSTANCE,BSIM4_IC,0);
 if(!values||count<1||count>3)return fail(h,CS_BSIM45_PARAMETER,CS_BSIM45_INSTANCE,BSIM4_IC,0);
 for(size_t n=0;n<count;n++)if(!isfinite(values[n]))return fail(h,CS_BSIM45_PARAMETER,CS_BSIM45_INSTANCE,BSIM4_IC,values[n]);
 IFvalue v={0};v.v.numValue=(int)count;v.v.vec.rVec=(double *)values;
 return BSIM4param(BSIM4_IC,&v,(GENinstance*)&h->instance,NULL)?fail(h,CS_BSIM45_PARAMETER,CS_BSIM45_INSTANCE,BSIM4_IC,0):CS_BSIM45_OK;
}
CSBSIM45Status cs_bsim45_prepare(CSBSIM45Owner *h) {
 if(!h)return CS_BSIM45_PARAMETER;
 if(h->state!=0)return fail(h,CS_BSIM45_STATE,CS_BSIM45_KERNEL_ROLE,0,0);
 h->state=1;
 int status=BSIM4setup(&h->matrix,(GENmodel*)&h->model,&h->circuit,&h->stateCount);
 BSIM4instance *i=&h->instance;
 if(!status&&i->BSIM4sa>0&&i->BSIM4sb>0&&(i->BSIM4nf==1||(i->BSIM4nf>1&&i->BSIM4sd>0))) {
  double work=ceil(i->BSIM4nf);
  if(work>h->maximumStressIterations)return fail(h,CS_BSIM45_RESOURCE,CS_BSIM45_INSTANCE,BSIM4_NF,i->BSIM4nf);
  h->stressIterations=(uint32_t)work;
 }
 if(!status)status=BSIM4temp((GENmodel*)&h->model,&h->circuit);
 if(status||h->circuit.fatalSeen)return fail(h,CS_BSIM45_KERNEL,CS_BSIM45_KERNEL_ROLE,0,0);
 if(h->circuit.allocationFailed||h->stateCount!=29||h->circuit.nodeCount>12)return fail(h,CS_BSIM45_RESOURCE,CS_BSIM45_KERNEL_ROLE,0,0);
 if(h->circuit.diagnosticOverflow)return fail(h,CS_BSIM45_DIAGNOSTICS,CS_BSIM45_KERNEL_ROLE,0,0);
 if(i->pParam!=&h->geometry||!prepared_finite(h))return fail(h,CS_BSIM45_NONFINITE,CS_BSIM45_KERNEL_ROLE,0,0);
 h->state=2;return CS_BSIM45_OK;
}
CSBSIM45Status cs_bsim45_prepared_info(const CSBSIM45Owner *h,CSBSIM45PreparedInfo *out) {
 if(!h||!out)return CS_BSIM45_PARAMETER;
 if(h->state!=2)return CS_BSIM45_STATE;
 const BSIM4instance *i=&h->instance;const struct bsim4SizeDependParam *g=&h->geometry;
 *out=(CSBSIM45PreparedInfo){h->circuit.nodeCount,i->BSIM4dNodePrime,i->BSIM4sNodePrime,i->BSIM4gNodePrime,i->BSIM4gNodeMid,
  i->BSIM4bNodePrime,i->BSIM4dbNode,i->BSIM4sbNode,i->BSIM4qNode,h->circuit.noiseRequested,h->stateCount,h->model.BSIM4type,
  h->stressIterations,i->BSIM4l,i->BSIM4w,i->BSIM4nf,g->BSIM4leff,g->BSIM4weff,g->BSIM4leffCV,g->BSIM4weffCV,
  i->BSIM4vth0,i->BSIM4u0temp,i->BSIM4vsattemp,h->model.BSIM4tnom,h->circuit.CKTtemp,h->model.BSIM4ud,i->BSIM4sc,i->BSIM4sca,h->model.BSIM4SbulkJctPotential,h->model.BSIM4vcrit};
 return CS_BSIM45_OK;
}
size_t cs_bsim45_diagnostic_count(const CSBSIM45Owner *h){return h?h->circuit.diagnosticCount:0;}
CSBSIM45Status cs_bsim45_diagnostic_at(const CSBSIM45Owner *h,size_t n,CSBSIM45Diagnostic *out) {
 if(!h||!out||n>=h->circuit.diagnosticCount)return CS_BSIM45_PARAMETER;
 *out=h->circuit.diagnostics[n];return CS_BSIM45_OK;
}
size_t cs_bsim45_parameter_count(CSBSIM45Role role) {
 if(role!=CS_BSIM45_INSTANCE&&role!=CS_BSIM45_MODEL)return 0;
 const IFparm *table=role==CS_BSIM45_MODEL?BSIM4mPTable:BSIM4pTable;
 int count=role==CS_BSIM45_MODEL?BSIM4mPTSize:BSIM4pTSize;
 size_t writable=0;for(int n=0;n<count;n++)if(table[n].writable)writable++;
 return writable;
}
CSBSIM45Status cs_bsim45_parameter_at(CSBSIM45Role role,size_t index,CSBSIM45ParameterInfo *out) {
 if(!out||index>=cs_bsim45_parameter_count(role))return CS_BSIM45_PARAMETER;
 const IFparm *table=role==CS_BSIM45_MODEL?BSIM4mPTable:BSIM4pTable;
 int count=role==CS_BSIM45_MODEL?BSIM4mPTSize:BSIM4pTSize;
 size_t n=0;
 for(int k=0;k<count;k++)if(table[k].writable) {
  if(n++==index){*out=(CSBSIM45ParameterInfo){table[k].keyword,table[k].id,table[k].dataType};return CS_BSIM45_OK;}
 }
 return CS_BSIM45_PARAMETER;
}
void cs_bsim45_destroy(CSBSIM45Owner *h){free(h);}

#include "static_evaluation.inc"
