/* Modified for CoreSpice: exclusive bounded preparation; see adapt_upstream.py and DESIGN.md. */
/**** BSIM4.5.0 Released by Xuemei (Jane) Xi 07/29/2005 ****/

/**********
 * Copyright 2005 Regents of the University of California. All rights reserved.
 * File: b4check.c of BSIM4.5.0.
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

#include "spice.h"
#include <stdio.h>
#include <math.h>
#include "util.h"
#include "cktdefs.h"
#include "bsim4def.h"
#include "trandefs.h"
#include "const.h"
#include "sperror.h"
#include "devdefs.h"
#include "suffix.h"

int
BSIM4checkModel(model, here, ckt)
register BSIM4model *model;
register BSIM4instance *here;
CKTcircuit *ckt;
{
struct bsim4SizeDependParam *pParam;
int Fatal_Flag = 0;


    /* Checks run regardless of filesystem/diagnostic availability. */
    {   pParam = here->pParam;
        ;;
        ;;
        ;;
        ;;

        if (strcmp(model->BSIM4version, "4.5.0") != 0)
        {  cs_diagnostic(ckt, 50047, CS_BSIM45_DIAG_WARNING, -1, 0, 0.0,  "Warning: This model is BSIM4.5.0; you specified a wrong version number.\n");
           ;
        }
        ;;


        if ((here->BSIM4rgateMod == 2) || (here->BSIM4rgateMod == 3))
        {   if ((here->BSIM4trnqsMod == 1) || (here->BSIM4acnqsMod == 1))
            {   cs_diagnostic(ckt, 50055, CS_BSIM45_DIAG_WARNING, -1, 0, 0.0,  "Warning: You've selected both Rg and charge deficit NQS; select one only.\n");
                ;
            }
        }

        if (model->BSIM4toxe <= 0.0)
        {   cs_diagnostic(ckt, 50061, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_TOXE, (double)model->BSIM4toxe,  "Fatal: Toxe = %g is not positive.\n",
                    model->BSIM4toxe);
            ;
            Fatal_Flag = 1;
        }
        if (model->BSIM4toxp <= 0.0)
        {   cs_diagnostic(ckt, 50067, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_TOXP, (double)model->BSIM4toxp,  "Fatal: Toxp = %g is not positive.\n",
                    model->BSIM4toxp);
            ;
            Fatal_Flag = 1;
        }

        if (model->BSIM4toxm <= 0.0)
        {   cs_diagnostic(ckt, 50074, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_TOXM, (double)model->BSIM4toxm,  "Fatal: Toxm = %g is not positive.\n",
                    model->BSIM4toxm);
            ;
            Fatal_Flag = 1;
        }

        if (model->BSIM4toxref <= 0.0)
        {   cs_diagnostic(ckt, 50081, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_TOXREF, (double)model->BSIM4toxref,  "Fatal: Toxref = %g is not positive.\n",
                    model->BSIM4toxref);
            ;
            Fatal_Flag = 1;
        }

        if (pParam->BSIM4lpe0 < -pParam->BSIM4leff)
        {   cs_diagnostic(ckt, 50088, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_LPE0, (double)pParam->BSIM4lpe0,  "Fatal: Lpe0 = %g is less than -Leff.\n",
                    pParam->BSIM4lpe0);
            ;
            Fatal_Flag = 1;
        }
        if (model->BSIM4lintnoi > pParam->BSIM4leff/2)
        {   cs_diagnostic(ckt, 50095, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_LINTNOI, (double)model->BSIM4lintnoi,  "Fatal: Lintnoi = %g is too large - Leff for noise is negative.\n",
                    model->BSIM4lintnoi);
            ;
            Fatal_Flag = 1;
        }
        if (pParam->BSIM4lpeb < -pParam->BSIM4leff)
        {   cs_diagnostic(ckt, 50102, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_LPEB, (double)pParam->BSIM4lpeb,  "Fatal: Lpeb = %g is less than -Leff.\n",
                    pParam->BSIM4lpeb);
            ;
            Fatal_Flag = 1;
        }
        if (pParam->BSIM4ndep <= 0.0)
        {   cs_diagnostic(ckt, 50109, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_NDEP, (double)pParam->BSIM4ndep,  "Fatal: Ndep = %g is not positive.\n",
                    pParam->BSIM4ndep);
            ;
            Fatal_Flag = 1;
        }
        if (pParam->BSIM4phi <= 0.0)
        {   cs_diagnostic(ckt, 50116, CS_BSIM45_DIAG_FATAL, -1, 0, 0.0,  "Fatal: Phi = %g is not positive. Please check Phin and Ndep\n",
                    pParam->BSIM4phi);
            cs_diagnostic(ckt, 50118, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_PHIN, (double)pParam->BSIM4phin,  "     Phin = %g  Ndep = %g \n",
                    pParam->BSIM4phin, pParam->BSIM4ndep);
            ;
            ;
            Fatal_Flag = 1;
        }
        if (pParam->BSIM4nsub <= 0.0)
        {   cs_diagnostic(ckt, 50127, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_NSUB, (double)pParam->BSIM4nsub,  "Fatal: Nsub = %g is not positive.\n",
                    pParam->BSIM4nsub);
            ;
            Fatal_Flag = 1;
        }
        if (pParam->BSIM4ngate < 0.0)
        {   cs_diagnostic(ckt, 50134, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_NGATE, (double)pParam->BSIM4ngate,  "Fatal: Ngate = %g is not positive.\n",
                    pParam->BSIM4ngate);
            ;
            Fatal_Flag = 1;
        }
        if (pParam->BSIM4ngate > 1.e25)
        {   cs_diagnostic(ckt, 50141, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_NGATE, (double)pParam->BSIM4ngate,  "Fatal: Ngate = %g is too high.\n",
                    pParam->BSIM4ngate);
            ;
            Fatal_Flag = 1;
        }
        if (pParam->BSIM4xj <= 0.0)
        {   cs_diagnostic(ckt, 50148, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_XJ, (double)pParam->BSIM4xj,  "Fatal: Xj = %g is not positive.\n",
                    pParam->BSIM4xj);
            ;
            Fatal_Flag = 1;
        }

        if (pParam->BSIM4dvt1 < 0.0)
        {   cs_diagnostic(ckt, 50155, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_DVT1, (double)pParam->BSIM4dvt1,  "Fatal: Dvt1 = %g is negative.\n",
                    pParam->BSIM4dvt1);
            ;
            Fatal_Flag = 1;
        }

        if (pParam->BSIM4dvt1w < 0.0)
        {   cs_diagnostic(ckt, 50162, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_DVT1W, (double)pParam->BSIM4dvt1w,  "Fatal: Dvt1w = %g is negative.\n",
                    pParam->BSIM4dvt1w);
            ;
            Fatal_Flag = 1;
        }

        if (pParam->BSIM4w0 == -pParam->BSIM4weff)
        {   cs_diagnostic(ckt, 50169, CS_BSIM45_DIAG_FATAL, -1, 0, 0.0,  "Fatal: (W0 + Weff) = 0 causing divided-by-zero.\n");
            ;
            Fatal_Flag = 1;
        }

        if (pParam->BSIM4dsub < 0.0)
        {   cs_diagnostic(ckt, 50175, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_DSUB, (double)pParam->BSIM4dsub,  "Fatal: Dsub = %g is negative.\n", pParam->BSIM4dsub);
            ;
            Fatal_Flag = 1;
        }
        if (pParam->BSIM4b1 == -pParam->BSIM4weff)
        {   cs_diagnostic(ckt, 50180, CS_BSIM45_DIAG_FATAL, -1, 0, 0.0,  "Fatal: (B1 + Weff) = 0 causing divided-by-zero.\n");
            ;
            Fatal_Flag = 1;
        }
        if (here->BSIM4u0temp <= 0.0)
        {   cs_diagnostic(ckt, 50185, CS_BSIM45_DIAG_FATAL, -1, 0, 0.0,  "Fatal: u0 at current temperature = %g is not positive.\n", here->BSIM4u0temp);
            ;
            Fatal_Flag = 1;
        }

        if (pParam->BSIM4delta < 0.0)
        {   cs_diagnostic(ckt, 50192, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_DELTA, (double)pParam->BSIM4delta,  "Fatal: Delta = %g is less than zero.\n",
                    pParam->BSIM4delta);
            ;
            Fatal_Flag = 1;
        }

        if (here->BSIM4vsattemp <= 0.0)
        {   cs_diagnostic(ckt, 50199, CS_BSIM45_DIAG_FATAL, -1, 0, 0.0,  "Fatal: Vsat at current temperature = %g is not positive.\n", here->BSIM4vsattemp);
            ;
            Fatal_Flag = 1;
        }

        if (pParam->BSIM4pclm <= 0.0)
        {   cs_diagnostic(ckt, 50206, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_PCLM, (double)pParam->BSIM4pclm,  "Fatal: Pclm = %g is not positive.\n", pParam->BSIM4pclm);
            ;
            Fatal_Flag = 1;
        }

        if (pParam->BSIM4drout < 0.0)
        {   cs_diagnostic(ckt, 50212, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_DROUT, (double)pParam->BSIM4drout,  "Fatal: Drout = %g is negative.\n", pParam->BSIM4drout);
            ;
            Fatal_Flag = 1;
        }

        if (here->BSIM4nf < 1.0)
        {   cs_diagnostic(ckt, 50218, CS_BSIM45_DIAG_FATAL, 0, BSIM4_NF, (double)here->BSIM4nf,  "Fatal: Number of finger = %g is smaller than one.\n", here->BSIM4nf);
            ;
            Fatal_Flag = 1;
        }

        if((here->BSIM4sa > 0.0) && (here->BSIM4sb > 0.0) &&
        ((here->BSIM4nf == 1.0) || ((here->BSIM4nf > 1.0) && (here->BSIM4sd > 0.0))) )
        {   if (model->BSIM4saref <= 0.0)
            {   cs_diagnostic(ckt, 50226, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_SAREF, (double)model->BSIM4saref,  "Fatal: SAref = %g is not positive.\n",model->BSIM4saref);
                ;
                Fatal_Flag = 1;
            }
            if (model->BSIM4sbref <= 0.0)
            {   cs_diagnostic(ckt, 50231, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_SBREF, (double)model->BSIM4sbref,  "Fatal: SBref = %g is not positive.\n",model->BSIM4sbref);
                ;
                Fatal_Flag = 1;
            }
        }

        if ((here->BSIM4l + model->BSIM4xl) <= model->BSIM4xgl)
        {   cs_diagnostic(ckt, 50238, CS_BSIM45_DIAG_FATAL, -1, 0, 0.0,  "Fatal: The parameter xgl must be smaller than Ldrawn+XL.\n");
            ;
            Fatal_Flag = 1;
        }
        if (here->BSIM4ngcon < 1.0)
        {   cs_diagnostic(ckt, 50243, CS_BSIM45_DIAG_FATAL, -1, 0, 0.0,  "Fatal: The parameter ngcon cannot be smaller than one.\n");
            ;
            Fatal_Flag = 1;
        }
        if ((here->BSIM4ngcon != 1.0) && (here->BSIM4ngcon != 2.0))
        {   here->BSIM4ngcon = 1.0;
            cs_diagnostic(ckt, 50249, CS_BSIM45_DIAG_WARNING, -1, 0, 0.0,  "Warning: Ngcon must be equal to one or two; reset to 1.0.\n");
            ;
        }

        if (model->BSIM4gbmin < 1.0e-20)
        {   cs_diagnostic(ckt, 50254, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_GBMIN, (double)model->BSIM4gbmin,  "Warning: Gbmin = %g is too small.\n",
                    model->BSIM4gbmin);
            ;
        }

        /* Check saturation parameters */
        if (pParam->BSIM4fprout < 0.0)
        {   cs_diagnostic(ckt, 50261, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_FPROUT, (double)pParam->BSIM4fprout,  "Fatal: fprout = %g is negative.\n",
                    pParam->BSIM4fprout);
            ;
            Fatal_Flag = 1;
        }
        if (pParam->BSIM4pdits < 0.0)
        {   cs_diagnostic(ckt, 50267, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_PDITS, (double)pParam->BSIM4pdits,  "Fatal: pdits = %g is negative.\n",
                    pParam->BSIM4pdits);
            ;
            Fatal_Flag = 1;
        }
        if (model->BSIM4pditsl < 0.0)
        {   cs_diagnostic(ckt, 50273, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_PDITSL, (double)model->BSIM4pditsl,  "Fatal: pditsl = %g is negative.\n",
                    model->BSIM4pditsl);
            ;
            Fatal_Flag = 1;
        }

        /* Check gate current parameters */
      if (model->BSIM4igbMod) {
        if (pParam->BSIM4nigbinv <= 0.0)
        {   cs_diagnostic(ckt, 50282, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_NIGBINV, (double)pParam->BSIM4nigbinv,  "Fatal: nigbinv = %g is non-positive.\n",
                    pParam->BSIM4nigbinv);
            ;
            Fatal_Flag = 1;
        }
        if (pParam->BSIM4nigbacc <= 0.0)
        {   cs_diagnostic(ckt, 50288, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_NIGBACC, (double)pParam->BSIM4nigbacc,  "Fatal: nigbacc = %g is non-positive.\n",
                    pParam->BSIM4nigbacc);
            ;
            Fatal_Flag = 1;
        }
      }
      if (model->BSIM4igcMod) {
        if (pParam->BSIM4nigc <= 0.0)
        {   cs_diagnostic(ckt, 50296, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_NIGC, (double)pParam->BSIM4nigc,  "Fatal: nigc = %g is non-positive.\n",
                    pParam->BSIM4nigc);
            ;
            Fatal_Flag = 1;
        }
        if (pParam->BSIM4poxedge <= 0.0)
        {   cs_diagnostic(ckt, 50302, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_POXEDGE, (double)pParam->BSIM4poxedge,  "Fatal: poxedge = %g is non-positive.\n",
                    pParam->BSIM4poxedge);
            ;
            Fatal_Flag = 1;
        }
        if (pParam->BSIM4pigcd <= 0.0)
        {   cs_diagnostic(ckt, 50308, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_PIGCD, (double)pParam->BSIM4pigcd,  "Fatal: pigcd = %g is non-positive.\n",
                    pParam->BSIM4pigcd);
            ;
            Fatal_Flag = 1;
        }
      }

        /* Check capacitance parameters */
        if (pParam->BSIM4clc < 0.0)
        {   cs_diagnostic(ckt, 50317, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_CLC, (double)pParam->BSIM4clc,  "Fatal: Clc = %g is negative.\n", pParam->BSIM4clc);
            ;
            Fatal_Flag = 1;
        }

        /* Check overlap capacitance parameters */
        if (pParam->BSIM4ckappas < 0.02)
        {   cs_diagnostic(ckt, 50324, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_CKAPPAS, (double)pParam->BSIM4ckappas,  "Warning: ckappas = %g is too small. Set to 0.02\n",
                    pParam->BSIM4ckappas);
            ;
            pParam->BSIM4ckappas = 0.02;
       }
        if (pParam->BSIM4ckappad < 0.02)
        {   cs_diagnostic(ckt, 50330, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_CKAPPAD, (double)pParam->BSIM4ckappad,  "Warning: ckappad = %g is too small. Set to 0.02\n",
                    pParam->BSIM4ckappad);
            ;
            pParam->BSIM4ckappad = 0.02;
        }

        if (model->BSIM4vtss < 0.0)
        {   cs_diagnostic(ckt, 50337, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_VTSS, (double)model->BSIM4vtss,  "Fatal: Vtss = %g is negative.\n",
                        model->BSIM4vtss);
            ;
            Fatal_Flag = 1;
        }
        if (model->BSIM4vtsd < 0.0)
        {   cs_diagnostic(ckt, 50344, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_VTSD, (double)model->BSIM4vtsd,  "Fatal: Vtsd = %g is negative.\n",
                        model->BSIM4vtsd);
            ;
            Fatal_Flag = 1;
        }
        if (model->BSIM4vtssws < 0.0)
        {   cs_diagnostic(ckt, 50351, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_VTSSWS, (double)model->BSIM4vtssws,  "Fatal: Vtssws = %g is negative.\n",
                    model->BSIM4vtssws);
            ;
            Fatal_Flag = 1;
        }
        if (model->BSIM4vtsswd < 0.0)
        {   cs_diagnostic(ckt, 50358, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_VTSSWD, (double)model->BSIM4vtsswd,  "Fatal: Vtsswd = %g is negative.\n",
                    model->BSIM4vtsswd);
            ;
            Fatal_Flag = 1;
        }
        if (model->BSIM4vtsswgs < 0.0)
        {   cs_diagnostic(ckt, 50365, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_VTSSWGS, (double)model->BSIM4vtsswgs,  "Fatal: Vtsswgs = %g is negative.\n",
                    model->BSIM4vtsswgs);
            ;
            Fatal_Flag = 1;
        }
        if (model->BSIM4vtsswgd < 0.0)
        {   cs_diagnostic(ckt, 50372, CS_BSIM45_DIAG_FATAL, 1, BSIM4_MOD_VTSSWGD, (double)model->BSIM4vtsswgd,  "Fatal: Vtsswgd = %g is negative.\n",
                    model->BSIM4vtsswgd);
            ;
            Fatal_Flag = 1;
        }


      if (model->BSIM4paramChk ==1)
      {
/* Check L and W parameters */
        if (pParam->BSIM4leff <= 1.0e-9)
        {   cs_diagnostic(ckt, 50384, CS_BSIM45_DIAG_WARNING, -1, 0, 0.0,  "Warning: Leff = %g <= 1.0e-9. Recommended Leff >= 1e-8 \n",
                    pParam->BSIM4leff);
            ;
        }

        if (pParam->BSIM4leffCV <= 1.0e-9)
        {   cs_diagnostic(ckt, 50391, CS_BSIM45_DIAG_WARNING, -1, 0, 0.0,  "Warning: Leff for CV = %g <= 1.0e-9. Recommended LeffCV >=1e-8 \n",
                    pParam->BSIM4leffCV);
            ;
        }

        if (pParam->BSIM4weff <= 1.0e-9)
        {   cs_diagnostic(ckt, 50398, CS_BSIM45_DIAG_WARNING, -1, 0, 0.0,  "Warning: Weff = %g <= 1.0e-9. Recommended Weff >=1e-7 \n",
                    pParam->BSIM4weff);
            ;
        }

        if (pParam->BSIM4weffCV <= 1.0e-9)
        {   cs_diagnostic(ckt, 50405, CS_BSIM45_DIAG_WARNING, -1, 0, 0.0,  "Warning: Weff for CV = %g <= 1.0e-9. Recommended WeffCV >= 1e-7 \n",
                    pParam->BSIM4weffCV);
            ;
        }

        /* Check threshold voltage parameters */
        if (model->BSIM4toxe < 1.0e-10)
        {   cs_diagnostic(ckt, 50413, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_TOXE, (double)model->BSIM4toxe,  "Warning: Toxe = %g is less than 1A. Recommended Toxe >= 5A\n",
                    model->BSIM4toxe);
            ;
        }
        if (model->BSIM4toxp < 1.0e-10)
        {   cs_diagnostic(ckt, 50418, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_TOXP, (double)model->BSIM4toxp,  "Warning: Toxp = %g is less than 1A. Recommended Toxp >= 5A\n",
                    model->BSIM4toxp);
            ;
        }
        if (model->BSIM4toxm < 1.0e-10)
        {   cs_diagnostic(ckt, 50423, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_TOXM, (double)model->BSIM4toxm,  "Warning: Toxm = %g is less than 1A. Recommended Toxm >= 5A\n",
                    model->BSIM4toxm);
            ;
        }

        if (pParam->BSIM4ndep <= 1.0e12)
        {   cs_diagnostic(ckt, 50429, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_NDEP, (double)pParam->BSIM4ndep,  "Warning: Ndep = %g may be too small.\n",
                    pParam->BSIM4ndep);
            ;
        }
        else if (pParam->BSIM4ndep >= 1.0e21)
        {   cs_diagnostic(ckt, 50435, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_NDEP, (double)pParam->BSIM4ndep,  "Warning: Ndep = %g may be too large.\n",
                    pParam->BSIM4ndep);
            ;
        }

         if (pParam->BSIM4nsub <= 1.0e14)
        {   cs_diagnostic(ckt, 50442, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_NSUB, (double)pParam->BSIM4nsub,  "Warning: Nsub = %g may be too small.\n",
                    pParam->BSIM4nsub);
            ;
        }
        else if (pParam->BSIM4nsub >= 1.0e21)
        {   cs_diagnostic(ckt, 50448, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_NSUB, (double)pParam->BSIM4nsub,  "Warning: Nsub = %g may be too large.\n",
                    pParam->BSIM4nsub);
            ;
        }

        if ((pParam->BSIM4ngate > 0.0) &&
            (pParam->BSIM4ngate <= 1.e18))
        {   cs_diagnostic(ckt, 50456, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_NGATE, (double)pParam->BSIM4ngate,  "Warning: Ngate = %g is less than 1.E18cm^-3.\n",
                    pParam->BSIM4ngate);
            ;
        }

        if (pParam->BSIM4dvt0 < 0.0)
        {   cs_diagnostic(ckt, 50463, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_DVT0, (double)pParam->BSIM4dvt0,  "Warning: Dvt0 = %g is negative.\n",
                    pParam->BSIM4dvt0);
            ;
        }

        if (fabs(1.0e-8 / (pParam->BSIM4w0 + pParam->BSIM4weff)) > 10.0)
        {   cs_diagnostic(ckt, 50469, CS_BSIM45_DIAG_WARNING, -1, 0, 0.0,  "Warning: (W0 + Weff) may be too small.\n");
            ;
        }

/* Check subthreshold parameters */
        if (pParam->BSIM4nfactor < 0.0)
        {   cs_diagnostic(ckt, 50475, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_NFACTOR, (double)pParam->BSIM4nfactor,  "Warning: Nfactor = %g is negative.\n",
                    pParam->BSIM4nfactor);
            ;
        }
        if (pParam->BSIM4cdsc < 0.0)
        {   cs_diagnostic(ckt, 50480, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_CDSC, (double)pParam->BSIM4cdsc,  "Warning: Cdsc = %g is negative.\n",
                    pParam->BSIM4cdsc);
            ;
        }
        if (pParam->BSIM4cdscd < 0.0)
        {   cs_diagnostic(ckt, 50485, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_CDSCD, (double)pParam->BSIM4cdscd,  "Warning: Cdscd = %g is negative.\n",
                    pParam->BSIM4cdscd);
            ;
        }
/* Check DIBL parameters */
        if (here->BSIM4eta0 < 0.0)
        {   cs_diagnostic(ckt, 50491, CS_BSIM45_DIAG_WARNING, -1, 0, 0.0,  "Warning: Eta0 = %g is negative.\n",
                    here->BSIM4eta0);
            ;
        }

/* Check Abulk parameters */
         if (fabs(1.0e-8 / (pParam->BSIM4b1 + pParam->BSIM4weff)) > 10.0)
        {   cs_diagnostic(ckt, 50498, CS_BSIM45_DIAG_WARNING, -1, 0, 0.0,  "Warning: (B1 + Weff) may be too small.\n");
            ;
        }


/* Check Saturation parameters */
        if (pParam->BSIM4a2 < 0.01)
        {   cs_diagnostic(ckt, 50505, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_A2, (double)pParam->BSIM4a2,  "Warning: A2 = %g is too small. Set to 0.01.\n", pParam->BSIM4a2);
            ;
            pParam->BSIM4a2 = 0.01;
        }
        else if (pParam->BSIM4a2 > 1.0)
        {   cs_diagnostic(ckt, 50511, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_A2, (double)pParam->BSIM4a2,  "Warning: A2 = %g is larger than 1. A2 is set to 1 and A1 is set to 0.\n",
                    pParam->BSIM4a2);
            ;
            pParam->BSIM4a2 = 1.0;
            pParam->BSIM4a1 = 0.0;
        }

        if (pParam->BSIM4prwg < 0.0)
        {   cs_diagnostic(ckt, 50520, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_PRWG, (double)pParam->BSIM4prwg,  "Warning: Prwg = %g is negative. Set to zero.\n",
                    pParam->BSIM4prwg);
            ;
            pParam->BSIM4prwg = 0.0;
        }

        if (pParam->BSIM4rdsw < 0.0)
        {   cs_diagnostic(ckt, 50528, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_RDSW, (double)pParam->BSIM4rdsw,  "Warning: Rdsw = %g is negative. Set to zero.\n",
                    pParam->BSIM4rdsw);
            ;
            pParam->BSIM4rdsw = 0.0;
            pParam->BSIM4rds0 = 0.0;
        }

        if (pParam->BSIM4rds0 < 0.0)
        {   cs_diagnostic(ckt, 50537, CS_BSIM45_DIAG_WARNING, -1, 0, 0.0,  "Warning: Rds at current temperature = %g is negative. Set to zero.\n",
                    pParam->BSIM4rds0);
            ;
            pParam->BSIM4rds0 = 0.0;
        }

        if (pParam->BSIM4rdswmin < 0.0)
        {   cs_diagnostic(ckt, 50545, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_RDSWMIN, (double)pParam->BSIM4rdswmin,  "Warning: Rdswmin at current temperature = %g is negative. Set to zero.\n",
                    pParam->BSIM4rdswmin);
            ;
            pParam->BSIM4rdswmin = 0.0;
        }

        if (pParam->BSIM4pscbe2 <= 0.0)
        {   cs_diagnostic(ckt, 50553, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_PSCBE2, (double)pParam->BSIM4pscbe2,  "Warning: Pscbe2 = %g is not positive.\n",
                    pParam->BSIM4pscbe2);
            ;
        }

        if (pParam->BSIM4vsattemp < 1.0e3)
        {   cs_diagnostic(ckt, 50559, CS_BSIM45_DIAG_WARNING, -1, 0, 0.0,  "Warning: Vsat at current temperature = %g may be too small.\n", pParam->BSIM4vsattemp);
           ;
        }

      if((model->BSIM4lambdaGiven) && (pParam->BSIM4lambda > 0.0) )
      {
        if (pParam->BSIM4lambda > 1.0e-9)
        {   cs_diagnostic(ckt, 50566, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_LAMBDA, (double)pParam->BSIM4lambda,  "Warning: Lambda = %g may be too large.\n", pParam->BSIM4lambda);
           ;
        }
      }

      if((model->BSIM4vtlGiven) && (pParam->BSIM4vtl > 0.0) )
      {
        if (pParam->BSIM4vtl < 6.0e4)
        {   cs_diagnostic(ckt, 50574, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_VTL, (double)pParam->BSIM4vtl,  "Warning: Thermal velocity vtl = %g may be too small.\n", pParam->BSIM4vtl);
           ;
        }

        if (pParam->BSIM4xn < 3.0)
        {   cs_diagnostic(ckt, 50579, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_XN, (double)pParam->BSIM4xn,  "Warning: back scattering coeff xn = %g is too small.\n", pParam->BSIM4xn);
            ;
            pParam->BSIM4xn = 3.0;
        }

        if (model->BSIM4lc < 0.0)
        {   cs_diagnostic(ckt, 50585, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_LC, (double)model->BSIM4lc,  "Warning: back scattering coeff lc = %g is too small.\n", model->BSIM4lc);
            ;
            pParam->BSIM4lc = 0.0;
        }
      }

        if (pParam->BSIM4pdibl1 < 0.0)
        {   cs_diagnostic(ckt, 50592, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_PDIBL1, (double)pParam->BSIM4pdibl1,  "Warning: Pdibl1 = %g is negative.\n",
                    pParam->BSIM4pdibl1);
            ;
        }
        if (pParam->BSIM4pdibl2 < 0.0)
        {   cs_diagnostic(ckt, 50597, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_PDIBL2, (double)pParam->BSIM4pdibl2,  "Warning: Pdibl2 = %g is negative.\n",
                    pParam->BSIM4pdibl2);
            ;
        }

/* Check stress effect parameters */
        if((here->BSIM4sa > 0.0) && (here->BSIM4sb > 0.0) &&
        ((here->BSIM4nf == 1.0) || ((here->BSIM4nf > 1.0) && (here->BSIM4sd > 0.0))) )
        {   if (model->BSIM4lodk2 <= 0.0)
            {   cs_diagnostic(ckt, 50606, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_LODK2, (double)model->BSIM4lodk2,  "Warning: LODK2 = %g is not positive.\n",model->BSIM4lodk2);
                ;
            }
            if (model->BSIM4lodeta0 <= 0.0)
            {   cs_diagnostic(ckt, 50610, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_LODETA0, (double)model->BSIM4lodeta0,  "Warning: LODETA0 = %g is not positive.\n",model->BSIM4lodeta0);
                ;
            }
        }

/* Check gate resistance parameters */
        if (here->BSIM4rgateMod == 1)
        {   if (model->BSIM4rshg <= 0.0)
                ;
        }
        else if (here->BSIM4rgateMod == 2)
        {   if (model->BSIM4rshg <= 0.0)
                ;
            else if (pParam->BSIM4xrcrg1 <= 0.0)
                     ;
         }
        if (here->BSIM4rgateMod == 3)
        {   if (model->BSIM4rshg <= 0.0)
                ;
            else if (pParam->BSIM4xrcrg1 <= 0.0)
                     ;
         }

/* Check capacitance parameters */
        if (pParam->BSIM4noff < 0.1)
        {   cs_diagnostic(ckt, 50635, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_NOFF, (double)pParam->BSIM4noff,  "Warning: Noff = %g is too small.\n",
                    pParam->BSIM4noff);
            ;
        }

        if (pParam->BSIM4voffcv < -0.5)
        {   cs_diagnostic(ckt, 50641, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_VOFFCV, (double)pParam->BSIM4voffcv,  "Warning: Voffcv = %g is too small.\n",
                    pParam->BSIM4voffcv);
            ;
        }

        if (pParam->BSIM4moin < 5.0)
        {   cs_diagnostic(ckt, 50647, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_MOIN, (double)pParam->BSIM4moin,  "Warning: Moin = %g is too small.\n",
                    pParam->BSIM4moin);
            ;
        }
        if (pParam->BSIM4moin > 25.0)
        {   cs_diagnostic(ckt, 50652, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_MOIN, (double)pParam->BSIM4moin,  "Warning: Moin = %g is too large.\n",
                    pParam->BSIM4moin);
            ;
        }
        if(model->BSIM4capMod ==2) {
                if (pParam->BSIM4acde < 0.1)
                {   cs_diagnostic(ckt, 50658, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_ACDE, (double)pParam->BSIM4acde,  "Warning:  Acde = %g is too small.\n",
                        pParam->BSIM4acde);
                ;
                }
                if (pParam->BSIM4acde > 1.6)
                {   cs_diagnostic(ckt, 50663, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_ACDE, (double)pParam->BSIM4acde,  "Warning:  Acde = %g is too large.\n",
                        pParam->BSIM4acde);
                ;
                }
        }

/* Check overlap capacitance parameters */
        if (model->BSIM4cgdo < 0.0)
        {   cs_diagnostic(ckt, 50671, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_CGDO, (double)model->BSIM4cgdo,  "Warning: cgdo = %g is negative. Set to zero.\n", model->BSIM4cgdo);
            ;
            model->BSIM4cgdo = 0.0;
        }
        if (model->BSIM4cgso < 0.0)
        {   cs_diagnostic(ckt, 50676, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_CGSO, (double)model->BSIM4cgso,  "Warning: cgso = %g is negative. Set to zero.\n", model->BSIM4cgso);
            ;
            model->BSIM4cgso = 0.0;
        }
        if (model->BSIM4cgbo < 0.0)
        {   cs_diagnostic(ckt, 50681, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_CGBO, (double)model->BSIM4cgbo,  "Warning: cgbo = %g is negative. Set to zero.\n", model->BSIM4cgbo);
            ;
            model->BSIM4cgbo = 0.0;
        }
      if (model->BSIM4tnoiMod == 1) {
        if (model->BSIM4tnoia < 0.0)
        {   cs_diagnostic(ckt, 50687, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_TNOIA, (double)model->BSIM4tnoia,  "Warning: tnoia = %g is negative. Set to zero.\n", model->BSIM4tnoia);
            ;
            model->BSIM4tnoia = 0.0;
        }
        if (model->BSIM4tnoib < 0.0)
        {   cs_diagnostic(ckt, 50692, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_TNOIB, (double)model->BSIM4tnoib,  "Warning: tnoib = %g is negative. Set to zero.\n", model->BSIM4tnoib);
            ;
            model->BSIM4tnoib = 0.0;
        }

         if (model->BSIM4rnoia < 0.0)
        {   cs_diagnostic(ckt, 50698, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_RNOIA, (double)model->BSIM4rnoia,  "Warning: rnoia = %g is negative. Set to zero.\n", model->BSIM4rnoia);
            ;
            model->BSIM4rnoia = 0.0;
        }
        if (model->BSIM4rnoib < 0.0)
        {   cs_diagnostic(ckt, 50703, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_RNOIB, (double)model->BSIM4rnoib,  "Warning: rnoib = %g is negative. Set to zero.\n", model->BSIM4rnoib);
            ;
            model->BSIM4rnoib = 0.0;
        }
      }

        if (model->BSIM4SjctEmissionCoeff < 0.0)
        {   cs_diagnostic(ckt, 50710, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_NJS, (double)model->BSIM4SjctEmissionCoeff,  "Warning: Njs = %g is negative.\n",
                    model->BSIM4SjctEmissionCoeff);
            ;
        }
        if (model->BSIM4DjctEmissionCoeff < 0.0)
        {   cs_diagnostic(ckt, 50716, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_NJD, (double)model->BSIM4DjctEmissionCoeff,  "Warning: Njd = %g is negative.\n",
                    model->BSIM4DjctEmissionCoeff);
            ;
        }
        if (model->BSIM4njtstemp < 0.0)
        {   cs_diagnostic(ckt, 50722, CS_BSIM45_DIAG_WARNING, -1, 0, 0.0,  "Warning: Njts = %g is negative at temperature = %g.\n",
                    model->BSIM4njtstemp, ckt->CKTtemp);
            ;
        }
        if (model->BSIM4njtsswtemp < 0.0)
        {   cs_diagnostic(ckt, 50728, CS_BSIM45_DIAG_WARNING, -1, 0, 0.0,  "Warning: Njtssw = %g is negative at temperature = %g.\n",
                    model->BSIM4njtsswtemp, ckt->CKTtemp);
            ;
        }
        if (model->BSIM4njtsswgtemp < 0.0)
        {   cs_diagnostic(ckt, 50734, CS_BSIM45_DIAG_WARNING, -1, 0, 0.0,  "Warning: Njtsswg = %g is negative at temperature = %g.\n",
                    model->BSIM4njtsswgtemp, ckt->CKTtemp);
            ;
        }
       if (model->BSIM4ntnoi < 0.0)
        {   cs_diagnostic(ckt, 50740, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_NTNOI, (double)model->BSIM4ntnoi,  "Warning: ntnoi = %g is negative. Set to zero.\n", model->BSIM4ntnoi);
            ;
            model->BSIM4ntnoi = 0.0;
        }

        /* diode model */
       if (model->BSIM4SbulkJctBotGradingCoeff >= 0.99)
        {   cs_diagnostic(ckt, 50747, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_MJS, (double)model->BSIM4SbulkJctBotGradingCoeff,  "Warning: MJS = %g is too big. Set to 0.99.\n", model->BSIM4SbulkJctBotGradingCoeff);
            ;
            model->BSIM4SbulkJctBotGradingCoeff = 0.99;
        }
       if (model->BSIM4SbulkJctSideGradingCoeff >= 0.99)
        {   cs_diagnostic(ckt, 50752, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_MJSWS, (double)model->BSIM4SbulkJctSideGradingCoeff,  "Warning: MJSWS = %g is too big. Set to 0.99.\n", model->BSIM4SbulkJctSideGradingCoeff);
            ;
            model->BSIM4SbulkJctSideGradingCoeff = 0.99;
        }
       if (model->BSIM4SbulkJctGateSideGradingCoeff >= 0.99)
        {   cs_diagnostic(ckt, 50757, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_MJSWGS, (double)model->BSIM4SbulkJctGateSideGradingCoeff,  "Warning: MJSWGS = %g is too big. Set to 0.99.\n", model->BSIM4SbulkJctGateSideGradingCoeff);
            ;
            model->BSIM4SbulkJctGateSideGradingCoeff = 0.99;
        }

       if (model->BSIM4DbulkJctBotGradingCoeff >= 0.99)
        {   cs_diagnostic(ckt, 50763, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_MJD, (double)model->BSIM4DbulkJctBotGradingCoeff,  "Warning: MJD = %g is too big. Set to 0.99.\n", model->BSIM4DbulkJctBotGradingCoeff);
            ;
            model->BSIM4DbulkJctBotGradingCoeff = 0.99;
        }
       if (model->BSIM4DbulkJctSideGradingCoeff >= 0.99)
        {   cs_diagnostic(ckt, 50768, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_MJSWD, (double)model->BSIM4DbulkJctSideGradingCoeff,  "Warning: MJSWD = %g is too big. Set to 0.99.\n", model->BSIM4DbulkJctSideGradingCoeff);
            ;
            model->BSIM4DbulkJctSideGradingCoeff = 0.99;
        }
       if (model->BSIM4DbulkJctGateSideGradingCoeff >= 0.99)
        {   cs_diagnostic(ckt, 50773, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_MJSWGD, (double)model->BSIM4DbulkJctGateSideGradingCoeff,  "Warning: MJSWGD = %g is too big. Set to 0.99.\n", model->BSIM4DbulkJctGateSideGradingCoeff);
            ;
            model->BSIM4DbulkJctGateSideGradingCoeff = 0.99;
        }
        if (model->BSIM4wpemod == 1)
        {
                if (model->BSIM4scref <= 0.0)
                {   cs_diagnostic(ckt, 50780, CS_BSIM45_DIAG_WARNING, 1, BSIM4_MOD_SCREF, (double)model->BSIM4scref,  "Warning: SCREF = %g is not positive. Set to 1e-6.\n", model->BSIM4scref);
                    ;
                    model->BSIM4scref = 1e-6;
                }
                if (here->BSIM4sca < 0.0)
                {   cs_diagnostic(ckt, 50785, CS_BSIM45_DIAG_WARNING, 0, BSIM4_SCA, (double)here->BSIM4sca,  "Warning: SCA = %g is negative. Set to 0.0.\n", here->BSIM4sca);
                    ;
                    here->BSIM4sca = 0.0;
                }
                if (here->BSIM4scb < 0.0)
                {   cs_diagnostic(ckt, 50790, CS_BSIM45_DIAG_WARNING, 0, BSIM4_SCB, (double)here->BSIM4scb,  "Warning: SCB = %g is negative. Set to 0.0.\n", here->BSIM4scb);
                    ;
                    here->BSIM4scb = 0.0;
                }
                if (here->BSIM4scc < 0.0)
                {   cs_diagnostic(ckt, 50795, CS_BSIM45_DIAG_WARNING, 0, BSIM4_SCC, (double)here->BSIM4scc,  "Warning: SCC = %g is negative. Set to 0.0.\n", here->BSIM4scc);
                    ;
                    here->BSIM4scc = 0.0;
                }
                if (here->BSIM4sc < 0.0)
                {   cs_diagnostic(ckt, 50800, CS_BSIM45_DIAG_WARNING, 0, BSIM4_SC, (double)here->BSIM4sc,  "Warning: SC = %g is negative. Set to 0.0.\n", here->BSIM4sc);
                    ;
                    here->BSIM4sc = 0.0;
                }
        }
     }/* loop for the parameter check for warning messages */

    }
    return(Fatal_Flag);
}
