/* Pinned SPICE3f5 thermal/shot laws; complex gains are borrowed for one call.
   Normalize before applying power so an unscaled squared gain cannot overflow. */
typedef struct { const double *real,*imaginary; CKTcircuit *circuit; int failed; } CSBSIM45NoiseContext;
static double cs_noise_project(CSBSIM45NoiseContext *context,int positive,int negative,double logPower,int zero) {
 if(positive<0||negative<0||positive>context->circuit->nodeCount||negative>context->circuit->nodeCount){context->failed=1;return NAN;}
 double real=context->real[positive]-context->real[negative],imaginary=context->imaginary[positive]-context->imaginary[negative];
 double scale=fmax(fabs(real),fabs(imaginary));if(zero||scale==0)return 0;
 double norm;
 if(isfinite(scale))norm=(real/scale)*(real/scale)+(imaginary/scale)*(imaginary/scale);
 else {
  scale=fmax(fmax(fabs(context->real[positive]),fabs(context->real[negative])),fmax(fabs(context->imaginary[positive]),fabs(context->imaginary[negative])));
  real=context->real[positive]/scale-context->real[negative]/scale;
  imaginary=context->imaginary[positive]/scale-context->imaginary[negative]/scale;norm=real*real+imaginary*imaginary;
 }
 double density=exp(logPower+2*log(scale)+log(norm));
 if(!isfinite(density)||density<=0){context->failed=1;return NAN;}return density;
}
static void cs_noise_single(double *density,double *logDensity,CSBSIM45NoiseContext *context,int type,int positive,int negative,double parameter) {
 if(!isfinite(parameter)||(type==THERMNOISE&&parameter<0)){context->failed=1;*density=NAN;return;}
 double power;
 if(type==THERMNOISE)power=log(4*CONSTboltz)+log(context->circuit->CKTtemp)+(parameter>0?log(parameter):0);
 else if(type==SHOTNOISE)power=log(2*CHARGE)+(parameter!=0?log(fabs(parameter)):0);
 else {context->failed=1;*density=NAN;return;}
 *density=cs_noise_project(context,positive,negative,power,parameter==0);
 if(logDensity)*logDensity=log(MAX(*density,N_MINLOG));
}
#define NevalSrc(a,b,c,d,e,f,g) cs_noise_single(a,b,&context,d,e,f,g)
