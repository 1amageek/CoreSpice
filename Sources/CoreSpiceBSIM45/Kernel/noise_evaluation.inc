extern int cs_bsim45_noise_density(BSIM4model *,BSIM4instance *,CKTcircuit *,double,const double *,const double *,double *);
CSBSIM45Status cs_bsim45_noise_spectrum(CSBSIM45Owner *h,const double *bias,size_t count,double gmin,double frequency,
 const double *real,const double *imaginary,CSBSIM45NoiseSpectrum *out) {
 invalidate_trial(h);
 if(!h||!bias||!real||!imaginary||!out||count!=13||!isfinite(frequency)||frequency<=0||!isfinite(gmin)||gmin<0)return CS_BSIM45_PARAMETER;
 if(h->state!=2)return CS_BSIM45_STATE;
 for(int n=0;n<13;n++)if(!isfinite(real[n])||!isfinite(imaginary[n])||
  ((n==0||n>h->circuit.nodeCount||n==h->instance.BSIM4qNode)&&(real[n]!=0||imaginary[n]!=0)))return CS_BSIM45_PARAMETER;
 if(!h->circuit.noiseRequested)return CS_BSIM45_NOISE_UNPREPARED;
 CSBSIM45Status status=cs_bsim45_evaluate_static(h,bias,count,gmin,&h->result);
 if(status!=CS_BSIM45_OK)return status;
 status=cs_bsim45_noise_density(&h->model,&h->instance,&h->circuit,frequency,real,imaginary,h->noiseResult.density);
 if(status!=CS_BSIM45_OK)return fail(h,status,CS_BSIM45_KERNEL_ROLE,0,0);
 h->noiseResult.frequency=frequency;*out=h->noiseResult;return CS_BSIM45_OK;
}
