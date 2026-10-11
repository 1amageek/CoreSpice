/* One owner owns all scratch and publishes the complete physical matrix once.
   The original transient deficit diagonal is an isolated algebraic placeholder,
   not terminal admittance; do not expose it as a physical voltage equation. */
CSBSIM45Status cs_bsim45_evaluate_ac(CSBSIM45Owner *h,const double *bias,size_t count,double gmin,double omega,CSBSIM45ACResult *out) {
 invalidate_trial(h);
 if(!out||!isfinite(omega)||omega<0)return CS_BSIM45_PARAMETER;
 CSBSIM45Status status=cs_bsim45_evaluate_static(h,bias,count,gmin,h?&h->result:NULL);
 if(status!=CS_BSIM45_OK)return status;
 if(h->instance.BSIM4acnqsMod&&(!isfinite(h->instance.BSIM4taunet)||h->instance.BSIM4taunet<0))
  return fail(h,CS_BSIM45_NONFINITE,CS_BSIM45_KERNEL_ROLE,0,0);
 CKTcircuit *c=&h->circuit;c->CKTomega=omega;c->CKTmode=MODEAC;
 memset(&h->matrix,0,sizeof(h->matrix));
 if(h->instance.BSIM4acnqsMod&&BSIM4acLoad((GENmodel*)&h->model,c))return fail(h,CS_BSIM45_KERNEL,CS_BSIM45_KERNEL_ROLE,0,0);
 if(c->diagnosticOverflow)return fail(h,CS_BSIM45_DIAGNOSTICS,CS_BSIM45_KERNEL_ROLE,0,0);
 for(int r=0;r<13;r++)for(int col=0;col<13;col++) {
  int deficit=h->instance.BSIM4qNode;
  double real=(deficit&&(r==deficit||col==deficit))?0:h->matrix.values[r][col][0];
  double imaginary=(deficit&&(r==deficit||col==deficit))?0:h->matrix.values[r][col][1];
  /* QS has one derivative authority. Scaling the final qualified C avoids
     cancellation amplified by frequency in the original per-term AC stamp. */
  if(!h->instance.BSIM4acnqsMod){real=h->result.conductance[r*13+col];imaginary=omega*h->result.capacitance[r*13+col];}
  if(!isfinite(real)||!isfinite(imaginary))return fail(h,CS_BSIM45_NONFINITE,CS_BSIM45_KERNEL_ROLE,0,0);
  h->acResult.real[r*13+col]=real;h->acResult.imaginary[r*13+col]=imaginary;
 }
 *out=h->acResult;return CS_BSIM45_OK;
}
