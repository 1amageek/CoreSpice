/**** BSIM3v3.3.0, Released by Xuemei Xi 07/29/2005 ****/

/**********
 * Copyright 2004 Regents of the University of California. All rights reserved.
 * File: b3noi.c of BSIM3v3.3.0
 * Author: 1995 Gary W. Ng and Min-Chie Jeng.
 * Author: 1997-1999 Weidong Liu.
 * Author: 2001 Xuemei Xi
 * Modified by Xuemei Xi, 10/05/2001.
 **********/


#include "bsim3def.h"
#include "../include/CoreSpiceBSIM3.h"
#define CHARGE 1.602176634e-19
#define N_MINLOG 1e-38
#define MIN(a,b) ((a)<(b)?(a):(b))
#define THERMNOISE 1
#define N_GAIN 2
/* Current PSD only. The analysis owns the transfer function and integration. */
static void NevalSrc(double *density, double *logDensity, CKTcircuit *ckt,
                     int type, int positive, int negative, double conductance) {
    *density = type == THERMNOISE ? 4 * 1.380649e-23 * ckt->CKTtemp * conductance : 1;
    if (logDensity) *logDensity = log(MAX(*density, N_MINLOG));
}
static double StrongInversionNoiseEval(double Vds, BSIM3model *model, BSIM3instance *here, double freq, double temp)
{
struct bsim3SizeDependParam *pParam;
double cd, esat, DelClm, EffFreq, N0, Nl, Vgst, Leff, Leffsq;
double T0, T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13, Ssi;

    pParam = here->pParam;
    cd = fabs(here->BSIM3cd);
    Leff = pParam->BSIM3leff - 2.0 * model->BSIM3lintnoi;
    Leffsq = Leff * Leff;
    esat = 2.0 * pParam->BSIM3vsattemp / here->BSIM3ueff;
    if(model->BSIM3em<=0.0) DelClm = 0.0;
    else {
            T0 = ((((Vds - here->BSIM3Vdseff) / pParam->BSIM3litl)
                + model->BSIM3em) / esat);
            DelClm = pParam->BSIM3litl * log (MAX(T0, N_MINLOG));
            if (DelClm < 0.0)       DelClm = 0.0;  /* bugfix */
    }
    EffFreq = pow(freq, model->BSIM3ef);
    T1 = CHARGE * CHARGE * 8.62e-5 * cd * temp * here->BSIM3ueff;
    T2 = 1.0e8 * EffFreq * here->BSIM3Abulk * model->BSIM3cox * Leffsq;
    N0 = model->BSIM3cox * here->BSIM3Vgsteff / CHARGE;
    Nl = model->BSIM3cox * here->BSIM3Vgsteff
          * (1.0 - here->BSIM3AbovVgst2Vtm * here->BSIM3Vdseff) / CHARGE;

    T3 = model->BSIM3oxideTrapDensityA
       * log(MAX(((N0 + 2.0e14) / (Nl + 2.0e14)), N_MINLOG));
    T4 = model->BSIM3oxideTrapDensityB * (N0 - Nl);
    T5 = model->BSIM3oxideTrapDensityC * 0.5 * (N0 * N0 - Nl * Nl);

    T6 = 8.62e-5 * temp * cd * cd;
    T7 = 1.0e8 * EffFreq * Leffsq * pParam->BSIM3weff;
    T8 = model->BSIM3oxideTrapDensityA + model->BSIM3oxideTrapDensityB * Nl
       + model->BSIM3oxideTrapDensityC * Nl * Nl;
    T9 = (Nl + 2.0e14) * (Nl + 2.0e14);

    Ssi = T1 / T2 * (T3 + T4 + T5) + T6 / T7 * DelClm * T8 / T9;
    return Ssi;
}

int cs_bsim3_noise_density(BSIM3model *model, BSIM3instance *here,
                          CKTcircuit *ckt, double frequency, double noizDens[4]) {
    struct bsim3SizeDependParam *pParam = here->pParam;
    double lnNdens[4], vds, Ssi, Swi, T1, T10, T11;
    double frequencyPower = pow(frequency, model->BSIM3ef);
    if (!isfinite(frequencyPower) || frequencyPower <= 0) return CS_BSIM3_NUMERICAL;
    if (model->BSIM3noiMod < 1 || model->BSIM3noiMod > 6) return E_BADPARM;
    if ((model->BSIM3noiMod == 2 || model->BSIM3noiMod == 3 || model->BSIM3noiMod == 6)
        && pParam->BSIM3leff - 2 * model->BSIM3lintnoi <= 0) return E_BADPARM;
NevalSrc(&noizDens[BSIM3RDNOIZ],
                                       &lnNdens[BSIM3RDNOIZ], ckt, THERMNOISE,
                                       here->BSIM3dNodePrime, here->BSIM3dNode,
                                       here->BSIM3drainConductance);

                              NevalSrc(&noizDens[BSIM3RSNOIZ],
                                       &lnNdens[BSIM3RSNOIZ], ckt, THERMNOISE,
                                       here->BSIM3sNodePrime, here->BSIM3sNode,
                                       here->BSIM3sourceConductance);

                              switch( model->BSIM3noiMod )
                              {  case 1:
                                 case 3:
                                     NevalSrc(&noizDens[BSIM3IDNOIZ],
                                              &lnNdens[BSIM3IDNOIZ], ckt,
                                              THERMNOISE, here->BSIM3dNodePrime,
                                              here->BSIM3sNodePrime,
                                              2.0 * FABS(here->BSIM3gm
                                              + here->BSIM3gds
                                              + here->BSIM3gmbs) / 3.0);

                                      break;
                                 case 5:
                                 case 6:
                                     vds = MIN(*(ckt->CKTstate0 + here->BSIM3vds), here->BSIM3vdsat);
                                     NevalSrc(&noizDens[BSIM3IDNOIZ],
                                              &lnNdens[BSIM3IDNOIZ], ckt,
                                              THERMNOISE, here->BSIM3dNodePrime,
                                              here->BSIM3sNodePrime,
                                              (3.0 - vds / here->BSIM3vdsat)
                                              * FABS(here->BSIM3gm
                                              + here->BSIM3gds
                                              + here->BSIM3gmbs) / 3.0);

                                      break;
                                 case 2:
                                 case 4:
                                      NevalSrc(&noizDens[BSIM3IDNOIZ],
                                               &lnNdens[BSIM3IDNOIZ], ckt,
                                               THERMNOISE, here->BSIM3dNodePrime,
                                               here->BSIM3sNodePrime,
                                               (here->BSIM3ueff
                                               * FABS(here->BSIM3qinv)
                                               / (pParam->BSIM3leff * pParam->BSIM3leff
                                                + here->BSIM3ueff *FABS(here->BSIM3qinv)
                                                * here->BSIM3rds)));    /* bugfix */
                                      break;
                              }
                              NevalSrc(&noizDens[BSIM3FLNOIZ], (double*) NULL,
                                       ckt, N_GAIN, here->BSIM3dNodePrime,
                                       here->BSIM3sNodePrime, (double) 0.0);

                              switch( model->BSIM3noiMod )
                              {  case 1:
                                 case 4:
                                 case 5:
                                      noizDens[BSIM3FLNOIZ] *= model->BSIM3kf
                                            * exp(model->BSIM3af
                                            * log(MAX(FABS(here->BSIM3cd),
                                            N_MINLOG)))
                                            / (pow(frequency, model->BSIM3ef)
                                            * pParam->BSIM3leff
                                            * pParam->BSIM3leff
                                            * model->BSIM3cox);
                                      break;
                                 case 2:
                                 case 3:
                                 case 6:
                                      vds = *(ckt->CKTstate0 + here->BSIM3vds);
                                      if (vds < 0.0)
                                      {   vds = -vds;
                                      }
                                      Ssi = StrongInversionNoiseEval(vds, model,
                                                here, frequency, ckt->CKTtemp);
                                          T10 = model->BSIM3oxideTrapDensityA
                                              * 8.62e-5 * ckt->CKTtemp;
                                          T11 = pParam->BSIM3weff
                                              * pParam->BSIM3leff
                                              * pow(frequency, model->BSIM3ef)
                                              * 4.0e36;
                                          Swi = T10 / T11 * here->BSIM3cd
                                              * here->BSIM3cd;
                                          T1 = Swi + Ssi;
    if (!isfinite(Ssi) || !isfinite(Swi) || !isfinite(T1)) return CS_BSIM3_NUMERICAL;
                                          if (T1 > 0.0)
                                              noizDens[BSIM3FLNOIZ] *= (Ssi * Swi) / T1;
                                          else
                                              noizDens[BSIM3FLNOIZ] *= 0.0;
                                      break;
                              }


    return OK;
}
