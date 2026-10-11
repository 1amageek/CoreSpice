/* The owner contains all scratch; no caller pointer survives a call. All matrix
   indices originate in checked preparation topology (0...12). Output copying is
   confined to the atomic publication boundary after full finite validation. */
static void seed_exact_bias(CSBSIM45Owner *h) {
 BSIM4instance *i=&h->instance;const double *bias=h->bias;
 int positive[]={i->BSIM4bNodePrime,i->BSIM4bNodePrime,i->BSIM4gNodePrime,i->BSIM4dNodePrime,
  i->BSIM4dbNode,i->BSIM4dbNode,i->BSIM4sbNode,i->BSIM4gNodeExt,i->BSIM4gNodeMid,i->BSIM4sNode,i->BSIM4dNode};
 for(int n=0;n<11;n++)h->states[0][n]=h->model.BSIM4type*(bias[positive[n]]-bias[(n==0||n==5)?i->BSIM4dNodePrime:i->BSIM4sNodePrime]);
 h->states[0][27]=i->BSIM4qNode?h->model.BSIM4type*bias[i->BSIM4qNode]:0;
}
static void static_pair(CSBSIM45StaticResult *out,int positive,int negative,double q,double capacitance) {
 out->charge[positive]+=q;out->charge[negative]-=q;
 out->capacitance[positive*13+positive]+=capacitance;
 out->capacitance[positive*13+negative]-=capacitance;
 out->capacitance[negative*13+positive]-=capacitance;
 out->capacitance[negative*13+negative]+=capacitance;
}
static void static_charge(CSBSIM45Owner *h) {
 BSIM4instance *i=&h->instance;CSBSIM45StaticResult *out=&h->result;
 int nodes[]={i->BSIM4gNodePrime,i->BSIM4dNodePrime,i->BSIM4sNodePrime,i->BSIM4bNodePrime};
 if(i->BSIM4mode<0){int node=nodes[1];nodes[1]=nodes[2];nodes[2]=node;}
 double sign=h->model.BSIM4type;
 double charges[]={i->BSIM4qgate,i->BSIM4qdrn,i->BSIM4qsrc,i->BSIM4qbulk};
 double derivatives[4][4]={
  {i->BSIM4cggb,i->BSIM4cgdb,i->BSIM4cgsb,i->BSIM4cgbb},
  {i->BSIM4cdgb,i->BSIM4cddb,i->BSIM4cdsb,i->BSIM4cdbb},
  {i->BSIM4csgb,i->BSIM4csdb,i->BSIM4cssb,i->BSIM4csbb},
  {i->BSIM4cbgb,i->BSIM4cbdb,i->BSIM4cbsb,i->BSIM4cbbb}};
 for(int r=0;r<4;r++) {
  out->charge[nodes[r]]+=sign*charges[r];
  for(int col=0;col<4;col++)out->capacitance[nodes[r]*13+nodes[col]]+=derivatives[r][col];
 }
 int gate=i->BSIM4rgateMod==3?i->BSIM4gNodeMid:i->BSIM4gNodePrime;
 static_pair(out,gate,i->BSIM4dNodePrime,sign*i->BSIM4qgdo,i->BSIM4cgdo);
 static_pair(out,gate,i->BSIM4sNodePrime,sign*i->BSIM4qgso,i->BSIM4cgso);
 double cgbo=i->pParam->BSIM4cgbo;
 static_pair(out,gate,i->BSIM4bNodePrime,cgbo*(h->bias[gate]-h->bias[i->BSIM4bNodePrime]),cgbo);
 static_pair(out,i->BSIM4rbodyMod?i->BSIM4dbNode:i->BSIM4bNodePrime,i->BSIM4dNodePrime,
             sign*h->states[0][i->BSIM4qbd],i->BSIM4capbd);
 static_pair(out,i->BSIM4rbodyMod?i->BSIM4sbNode:i->BSIM4bNodePrime,i->BSIM4sNodePrime,
             sign*h->states[0][i->BSIM4qbs],i->BSIM4capbs);
}
CSBSIM45Status cs_bsim45_evaluate_static(CSBSIM45Owner *h,const double *bias,size_t count,double gmin,CSBSIM45StaticResult *out) {
 invalidate_trial(h);
 if(!h||!bias||!out||count!=13||!isfinite(gmin)||gmin<0)return CS_BSIM45_PARAMETER;
 if(h->state!=2)return CS_BSIM45_STATE;
 BSIM4instance *i=&h->instance;CKTcircuit *c=&h->circuit;
 for(int n=0;n<13;n++)if(!isfinite(bias[n])||((n==0||n>c->nodeCount||n==i->BSIM4qNode)&&bias[n]!=0))return CS_BSIM45_PARAMETER;
 memcpy(h->bias,bias,sizeof(h->bias));memset(h->states[0],0,sizeof(h->states[0]));
 memset(&h->matrix,0,sizeof(h->matrix));memset(h->rhs,0,sizeof(h->rhs));memset(&h->result,0,sizeof(h->result));
 c->CKTag[0]=0;c->CKTag[1]=0;c->integrationMethod=0;
 c->CKTgmin=gmin;c->CKTnoncon=0;c->CKTmode=MODEINITSMSIG;
 seed_exact_bias(h);
 int loadStatus=BSIM4load((GENmodel*)&h->model,c);
 if(loadStatus)return fail(h,loadStatus==E_NONFINITE?CS_BSIM45_NONFINITE:CS_BSIM45_KERNEL,CS_BSIM45_KERNEL_ROLE,0,0);
 c->CKTmode=MODEDCOP;memset(&h->matrix,0,sizeof(h->matrix));memset(h->rhs,0,sizeof(h->rhs));
 loadStatus=BSIM4load((GENmodel*)&h->model,c);
 if(loadStatus)return fail(h,loadStatus==E_NONFINITE?CS_BSIM45_NONFINITE:CS_BSIM45_KERNEL,CS_BSIM45_KERNEL_ROLE,0,0);
 for(int r=0;r<13;r++) {
  if(i->BSIM4qNode&&r==i->BSIM4qNode)continue;
  h->result.current[r]=-h->rhs[r];
  for(int col=0;col<13;col++) {
   if(i->BSIM4qNode&&col==i->BSIM4qNode)continue;
   double value=h->matrix.values[r][col][0];
   h->result.conductance[r*13+col]=value;h->result.current[r]+=value*bias[col];
  }
 }
 static_charge(h);
 if(c->diagnosticOverflow)return fail(h,CS_BSIM45_DIAGNOSTICS,CS_BSIM45_KERNEL_ROLE,0,0);
 const double *arrays[]={h->result.current,h->result.charge,h->result.conductance,h->result.capacitance};
 const int counts[]={13,13,169,169};
 for(int a=0;a<4;a++)for(int n=0;n<counts[a];n++)if(!isfinite(arrays[a][n]))return fail(h,CS_BSIM45_NONFINITE,CS_BSIM45_KERNEL_ROLE,0,0);
 *out=h->result;return CS_BSIM45_OK;
}
