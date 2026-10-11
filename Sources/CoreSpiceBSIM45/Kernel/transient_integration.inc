/* Bounded SPICE3f5 BE/TR charge companions. Only the eight original charge
   pairs are integrable; voltage, deficit and dependent-source slots are not.
   The service writes scratch only and never changes accepted or older history. */
int NIintegrate(CKTcircuit *c,double *g,double *eq,double capacitance,int charge) {
 switch(charge){case 11:case 13:case 15:case 17:case 19:case 21:case 23:case 25:break;default:return E_BADPARM;}
 if(!g||!eq||!isfinite(capacitance))return E_BADPARM;
 double coefficient=c->CKTag[0],current=0;
 if(c->CKTmode==MODETRAN) {
  if((c->integrationMethod!=CS_BSIM45_BE&&c->integrationMethod!=CS_BSIM45_TRAPEZOIDAL)||
     !isfinite(coefficient)||coefficient<=0)return E_BADPARM;
  current=coefficient*(c->CKTstate0[charge]-c->CKTstate1[charge]);
  if(c->integrationMethod==CS_BSIM45_TRAPEZOIDAL)current-=c->CKTstate1[charge+1];
 } else if((c->CKTmode!=MODEDCOP&&c->CKTmode!=MODEINITSMSIG)||coefficient!=0)return E_BADPARM;
 double conductance=coefficient*capacitance,equivalent=current-coefficient*c->CKTstate0[charge];
 if(!isfinite(current)||!isfinite(conductance)||!isfinite(equivalent))return E_NONFINITE;
 c->CKTstate0[charge+1]=current;*g=conductance;*eq=equivalent;return OK;
}
