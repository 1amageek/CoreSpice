/* Modified for CoreSpice: local original spectrum and scoped complex transfer primitive; no simulator noise history. */
/* ******************************************************************************
   *  BSIM4 4.8.3 released on 05/19/2025                                        *
   *  BSIM4 Model Equations                                                     *
   ******************************************************************************

   ******************************************************************************
   *  Copyright (c) 2025 University of California                               *
   *                                                                            *
   *  Project Directors: Prof. Sayeef Salahuddin and Prof. Chenming Hu          *
   *  Developers list: https://www.bsim.berkeley.edu/models/bsim4/auth_bsim4/   *
   ******************************************************************************/

/*
Licensed under Educational Community License, Version 2.0 (the "License"); you may
not use this file except in compliance with the License. You may obtain a copy of the license at
http://opensource.org/licenses/ECL-2.0
Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations
under the License.

BSIM4 model is supported by the members of Silicon Integration Initiative's Compact Model Coalition. A link to the most recent version of this
standard can be found at: http://www.si2.org/cmc
*/


/* Copyright 1990 Regents of the University of California.
   Derived from NevalSrc/NevalSrc2 (Gary W. Ng, Darsen Lu); Modified BSD.
   Copyright 1985 - 2018, Regents of the University of California and others

   Redistribution and use in source and binary forms, with or without modification,
   are permitted provided that the following conditions are met:

   1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.

   2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

   3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from this
   software without specific prior written permission.

   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
   AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
   IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
   ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
   LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
   CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
   SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
   INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
   CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
   ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
   POSSIBILITY OF SUCH DAMAGE.
*/
#include "bsim4def.h"
#include "../include/CoreSpiceBSIM4.h"
#define CONSTboltz 1.380649e-23
#define N_MINLOG 1e-38
#define SHOTNOISE 1
#define THERMNOISE 2
#define N_GAIN 3
/* All references borrow this synchronous call's inputs. Nothing escapes. */
typedef struct { CKTcircuit *circuit; const double *real,*imag; int failed; } CSBSIM4NoiseContext;
static int cs_noise_gain(CSBSIM4NoiseContext *context,int positive,int negative,double *real,double *imag) {
 if(positive<0||negative<0||positive>context->circuit->nodeCount||negative>context->circuit->nodeCount){context->failed=1;return 0;}
 *real=context->real[positive]-context->real[negative];
 *imag=context->imag[positive]-context->imag[negative];
 if(!isfinite(*real)||!isfinite(*imag)){context->failed=1;return 0;}return 1;
}
static void cs_noise_single(double *density,double *logDensity,CSBSIM4NoiseContext *context,int type,int positive,int negative,double parameter) {
 double real,imag;*density=NAN;
 if(!isfinite(parameter)||(type==THERMNOISE&&parameter<0)||!cs_noise_gain(context,positive,negative,&real,&imag)){context->failed=1;return;}
 double gain=real*real+imag*imag;
 switch(type){case SHOTNOISE:*density=gain*2*CHARGE*fabs(parameter);break;
 case THERMNOISE:*density=gain*4*CONSTboltz*context->circuit->CKTtemp*parameter;break;
 case N_GAIN:*density=gain;break;default:context->failed=1;return;}
 if(!isfinite(*density)||*density<0){context->failed=1;return;}
 if(logDensity)*logDensity=log(MAX(*density,N_MINLOG));
}
static void cs_noise_correlated(double *density,double *logDensity,CSBSIM4NoiseContext *context,int type,
 int positive1,int negative1,double parameter1,int positive2,int negative2,double parameter2,double phase) {
 double real1,imag1,real2,imag2;*density=NAN;
 if(!isfinite(parameter1)||parameter1<0||!isfinite(parameter2)||parameter2<0||!isfinite(phase)||
 !cs_noise_gain(context,positive1,negative1,&real1,&imag1)||!cs_noise_gain(context,positive2,negative2,&real2,&imag2)){context->failed=1;return;}
 double T0=sqrt(parameter1),T1=sqrt(parameter2),T2=T1*cos(phase),T3=T1*sin(phase);
 double realOut=T0*real1+T2*real2-T3*imag2;
 double imagOut=T0*imag1+T2*imag2+T3*real2;
 double gain=realOut*realOut+imagOut*imagOut;
 switch(type){case SHOTNOISE:*density=2*CHARGE*fabs(gain);break;
 case THERMNOISE:*density=4*CONSTboltz*context->circuit->CKTtemp*gain;break;
 case N_GAIN:*density=0;break;default:context->failed=1;return;}
 if(!isfinite(*density)||*density<0){context->failed=1;return;}
 if(logDensity)*logDensity=log(MAX(*density,N_MINLOG));
}
#define NevalSrc(a,b,c,d,e,f,g) cs_noise_single(a,b,&context,d,e,f,g)
#define NevalSrc2(a,b,c,d,e,f,g,h,i,j,k) cs_noise_correlated(a,b,&context,d,e,f,g,h,i,j,k)

static double
Eval1ovFNoise(Vds, model, here, freq, temp)
double Vds, freq, temp;
BSIM4model *model;
BSIM4instance *here;
{
struct bsim4SizeDependParam *pParam;
double cd, esat, DelClm, EffFreq, N0, Nl, Leff, Leffsq;
double T0, T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13, Ssi;

    pParam = here->pParam;
    cd = fabs(here->BSIM4cd);
    Leff = pParam->BSIM4leff - 2.0 * model->BSIM4lintnoi;
    Leffsq = Leff * Leff;
    esat = 2.0 * here->BSIM4vsattemp / here->BSIM4ueff;
    if(model->BSIM4em<=0.0) DelClm = 0.0; /* flicker noise modified -JX  */
    else {
        T0 = ((((Vds - here->BSIM4Vdseff) / pParam->BSIM4litl)
            + model->BSIM4em) / esat);
        DelClm = pParam->BSIM4litl * log (MAX(T0, N_MINLOG));
        if (DelClm < 0.0)   DelClm = 0.0;  /* bugfix */
    }
    EffFreq = pow(freq, model->BSIM4ef);
    T1 = CHARGE * CHARGE * CONSTboltz * cd * temp * here->BSIM4ueff;
    T2 = 1.0e10 * EffFreq * here->BSIM4Abulk * model->BSIM4coxe * Leffsq;
    N0 = model->BSIM4coxe * here->BSIM4Vgsteff / CHARGE;
    Nl = model->BSIM4coxe * here->BSIM4Vgsteff
       * (1.0 - here->BSIM4AbovVgst2Vtm * here->BSIM4Vdseff) / CHARGE;

    T3 = model->BSIM4oxideTrapDensityA
       * log(MAX(((N0 + here->BSIM4nstar) / (Nl + here->BSIM4nstar)), N_MINLOG));
    T4 = model->BSIM4oxideTrapDensityB * (N0 - Nl);
    T5 = model->BSIM4oxideTrapDensityC * 0.5 * (N0 * N0 - Nl * Nl);

    T6 = CONSTboltz * temp * cd * cd;
    T7 = 1.0e10 * EffFreq * Leffsq * pParam->BSIM4weff * here->BSIM4nf;
    T8 = model->BSIM4oxideTrapDensityA + model->BSIM4oxideTrapDensityB * Nl
       + model->BSIM4oxideTrapDensityC * Nl * Nl;
    T9 = (Nl + here->BSIM4nstar) * (Nl + here->BSIM4nstar);
    Ssi = T1 / T2 * (T3 + T4 + T5) + T6 / T7 * DelClm * T8 / T9;
    return Ssi;
}



int cs_bsim4_noise_density(BSIM4model *model, BSIM4instance *here,
 CKTcircuit *ckt, double frequency, const double real[13], const double imag[13], double noizDens[14]) {
 struct bsim4SizeDependParam *pParam=here->pParam;
 CSBSIM4NoiseContext context={ckt,real,imag,0};
 double lnNdens[14];
 double T0,T1,T2,T3,T4,T5,T6,T7,T8,T9,T10,T11,T12,T13;
 double Vds,n,ExpArg,Ssi,Swi,tmp,gdpr,gspr,npart_theta,npart_beta,igsquare,bodymode;
 double eta,Leff,Lvsat,gamma,delta,epsilon,GammaGd0,npart_c,sigrat,C0,omega,ctnoi,tau;
 double mult_i=here->BSIM4mult_i,mult_fn=here->BSIM4mult_fn;
 double frequencyPower=pow(frequency,model->BSIM4ef);
 if (!isfinite(frequencyPower) || frequencyPower<=0 || (model->BSIM4fnoiMod==1 && pParam->BSIM4leff-2*model->BSIM4lintnoi<=0)) return CS_BSIM4_NUMERICAL;
if (model->BSIM4tnoiMod == 0)
                  {   if (model->BSIM4rdsMod == 0)
                  {   gspr = here->BSIM4sourceConductance;
                                      gdpr = here->BSIM4drainConductance;
                      if (here->BSIM4grdsw > 0.0)
                          tmp = 1.0 / here->BSIM4grdsw; /* tmp used below */
                      else
                      tmp = 0.0;
                  }
                  else
                  {   gspr = here->BSIM4gstot;
                                      gdpr = here->BSIM4gdtot;
                                      tmp = 0.0;
                  }
                  }
                  else if(model->BSIM4tnoiMod == 1)
                  {   T5 = here->BSIM4Vgsteff / here->BSIM4EsatL;
                  T5 *= T5;
                  npart_beta = model->BSIM4rnoia * (1.0 + T5
                         * model->BSIM4tnoia * pParam->BSIM4leff);
                  npart_theta = model->BSIM4rnoib * (1.0 + T5
                                              * model->BSIM4tnoib * pParam->BSIM4leff);
                  if(npart_theta > 0.9)
                     npart_theta = 0.9;
                  if(npart_theta > 0.9 * npart_beta)
                     npart_theta = 0.9 * npart_beta; //4.6.2

                  if (model->BSIM4rdsMod == 0)
                                  {   gspr = here->BSIM4sourceConductance;
                                      gdpr = here->BSIM4drainConductance;
                                  }
                                  else
                                  {   gspr = here->BSIM4gstot;
                                      gdpr = here->BSIM4gdtot;
                                  }

                  if ((*(ckt->CKTstates[0] + here->BSIM4vds)) >= 0.0)
                          gspr = gspr * (1.0 + npart_theta * npart_theta * gspr
                           / here->BSIM4IdovVds);
                  else
                      gdpr = gdpr * (1.0 + npart_theta * npart_theta * gdpr
                                           / here->BSIM4IdovVds);
                  }
                  else
                  {   /* tnoiMod=2 (v4.7) */

                  if (model->BSIM4rdsMod == 0)
                                  {   gspr = here->BSIM4sourceConductance;
                                      gdpr = here->BSIM4drainConductance;
                                  }
                                  else
                                  {   gspr = here->BSIM4gstot;
                                      gdpr = here->BSIM4gdtot;
                                  }

                  }

                      NevalSrc(&noizDens[BSIM4RDNOIZ],
                       &lnNdens[BSIM4RDNOIZ], ckt, THERMNOISE,
                       here->BSIM4dNodePrime, here->BSIM4dNode,
                       gdpr * mult_i);

                      NevalSrc(&noizDens[BSIM4RSNOIZ],
                       &lnNdens[BSIM4RSNOIZ], ckt, THERMNOISE,
                       here->BSIM4sNodePrime, here->BSIM4sNode,
                       gspr * mult_i);


                  if (here->BSIM4rgateMod == 1)
                  {   NevalSrc(&noizDens[BSIM4RGNOIZ],
                                       &lnNdens[BSIM4RGNOIZ], ckt, THERMNOISE,
                                       here->BSIM4gNodePrime, here->BSIM4gNodeExt,
                                       here->BSIM4grgeltd * mult_i);
                  }
                  else if (here->BSIM4rgateMod == 2)
                  {
                T0 = 1.0 + here->BSIM4grgeltd/here->BSIM4gcrg;
                T1 = T0 * T0;
                  NevalSrc(&noizDens[BSIM4RGNOIZ],
                                       &lnNdens[BSIM4RGNOIZ], ckt, THERMNOISE,
                                       here->BSIM4gNodePrime, here->BSIM4gNodeExt,
                                       here->BSIM4grgeltd * mult_i/T1);
                  }
                  else if (here->BSIM4rgateMod == 3)
                  {   NevalSrc(&noizDens[BSIM4RGNOIZ],
                                       &lnNdens[BSIM4RGNOIZ], ckt, THERMNOISE,
                                       here->BSIM4gNodeMid, here->BSIM4gNodeExt,
                                       here->BSIM4grgeltd * mult_i);
                  }
                  else
                  {    noizDens[BSIM4RGNOIZ] = 0.0;
                                   lnNdens[BSIM4RGNOIZ] =
                                          log(MAX(noizDens[BSIM4RGNOIZ], N_MINLOG));
                  }

                      bodymode = 5;
                      if (here->BSIM4rbodyMod == 2)
                      { if( ( !model->BSIM4rbps0Given) ||
                    ( !model->BSIM4rbpd0Given) )
                        bodymode = 1;
                        else
                    if( (!model->BSIM4rbsbx0Given && !model->BSIM4rbsby0Given) ||
                        (!model->BSIM4rbdbx0Given && !model->BSIM4rbdby0Given) )
                    bodymode = 3;
                  }

                              if (here->BSIM4rbodyMod)
                              {
                if(bodymode == 5)
                  {
                    NevalSrc(&noizDens[BSIM4RBPSNOIZ],
                         &lnNdens[BSIM4RBPSNOIZ], ckt, THERMNOISE,
                         here->BSIM4bNodePrime, here->BSIM4sbNode,
                         here->BSIM4grbps * mult_i);
                    NevalSrc(&noizDens[BSIM4RBPDNOIZ],
                         &lnNdens[BSIM4RBPDNOIZ], ckt, THERMNOISE,
                         here->BSIM4bNodePrime, here->BSIM4dbNode,
                         here->BSIM4grbpd * mult_i);
                    NevalSrc(&noizDens[BSIM4RBPBNOIZ],
                         &lnNdens[BSIM4RBPBNOIZ], ckt, THERMNOISE,
                         here->BSIM4bNodePrime, here->BSIM4bNode,
                         here->BSIM4grbpb * mult_i);
                    NevalSrc(&noizDens[BSIM4RBSBNOIZ],
                         &lnNdens[BSIM4RBSBNOIZ], ckt, THERMNOISE,
                         here->BSIM4bNode, here->BSIM4sbNode,
                         here->BSIM4grbsb * mult_i);
                    NevalSrc(&noizDens[BSIM4RBDBNOIZ],
                         &lnNdens[BSIM4RBDBNOIZ], ckt, THERMNOISE,
                         here->BSIM4bNode, here->BSIM4dbNode,
                         here->BSIM4grbdb * mult_i);
                  }
                if(bodymode == 3)
                  {
                    NevalSrc(&noizDens[BSIM4RBPSNOIZ],
                         &lnNdens[BSIM4RBPSNOIZ], ckt, THERMNOISE,
                         here->BSIM4bNodePrime, here->BSIM4sbNode,
                         here->BSIM4grbps * mult_i);
                    NevalSrc(&noizDens[BSIM4RBPDNOIZ],
                         &lnNdens[BSIM4RBPDNOIZ], ckt, THERMNOISE,
                         here->BSIM4bNodePrime, here->BSIM4dbNode,
                         here->BSIM4grbpd * mult_i);
                    NevalSrc(&noizDens[BSIM4RBPBNOIZ],
                         &lnNdens[BSIM4RBPBNOIZ], ckt, THERMNOISE,
                         here->BSIM4bNodePrime, here->BSIM4bNode,
                         here->BSIM4grbpb * mult_i);
                     noizDens[BSIM4RBSBNOIZ] = noizDens[BSIM4RBDBNOIZ] = 0.0;
                     lnNdens[BSIM4RBSBNOIZ] =
                       log(MAX(noizDens[BSIM4RBSBNOIZ], N_MINLOG));
                     lnNdens[BSIM4RBDBNOIZ] =
                       log(MAX(noizDens[BSIM4RBDBNOIZ], N_MINLOG));
                  }
                if(bodymode == 1)
                  {
                    NevalSrc(&noizDens[BSIM4RBPBNOIZ],
                         &lnNdens[BSIM4RBPBNOIZ], ckt, THERMNOISE,
                         here->BSIM4bNodePrime, here->BSIM4bNode,
                         here->BSIM4grbpb * mult_i);
                    noizDens[BSIM4RBPSNOIZ] = noizDens[BSIM4RBPDNOIZ] = 0.0;
                    noizDens[BSIM4RBSBNOIZ] = noizDens[BSIM4RBDBNOIZ] = 0.0;
                    lnNdens[BSIM4RBPSNOIZ] =
                      log(MAX(noizDens[BSIM4RBPSNOIZ], N_MINLOG));
                    lnNdens[BSIM4RBPDNOIZ] =
                      log(MAX(noizDens[BSIM4RBPDNOIZ], N_MINLOG));
                    lnNdens[BSIM4RBSBNOIZ] =
                      log(MAX(noizDens[BSIM4RBSBNOIZ], N_MINLOG));
                    lnNdens[BSIM4RBDBNOIZ] =
                      log(MAX(noizDens[BSIM4RBDBNOIZ], N_MINLOG));
                  }
                              }
                              else
                              {   noizDens[BSIM4RBPSNOIZ] = noizDens[BSIM4RBPDNOIZ] = 0.0;
                                  noizDens[BSIM4RBPBNOIZ] = 0.0;
                                  noizDens[BSIM4RBSBNOIZ] = noizDens[BSIM4RBDBNOIZ] = 0.0;
                                  lnNdens[BSIM4RBPSNOIZ] =
                                          log(MAX(noizDens[BSIM4RBPSNOIZ], N_MINLOG));
                                  lnNdens[BSIM4RBPDNOIZ] =
                                          log(MAX(noizDens[BSIM4RBPDNOIZ], N_MINLOG));
                                  lnNdens[BSIM4RBPBNOIZ] =
                                          log(MAX(noizDens[BSIM4RBPBNOIZ], N_MINLOG));
                                  lnNdens[BSIM4RBSBNOIZ] =
                                          log(MAX(noizDens[BSIM4RBSBNOIZ], N_MINLOG));
                                  lnNdens[BSIM4RBDBNOIZ] =
                                          log(MAX(noizDens[BSIM4RBDBNOIZ], N_MINLOG));
                              }

                  if(model->BSIM4tnoiMod == 2)
                  {
                                  eta = 1.0 - here->BSIM4Vdseff * here->BSIM4AbovVgst2Vtm;
                                  T0 = 1.0 - eta;
                                  T1 = 1.0 + eta;
                                  T2 = T1 + 2.0 * here->BSIM4Abulk * model->BSIM4vtm / here->BSIM4Vgsteff;
                  Leff = pParam->BSIM4leff;
                                  Lvsat = Leff * (1.0 + here->BSIM4Vdseff / here->BSIM4EsatL);
                                  T6 = Leff / Lvsat;
                                  /*Unwanted code for T5 commented*/
                                  /*T5 = here->BSIM4Vgsteff / here->BSIM4EsatL;
                                  T5 = T5 * T5;
                                  */
                                  gamma = T6 * (0.5 * T1 + T0 * T0 / (6.0 * T2));
                                  T3 = T2 * T2;
                                  T4 = T0 * T0;
                                  T5 = T3 * T3;
                                  delta = (T1 / T3 - (5.0 * T1 + T2) * T4 / (15.0 * T5) + T4 * T4 / (9.0 * T5 * T2)) / (6.0 * T6 * T6 * T6);
                                  T7 = T0 / T2;
                                  epsilon = (T7 - T7 * T7 * T7 / 3.0) / (6.0 * T6);
                              T8 = here->BSIM4Vgsteff / here->BSIM4EsatL;
                              T8 *= T8;
                              if(model->BSIM4version<=4.80){
                              npart_c = model->BSIM4rnoic * (1.0 + T8
                                      * model->BSIM4tnoic * Leff);
                                  ctnoi = epsilon / sqrt(gamma * delta)
                                  * (2.5316 * npart_c);

                              npart_beta = model->BSIM4rnoia * (1.0 + T8
                                  * model->BSIM4tnoia * Leff);
                              npart_theta = model->BSIM4rnoib * (1.0 + T8
                                  * model->BSIM4tnoib * Leff);
                              gamma = gamma * (3.0 * npart_beta * npart_beta);
                              delta = delta * (3.75 * npart_theta * npart_theta);

                              GammaGd0 = gamma * here->BSIM4noiGd0;
                                  C0 = here->BSIM4Coxeff * pParam->BSIM4weffCV * here->BSIM4nf * pParam->BSIM4leffCV;
                              T0 = C0 / here->BSIM4noiGd0;
                              sigrat = T0 * sqrt(delta / gamma);
                              }
                              else
                              {npart_c = model->BSIM4rnoic * (1.0 + T8
                                      * model->BSIM4tnoic * Leff);
                  /* Limits added for rnoia, rnoib, rnoic, tnoia, tnoib and tnoic in BSIM4.8.1 */
                  T9 = gamma * delta ;
 if (!isfinite(gamma) || !isfinite(delta) || !isfinite(epsilon) || !isfinite(T9)) return CS_BSIM4_NUMERICAL;
                  if (T9 > 0)
                      ctnoi   = epsilon / sqrt( gamma * delta) * (2.5316 * npart_c);
                  else
                      ctnoi   = 1.0 ;
                  if (ctnoi > 1)
                      ctnoi=1;
                  if (ctnoi < 0)
                      ctnoi=0;

                  npart_beta = model->BSIM4rnoia * (1.0 + T8
                                  * model->BSIM4tnoia * Leff);
                              npart_theta = model->BSIM4rnoib * (1.0 + T8
                                  * model->BSIM4tnoib * Leff);
                              gamma = gamma * (3.0 * npart_beta * npart_beta);
                              delta = delta * (3.75 * npart_theta * npart_theta);

                              GammaGd0 = gamma * here->BSIM4noiGd0;
                                  C0 = here->BSIM4Coxeff * pParam->BSIM4weffCV * here->BSIM4nf * pParam->BSIM4leffCV;
                              T0 = C0 / here->BSIM4noiGd0;

                  if (gamma > 0 && delta > 0)
                      sigrat = T0 * sqrt(delta / gamma);
                  else
                      sigrat = 0.0;
                                }
                          }
                              switch(model->BSIM4tnoiMod)
                  {  case 0:
                    if(model->BSIM4version<=4.80)
                    {
                      T0 = here->BSIM4ueff * FABS(here->BSIM4qinv);
                      T1 = T0 * tmp + pParam->BSIM4leff
                                         * pParam->BSIM4leff;
                              NevalSrc(&noizDens[BSIM4IDNOIZ],
                               &lnNdens[BSIM4IDNOIZ], ckt,
                           THERMNOISE, here->BSIM4dNodePrime,
                                               here->BSIM4sNodePrime,
                           (T0 / T1) * model->BSIM4ntnoi * mult_i);
                    }
                    else
                    {
                    T0 = here->BSIM4ueff * FABS(here->BSIM4qinv);
                        T1 = T0 * tmp + pParam->BSIM4leff
                                * pParam->BSIM4leff;
                        NevalSrc(&noizDens[BSIM4IDNOIZ],
                                &lnNdens[BSIM4IDNOIZ], ckt,
                                THERMNOISE, here->BSIM4dNodePrime,
                                here->BSIM4sNodePrime,
                                (T0 / T1) * model->BSIM4ntnoi * mult_i);

                        noizDens[BSIM4CORLNOIZ] = 0.0;
                        lnNdens[BSIM4CORLNOIZ] = log(MAX(noizDens[BSIM4CORLNOIZ], N_MINLOG));
                    }
                      break;
                 case 1:
                 if(model->BSIM4version<=4.80)
                 {
                      T0 = here->BSIM4gm + here->BSIM4gmbs + here->BSIM4gds;
                      T0 *= T0;
                      igsquare = npart_theta * npart_theta * T0 / here->BSIM4IdovVds;
                      T1 = npart_beta * (here->BSIM4gm
                     + here->BSIM4gmbs) + here->BSIM4gds;
                      T2 = T1 * T1 / here->BSIM4IdovVds;
                                      NevalSrc(&noizDens[BSIM4IDNOIZ],
                                               &lnNdens[BSIM4IDNOIZ], ckt,
                                               THERMNOISE, here->BSIM4dNodePrime,
                                               here->BSIM4sNodePrime, (T2 - igsquare) * mult_i);
                 }
                 else
                 {
                T0 = here->BSIM4gm + here->BSIM4gmbs + here->BSIM4gds;
                        T0 *= T0;
                        igsquare = npart_theta * npart_theta * T0 / here->BSIM4IdovVds;
                        T1 = npart_beta * (here->BSIM4gm
                        + here->BSIM4gmbs) + here->BSIM4gds;
                        T2 = T1 * T1 / here->BSIM4IdovVds;
                        NevalSrc(&noizDens[BSIM4IDNOIZ],
                                &lnNdens[BSIM4IDNOIZ], ckt,
                                THERMNOISE, here->BSIM4dNodePrime,
                                here->BSIM4sNodePrime, (T2 - igsquare) * mult_i);

                        noizDens[BSIM4CORLNOIZ] = 0.0;
                        lnNdens[BSIM4CORLNOIZ] = log(MAX(noizDens[BSIM4CORLNOIZ], N_MINLOG));
                 }
                                      break;
                                  case 2:
                      T2 = GammaGd0;
                                      T3 = ctnoi * ctnoi;
                                      T4 = 1.0 - T3;
                                      NevalSrc(&noizDens[BSIM4IDNOIZ],
                                               &lnNdens[BSIM4IDNOIZ], ckt,
                                               THERMNOISE, here->BSIM4dNodePrime,
                                               here->BSIM4sNodePrime, T2 * T4 * mult_i);

                     /* Evaluate output noise due to two correlated noise sources */
                     omega = 2.0 * M_PI * frequency;
                     T5 = omega * sigrat;
                     T6 = T5 * T5;
                     T7 = T6 / (1.0 + T6);

                                     if (here->BSIM4mode >= 0)  {
                                         NevalSrc2(&noizDens[BSIM4CORLNOIZ],
                                               &lnNdens[BSIM4CORLNOIZ], ckt,
                                               THERMNOISE, here->BSIM4dNodePrime,
                                               here->BSIM4sNodePrime, T2 * T3 * mult_i,
                           here->BSIM4gNodePrime,
                           here->BSIM4sNodePrime,
                           T2 * T7 * mult_i, 0.5 * M_PI);
                     }
                     else
                     {
                                         NevalSrc2(&noizDens[BSIM4CORLNOIZ],
                                               &lnNdens[BSIM4CORLNOIZ], ckt,
                                               THERMNOISE, here->BSIM4sNodePrime,
                                               here->BSIM4dNodePrime, T2 * T3 * mult_i,
                           here->BSIM4gNodePrime,
                           here->BSIM4dNodePrime,
                           T2 * T7 * mult_i, 0.5 * M_PI);
                     }
                                     break;
                  }

                      NevalSrc(&noizDens[BSIM4FLNOIZ], (double*) NULL,
                       ckt, N_GAIN, here->BSIM4dNodePrime,
                       here->BSIM4sNodePrime, (double) 0.0);

                              switch(model->BSIM4fnoiMod)
                  {  case 0:
                          noizDens[BSIM4FLNOIZ] *= mult_fn * model->BSIM4kf
                        * exp(model->BSIM4af
                        * log(MAX(FABS(here->BSIM4cd),
                        N_MINLOG)))
                        / (pow(frequency, model->BSIM4ef)
                        * pParam->BSIM4leff
                            * pParam->BSIM4leff
                        * model->BSIM4coxe);
                      break;
                     case 1:
                              Vds = *(ckt->CKTstates[0] + here->BSIM4vds);
                          if (Vds < 0.0)
                              Vds = -Vds;

                                      Ssi = Eval1ovFNoise(Vds, model, here,
                                          frequency, ckt->CKTtemp);
                                      T10 = model->BSIM4oxideTrapDensityA
                                          * CONSTboltz * ckt->CKTtemp;
                                      T11 = pParam->BSIM4weff * here->BSIM4nf * pParam->BSIM4leff
                                          * pow(frequency, model->BSIM4ef) * 1.0e10
                      * here->BSIM4nstar * here->BSIM4nstar;
                                      Swi = T10 / T11 * here->BSIM4cd
                                          * here->BSIM4cd;
                                      T1 = Swi + Ssi;
 if (!isfinite(Ssi) || !isfinite(Swi) || !isfinite(T1)) return CS_BSIM4_NUMERICAL;
                                      if (T1 > 0.0)
                                          noizDens[BSIM4FLNOIZ] *= mult_fn * (Ssi * Swi) / T1;
                                      else
                                          noizDens[BSIM4FLNOIZ] *= 0.0;
                      break;
                  }

                      lnNdens[BSIM4FLNOIZ] =
                     log(MAX(noizDens[BSIM4FLNOIZ], N_MINLOG));


                        if(here->BSIM4mode >= 0) {  /* bugfix  */
                              NevalSrc(&noizDens[BSIM4IGSNOIZ],
                                   &lnNdens[BSIM4IGSNOIZ], ckt, SHOTNOISE,
                                   here->BSIM4gNodePrime, here->BSIM4sNodePrime,
                                   mult_i * (here->BSIM4Igs + here->BSIM4Igcs));
                              NevalSrc(&noizDens[BSIM4IGDNOIZ],
                                   &lnNdens[BSIM4IGDNOIZ], ckt, SHOTNOISE,
                                   here->BSIM4gNodePrime, here->BSIM4dNodePrime,
                                   mult_i * (here->BSIM4Igd + here->BSIM4Igcd));
            } else {
                              NevalSrc(&noizDens[BSIM4IGSNOIZ],
                                   &lnNdens[BSIM4IGSNOIZ], ckt, SHOTNOISE,
                                   here->BSIM4gNodePrime, here->BSIM4sNodePrime,
                                   mult_i * (here->BSIM4Igs + here->BSIM4Igcd));
                              NevalSrc(&noizDens[BSIM4IGDNOIZ],
                                   &lnNdens[BSIM4IGDNOIZ], ckt, SHOTNOISE,
                                   here->BSIM4gNodePrime, here->BSIM4dNodePrime,
                                   mult_i * (here->BSIM4Igd + here->BSIM4Igcs));
                        }
                              NevalSrc(&noizDens[BSIM4IGBNOIZ],
                                   &lnNdens[BSIM4IGBNOIZ], ckt, SHOTNOISE,
                                   here->BSIM4gNodePrime, here->BSIM4bNodePrime,
                                   mult_i * here->BSIM4Igb);



 if(context.failed) return CS_BSIM4_NUMERICAL;
 for(int index=0;index<14;index++) if(!isfinite(noizDens[index])||noizDens[index]<0) return CS_BSIM4_NUMERICAL;
 return CS_BSIM4_OK;
}
