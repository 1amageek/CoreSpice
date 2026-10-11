/* Modified for CoreSpice: exact local noise with scoped transfer gains; no simulator sweep/history. */
#include "bsim4def.h"
/**** BSIM4.5.0 Released by Xuemei (Jane) Xi 07/29/2005 ****/

/**********
 * Copyright 2005 Regents of the University of California. All rights reserved.
 * File: b4noi.c of BSIM4.5.0.
 * Author: 2000 Weidong Liu
 * Authors: 2001- Xuemei Xi, Mohan Dunga, Ali Niknejad, Chenming Hu.
 * Project Director: Prof. Chenming Hu.
 * Modified by Xuemei Xi, 04/06/2001.
 * Modified by Xuemei Xi, 10/05/2001.
 * Modified by Xuemei Xi, 11/15/2002.
 * Modified by Xuemei Xi, 05/09/2003.
 * Modified by Xuemei Xi, 03/04/2004.
 * Modified by Xuemei Xi, 07/29/2005.
 **********/

















/*
 * WDL: 1/f noise model has been smoothed out and enhanced with
 * bulk charge effect as well as physical N* equ. and necessary
 * conversion into the SI unit system.
 */

double
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
        if (DelClm < 0.0)       DelClm = 0.0;  /* bugfix */
    }
    EffFreq = pow(freq, model->BSIM4ef);
    T1 = CHARGE * CHARGE * CONSTboltz * cd * temp * here->BSIM4ueff;
    T2 = 1.0e10 * EffFreq * here->BSIM4Abulk * model->BSIM4coxe * Leffsq;
    N0 = model->BSIM4coxe * here->BSIM4Vgsteff / CHARGE;
    Nl = model->BSIM4coxe * here->BSIM4Vgsteff
       * (1.0 - here->BSIM4AbovVgst2Vtm * here->BSIM4Vdseff) / CHARGE;

    T3 = model->BSIM4oxideTrapDensityA
       * log1p((N0-Nl)/(Nl+here->BSIM4nstar));
    T4 = model->BSIM4oxideTrapDensityB * (N0 - Nl);
    T5 = model->BSIM4oxideTrapDensityC * 0.5 * ((N0-Nl)*(N0+Nl));

    T6 = CONSTboltz * temp * cd * cd;
    T7 = 1.0e10 * EffFreq * Leffsq * pParam->BSIM4weff * here->BSIM4nf;
    T8 = model->BSIM4oxideTrapDensityA + model->BSIM4oxideTrapDensityB * Nl
       + model->BSIM4oxideTrapDensityC * Nl * Nl;
    T9 = (Nl + here->BSIM4nstar) * (Nl + here->BSIM4nstar);
    Ssi = T1 / T2 * (T3 + T4 + T5) + T6 / T7 * DelClm * T8 / T9;
    return Ssi;
}


#include "noise_primitives.inc"
int cs_bsim45_noise_density(BSIM4model *model,BSIM4instance *here,CKTcircuit *ckt,double frequency,
 const double *real,const double *imaginary,double noizDens[14]) {
 CSBSIM45NoiseContext context={real,imaginary,ckt,0};
 struct bsim4SizeDependParam *pParam=here->pParam;double lnNdens[14];
 double T0,T1,T2,T3,T4,T5,T6,T7,T8,T9,T10,T11,T12,T13,Vds,n,ExpArg,Ssi,Swi;
 double tmp,gdpr,gspr,npart_theta,npart_beta,igsquare,bodymode;
 if(model->BSIM4fnoiMod==1&&pParam->BSIM4leff-2*model->BSIM4lintnoi<=0)return CS_BSIM45_NONFINITE;
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
                              else
                              {   T5 = here->BSIM4Vgsteff / here->BSIM4EsatL;
                                  T5 *= T5;
                                  npart_beta = model->BSIM4rnoia * (1.0 + T5
                                             * model->BSIM4tnoia * pParam->BSIM4leff);
                                  npart_theta = model->BSIM4rnoib * (1.0 + T5
                                              * model->BSIM4tnoib * pParam->BSIM4leff);

                                  if (model->BSIM4rdsMod == 0)
                                  {   gspr = here->BSIM4sourceConductance;
                                      gdpr = here->BSIM4drainConductance;
                                  }
                                  else
                                  {   gspr = here->BSIM4gstot;
                                      gdpr = here->BSIM4gdtot;
                                  }

                                  if ((*(ckt->CKTstates[0] + here->BSIM4vds)) >= 0.0)
                                      gspr = gspr / (1.0 + npart_theta * npart_theta * gspr
                                           / here->BSIM4IdovVds);  /* bugfix */
                                  else
                                      gdpr = gdpr / (1.0 + npart_theta * npart_theta * gdpr
                                           / here->BSIM4IdovVds);
                              }

                              NevalSrc(&noizDens[BSIM4RDNOIZ],
                                       &lnNdens[BSIM4RDNOIZ], ckt, THERMNOISE,
                                       here->BSIM4dNodePrime, here->BSIM4dNode,
                                       gdpr);

                              NevalSrc(&noizDens[BSIM4RSNOIZ],
                                       &lnNdens[BSIM4RSNOIZ], ckt, THERMNOISE,
                                       here->BSIM4sNodePrime, here->BSIM4sNode,
                                       gspr);


                              if ((here->BSIM4rgateMod == 1) || (here->BSIM4rgateMod == 2))
                              {   NevalSrc(&noizDens[BSIM4RGNOIZ],
                                       &lnNdens[BSIM4RGNOIZ], ckt, THERMNOISE,
                                       here->BSIM4gNodePrime, here->BSIM4gNodeExt,
                                       here->BSIM4grgeltd);
                              }
                              else if (here->BSIM4rgateMod == 3)
                              {   NevalSrc(&noizDens[BSIM4RGNOIZ],
                                       &lnNdens[BSIM4RGNOIZ], ckt, THERMNOISE,
                                       here->BSIM4gNodeMid, here->BSIM4gNodeExt,
                                       here->BSIM4grgeltd);
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
                                             here->BSIM4grbps);
                                    NevalSrc(&noizDens[BSIM4RBPDNOIZ],
                                             &lnNdens[BSIM4RBPDNOIZ], ckt, THERMNOISE,
                                             here->BSIM4bNodePrime, here->BSIM4dbNode,
                                             here->BSIM4grbpd);
                                    NevalSrc(&noizDens[BSIM4RBPBNOIZ],
                                             &lnNdens[BSIM4RBPBNOIZ], ckt, THERMNOISE,
                                             here->BSIM4bNodePrime, here->BSIM4bNode,
                                             here->BSIM4grbpb);
                                    NevalSrc(&noizDens[BSIM4RBSBNOIZ],
                                             &lnNdens[BSIM4RBSBNOIZ], ckt, THERMNOISE,
                                             here->BSIM4bNode, here->BSIM4sbNode,
                                             here->BSIM4grbsb);
                                    NevalSrc(&noizDens[BSIM4RBDBNOIZ],
                                             &lnNdens[BSIM4RBDBNOIZ], ckt, THERMNOISE,
                                             here->BSIM4bNode, here->BSIM4dbNode,
                                             here->BSIM4grbdb);
                                  }
                                if(bodymode == 3)
                                  {
                                    NevalSrc(&noizDens[BSIM4RBPSNOIZ],
                                             &lnNdens[BSIM4RBPSNOIZ], ckt, THERMNOISE,
                                             here->BSIM4bNodePrime, here->BSIM4sbNode,
                                             here->BSIM4grbps);
                                    NevalSrc(&noizDens[BSIM4RBPDNOIZ],
                                             &lnNdens[BSIM4RBPDNOIZ], ckt, THERMNOISE,
                                             here->BSIM4bNodePrime, here->BSIM4dbNode,
                                             here->BSIM4grbpd);
                                    NevalSrc(&noizDens[BSIM4RBPBNOIZ],
                                             &lnNdens[BSIM4RBPBNOIZ], ckt, THERMNOISE,
                                             here->BSIM4bNodePrime, here->BSIM4bNode,
                                             here->BSIM4grbpb);
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
                                             here->BSIM4grbpb);
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


                              switch(model->BSIM4tnoiMod)
                              {  case 0:
                                      T0 = here->BSIM4ueff * FABS(here->BSIM4qinv);
                                      T1 = T0 * tmp + pParam->BSIM4leff
                                         * pParam->BSIM4leff;
                                      NevalSrc(&noizDens[BSIM4IDNOIZ],
                                               &lnNdens[BSIM4IDNOIZ], ckt,
                                               THERMNOISE, here->BSIM4dNodePrime,
                                               here->BSIM4sNodePrime,
                                               (T0 / T1) * model->BSIM4ntnoi);
                                      break;
                                 case 1:
                                      T0 = here->BSIM4gm + here->BSIM4gmbs + here->BSIM4gds;
                                      T0 *= T0;
                                      igsquare = npart_theta * npart_theta * T0 / here->BSIM4IdovVds;
                                      T1 = npart_beta * (here->BSIM4gm
                                         + here->BSIM4gmbs) + here->BSIM4gds;
                                      T2 = T1 * T1 / here->BSIM4IdovVds;
                                      NevalSrc(&noizDens[BSIM4IDNOIZ],
                                               &lnNdens[BSIM4IDNOIZ], ckt,
                                               THERMNOISE, here->BSIM4dNodePrime,
                                               here->BSIM4sNodePrime, (T2 - igsquare));
                                      break;
                              }

                              noizDens[BSIM4FLNOIZ]=1.0;

                              switch(model->BSIM4fnoiMod)
                              {  case 0:
                                      noizDens[BSIM4FLNOIZ] *= model->BSIM4kf
                                            * exp(model->BSIM4af
                                            * log(MAX(FABS(here->BSIM4cd),
                                            N_MINLOG)))
                                            / (1.0
                                            * pParam->BSIM4leff
                                            * pParam->BSIM4leff
                                            * model->BSIM4coxe);
                                      break;
                                 case 1:
                                      Vds = *(ckt->CKTstates[0] + here->BSIM4vds);
                                      if (Vds < 0.0)
                                          Vds = -Vds;

                                      Ssi = Eval1ovFNoise(Vds, model, here,
                                          1.0, ckt->CKTtemp);
                                      T10 = model->BSIM4oxideTrapDensityA
                                          * CONSTboltz * ckt->CKTtemp;
                                      T11 = pParam->BSIM4weff * here->BSIM4nf * pParam->BSIM4leff
                                          * 1.0 * 1.0e10
                                          * here->BSIM4nstar * here->BSIM4nstar;
                                      Swi = T10 / T11 * here->BSIM4cd
                                          * here->BSIM4cd;
                                      if(!isfinite(Ssi)||!isfinite(Swi)||Ssi<0||Swi<0)return CS_BSIM45_NONFINITE;
                                      noizDens[BSIM4FLNOIZ] *= (Ssi==0||Swi==0)?0:fmin(Ssi,Swi)/(1+fmin(Ssi,Swi)/fmax(Ssi,Swi));
                                      break;
                              }

                              if(!isfinite(noizDens[BSIM4FLNOIZ])||noizDens[BSIM4FLNOIZ]<0)return CS_BSIM45_NONFINITE;
                              noizDens[BSIM4FLNOIZ]=cs_noise_project(&context,here->BSIM4dNodePrime,here->BSIM4sNodePrime,
                                  noizDens[BSIM4FLNOIZ]>0?log(noizDens[BSIM4FLNOIZ])-model->BSIM4ef*log(frequency):0,noizDens[BSIM4FLNOIZ]==0);
                              lnNdens[BSIM4FLNOIZ] =
                                     log(MAX(noizDens[BSIM4FLNOIZ], N_MINLOG));


                        if(here->BSIM4mode >= 0) {  /* bugfix  */
                              NevalSrc(&noizDens[BSIM4IGSNOIZ],
                                   &lnNdens[BSIM4IGSNOIZ], ckt, SHOTNOISE,
                                   here->BSIM4gNodePrime, here->BSIM4sNodePrime,
                                   (here->BSIM4Igs + here->BSIM4Igcs));
                              NevalSrc(&noizDens[BSIM4IGDNOIZ],
                                   &lnNdens[BSIM4IGDNOIZ], ckt, SHOTNOISE,
                                   here->BSIM4gNodePrime, here->BSIM4dNodePrime,
                                   (here->BSIM4Igd + here->BSIM4Igcd));
                        } else {
                              NevalSrc(&noizDens[BSIM4IGSNOIZ],
                                   &lnNdens[BSIM4IGSNOIZ], ckt, SHOTNOISE,
                                   here->BSIM4gNodePrime, here->BSIM4sNodePrime,
                                   (here->BSIM4Igs + here->BSIM4Igcd));
                              NevalSrc(&noizDens[BSIM4IGDNOIZ],
                                   &lnNdens[BSIM4IGDNOIZ], ckt, SHOTNOISE,
                                   here->BSIM4gNodePrime, here->BSIM4dNodePrime,
                                   (here->BSIM4Igd + here->BSIM4Igcs));
                        }
                              NevalSrc(&noizDens[BSIM4IGBNOIZ],
                                   &lnNdens[BSIM4IGBNOIZ], ckt, SHOTNOISE,
                                   here->BSIM4gNodePrime, here->BSIM4bNodePrime,
                                   here->BSIM4Igb);


                              noizDens[BSIM4TOTNOIZ] = noizDens[BSIM4RDNOIZ]
                                     + noizDens[BSIM4RSNOIZ] + noizDens[BSIM4RGNOIZ]
                                     + noizDens[BSIM4RBPSNOIZ] + noizDens[BSIM4RBPDNOIZ]
                                     + noizDens[BSIM4RBPBNOIZ]
                                     + noizDens[BSIM4RBSBNOIZ] + noizDens[BSIM4RBDBNOIZ]
                                     + noizDens[BSIM4IDNOIZ] + noizDens[BSIM4FLNOIZ]
                                     + noizDens[BSIM4IGSNOIZ] + noizDens[BSIM4IGDNOIZ]
                                     + noizDens[BSIM4IGBNOIZ];
                              lnNdens[BSIM4TOTNOIZ] =
                                     log(MAX(noizDens[BSIM4TOTNOIZ], N_MINLOG));

 if(context.failed)return CS_BSIM45_NONFINITE;
 for(int n=0;n<14;n++)if(!isfinite(noizDens[n])||noizDens[n]<0)return CS_BSIM45_NONFINITE;
 return CS_BSIM45_OK;
}
