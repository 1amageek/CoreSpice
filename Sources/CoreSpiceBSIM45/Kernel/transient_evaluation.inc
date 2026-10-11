/* All 29 state slots have one owner. Original MODEINITTRAN is deliberately not
   entered: its implicit accepted-history writes violate trial isolation. Normal
   MODETRAN and NIintegrate write only state0. All pointer aliases remain stable. */
CSBSIM45Status cs_bsim45_initialize_history(CSBSIM45Owner *h,const double *bias,size_t count,double gmin) {
 invalidate_trial(h);
 CSBSIM45Status status=cs_bsim45_evaluate_static(h,bias,count,gmin,h?&h->result:NULL);
 if(status!=CS_BSIM45_OK)return status;
 for(int n=0;n<29;n++)if(!isfinite(h->states[0][n]))return fail(h,CS_BSIM45_NONFINITE,CS_BSIM45_KERNEL_ROLE,0,0);
 memcpy(h->states[1],h->states[0],sizeof(h->states[1]));
 memcpy(h->states[2],h->states[0],sizeof(h->states[2]));
 h->historyReady=1;return CS_BSIM45_OK;
}
CSBSIM45Status cs_bsim45_evaluate_transient(CSBSIM45Owner *h,const double *bias,size_t count,
 double deficit,double gmin,CSBSIM45IntegrationMethod method,double dt,CSBSIM45TransientResult *out) {
 invalidate_trial(h);
 if(!h||!bias||!out||count!=13||!isfinite(gmin)||gmin<0||!isfinite(deficit)||
    (method!=CS_BSIM45_BE&&method!=CS_BSIM45_TRAPEZOIDAL)||!isfinite(dt)||dt<=0)return CS_BSIM45_PARAMETER;
 if(h->state!=2)return CS_BSIM45_STATE;
 if(!h->historyReady)return CS_BSIM45_HISTORY;
 if(h->trialGeneration==UINT64_MAX)return CS_BSIM45_RESOURCE;
 BSIM4instance *i=&h->instance;CKTcircuit *c=&h->circuit;
 for(int n=0;n<13;n++)if(!isfinite(bias[n])||((n==0||n>c->nodeCount||n==i->BSIM4qNode)&&bias[n]!=0))return CS_BSIM45_PARAMETER;
 if(!i->BSIM4trnqsMod&&deficit!=0)return CS_BSIM45_PARAMETER;
 double coefficient=(method==CS_BSIM45_BE?1.:2.)/dt;
 if(!isfinite(coefficient)||coefficient<=0)return CS_BSIM45_PARAMETER;
 memcpy(h->bias,bias,sizeof(h->bias));if(i->BSIM4qNode)h->bias[i->BSIM4qNode]=deficit;
 memcpy(h->states[0],h->states[1],sizeof(h->states[0]));seed_exact_bias(h);
 memset(&h->matrix,0,sizeof(h->matrix));memset(h->rhs,0,sizeof(h->rhs));
 c->CKTgmin=gmin;c->CKTnoncon=0;c->CKTmode=MODETRAN;c->CKTdelta=dt;
 c->integrationMethod=method;c->CKTag[0]=coefficient;c->CKTag[1]=method==CS_BSIM45_BE?-coefficient:1;
 int loadStatus=BSIM4load((GENmodel*)&h->model,c);
 if(loadStatus)return fail(h,loadStatus==E_NONFINITE?CS_BSIM45_NONFINITE:CS_BSIM45_KERNEL,CS_BSIM45_KERNEL_ROLE,0,0);
 if(c->diagnosticOverflow)return fail(h,CS_BSIM45_DIAGNOSTICS,CS_BSIM45_KERNEL_ROLE,0,0);
 CSBSIM45TransientResult *r=&h->transientResult;
 for(int row=0;row<13;row++) {
  double residual=-h->rhs[row];
  for(int col=0;col<13;col++) {
   double value=h->matrix.values[row][col][0];
   if(!isfinite(value))return fail(h,CS_BSIM45_NONFINITE,CS_BSIM45_KERNEL_ROLE,0,0);
   r->jacobian[row*13+col]=value;residual+=value*h->bias[col];
  }
  if(!isfinite(residual))return fail(h,CS_BSIM45_NONFINITE,CS_BSIM45_KERNEL_ROLE,0,0);
  r->residual[row]=residual;
 }
 for(int n=0;n<29;n++) {
  if(!isfinite(h->states[0][n]))return fail(h,CS_BSIM45_NONFINITE,CS_BSIM45_KERNEL_ROLE,0,0);
  r->states[n]=h->states[0][n];
 }
 r->token=(CSBSIM45TrialToken){(uintptr_t)h,++h->trialGeneration};
 h->trialReady=1;*out=*r;return CS_BSIM45_OK;
}
static int valid_trial(const CSBSIM45Owner *h,CSBSIM45TrialToken token) {
 return h&&h->state==2&&h->historyReady&&h->trialReady&&token.owner==(uintptr_t)h&&token.generation==h->trialGeneration;
}
CSBSIM45Status cs_bsim45_commit(CSBSIM45Owner *h,CSBSIM45TrialToken token) {
 if(!valid_trial(h,token))return CS_BSIM45_HISTORY;
 memcpy(h->states[2],h->states[1],sizeof(h->states[2]));
 memcpy(h->states[1],h->states[0],sizeof(h->states[1]));
 h->trialReady=0;return CS_BSIM45_OK;
}
CSBSIM45Status cs_bsim45_reject(CSBSIM45Owner *h,CSBSIM45TrialToken token) {
 if(!valid_trial(h,token))return CS_BSIM45_HISTORY;
 h->trialReady=0;return CS_BSIM45_OK;
}
CSBSIM45Status cs_bsim45_history(const CSBSIM45Owner *h,CSBSIM45History *out) {
 if(!h||!out)return CS_BSIM45_PARAMETER;
 if(!h->historyReady)return CS_BSIM45_HISTORY;
 memcpy(out->accepted,h->states[1],sizeof(out->accepted));
 memcpy(out->older,h->states[2],sizeof(out->older));return CS_BSIM45_OK;
}
