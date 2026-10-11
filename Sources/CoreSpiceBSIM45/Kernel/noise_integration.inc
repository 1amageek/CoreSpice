/* No sweep state or pointer is retained. Positive endpoint powers use the exact
   power-law interpolant; a zero endpoint explicitly selects linear PSD. */
static int valid_spectrum(const CSBSIM45NoiseSpectrum *s) {
 if(!s||!isfinite(s->frequency)||s->frequency<=0)return 0;
 double total=0;for(int n=0;n<13;n++){if(!isfinite(s->density[n])||s->density[n]<0)return 0;total+=s->density[n];}
 return isfinite(total)&&s->density[13]==total;
}
static double noise_log_ratio(double upper,double lower) {
 double relative=(upper-lower)/lower;
 return relative>-.5&&relative<.5?log1p(relative):log(upper)-log(lower);
}
CSBSIM45Status cs_bsim45_integrate_noise(const CSBSIM45NoiseSpectrum *lower,const CSBSIM45NoiseSpectrum *upper,CSBSIM45NoiseIntegral *out) {
 if(!out||!valid_spectrum(lower)||!valid_spectrum(upper)||upper->frequency<=lower->frequency)return CS_BSIM45_PARAMETER;
 CSBSIM45NoiseIntegral result={0};double span=noise_log_ratio(upper->frequency,lower->frequency);
 for(int n=0;n<13;n++){
  double a=lower->density[n],b=upper->density[n];if(a==0&&b==0)continue;
  double logarithm;
  if(a==0||b==0)logarithm=log(fmax(a,b))-log(2.)+log(upper->frequency-lower->frequency);
  else {
   double exponent=noise_log_ratio(b,a)+span;
   double factor=exponent==0?span:span*(-expm1(-fabs(exponent)))/fabs(exponent);
   logarithm=(exponent>=0?log(b)+log(upper->frequency):log(a)+log(lower->frequency))+log(factor);
  }
  double integral=exp(logarithm);if(!isfinite(integral)||integral<=0)return CS_BSIM45_NONFINITE;
  result.power[n]=integral;result.power[13]+=integral;
 }
 if(!isfinite(result.power[13]))return CS_BSIM45_NONFINITE;
 result.rmsVoltage=sqrt(result.power[13]);*out=result;return CS_BSIM45_OK;
}
