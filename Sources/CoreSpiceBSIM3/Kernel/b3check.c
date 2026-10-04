/**** BSIM3v3.3.0, Released by Xuemei Xi 07/29/2005 ****/

/**********
 * Copyright 2004 Regents of the University of California. All rights reserved.
 * File: b3check.c of BSIM3v3.3.0
 * Author: 1995 Min-Chie Jeng
 * Author: 1997-1999 Weidong Liu.
 * Author: 2001 Xuemei Xi.
 * Modified by Xuemei Xi, 10/05, 12/14, 2001.
 * Modified by Xuemei Xi, 07/29/2005.
 **********/

static const char rcsid[] = "$Id: b3check.c, v3.3.0 07/29/2005 18:00:00 Xuemei Xi Release $";

#include "spice.h"
#include <stdio.h>
#include <math.h>
#include "util.h"
#include "cktdefs.h"
#include "bsim3def.h"
#include "trandefs.h"
#include "const.h"
#include "sperror.h"
#include "devdefs.h"
#include "suffix.h"

int
BSIM3checkModel(model, here, ckt)
register BSIM3model *model;
register BSIM3instance *here;
CKTcircuit *ckt;
{
struct bsim3SizeDependParam *pParam;
int Fatal_Flag = 0;


    /* Checking is independent of filesystem availability. */
    {   pParam = here->pParam;
        cs_diagnostic(ckt, "BSIM3v3.3.0 Parameter Checking.\n");
        if (strcmp(model->BSIM3version, "3.3.0"))
        {  cs_diagnostic(ckt, "Warning: This model is BSIM3v3.3.0; you specified a wrong version number.\n");

        }
        cs_diagnostic(ckt, "Model = %s\n", model->BSIM3modName);

            if (pParam->BSIM3nlx < -pParam->BSIM3leff)
            {   cs_diagnostic(ckt, "Fatal: Nlx = %g is less than -Leff.\n",
                        pParam->BSIM3nlx);

                Fatal_Flag = 1;
            }

        if (model->BSIM3tox <= 0.0)
        {   cs_diagnostic(ckt, "Fatal: Tox = %g is not positive.\n",
                    model->BSIM3tox);

            Fatal_Flag = 1;
        }

        if (model->BSIM3toxm <= 0.0)
        {   cs_diagnostic(ckt, "Fatal: Toxm = %g is not positive.\n",
                    model->BSIM3toxm);

            Fatal_Flag = 1;
        }

        if (model->BSIM3lintnoi > pParam->BSIM3leff/2)
        {   cs_diagnostic(ckt, "Fatal: Lintnoi = %g is too large - Leff for noise is negative.\n",
                    model->BSIM3lintnoi);

            Fatal_Flag = 1;
        }

        if (pParam->BSIM3npeak <= 0.0)
        {   cs_diagnostic(ckt, "Fatal: Nch = %g is not positive.\n",
                    pParam->BSIM3npeak);

            Fatal_Flag = 1;
        }
        if (pParam->BSIM3nsub <= 0.0)
        {   cs_diagnostic(ckt, "Fatal: Nsub = %g is not positive.\n",
                    pParam->BSIM3nsub);

            Fatal_Flag = 1;
        }
        if (pParam->BSIM3ngate < 0.0)
        {   cs_diagnostic(ckt, "Fatal: Ngate = %g is not positive.\n",
                    pParam->BSIM3ngate);

            Fatal_Flag = 1;
        }
        if (pParam->BSIM3ngate > 1.e25)
        {   cs_diagnostic(ckt, "Fatal: Ngate = %g is too high.\n",
                    pParam->BSIM3ngate);

            Fatal_Flag = 1;
        }
        if (pParam->BSIM3xj <= 0.0)
        {   cs_diagnostic(ckt, "Fatal: Xj = %g is not positive.\n",
                    pParam->BSIM3xj);

            Fatal_Flag = 1;
        }

        if (pParam->BSIM3dvt1 < 0.0)
        {   cs_diagnostic(ckt, "Fatal: Dvt1 = %g is negative.\n",
                    pParam->BSIM3dvt1);

            Fatal_Flag = 1;
        }

        if (pParam->BSIM3dvt1w < 0.0)
        {   cs_diagnostic(ckt, "Fatal: Dvt1w = %g is negative.\n",
                    pParam->BSIM3dvt1w);

            Fatal_Flag = 1;
        }

        if (pParam->BSIM3w0 == -pParam->BSIM3weff)
        {   cs_diagnostic(ckt, "Fatal: (W0 + Weff) = 0 causing divided-by-zero.\n");

            Fatal_Flag = 1;
        }

        if (pParam->BSIM3dsub < 0.0)
        {   cs_diagnostic(ckt, "Fatal: Dsub = %g is negative.\n", pParam->BSIM3dsub);

            Fatal_Flag = 1;
        }
        if (pParam->BSIM3b1 == -pParam->BSIM3weff)
        {   cs_diagnostic(ckt, "Fatal: (B1 + Weff) = 0 causing divided-by-zero.\n");

            Fatal_Flag = 1;
        }
        if (pParam->BSIM3u0temp <= 0.0)
        {   cs_diagnostic(ckt, "Fatal: u0 at current temperature = %g is not positive.\n", pParam->BSIM3u0temp);

            Fatal_Flag = 1;
        }

/* Check delta parameter */
        if (pParam->BSIM3delta < 0.0)
        {   cs_diagnostic(ckt, "Fatal: Delta = %g is less than zero.\n",
                    pParam->BSIM3delta);

            Fatal_Flag = 1;
        }

        if (pParam->BSIM3vsattemp <= 0.0)
        {   cs_diagnostic(ckt, "Fatal: Vsat at current temperature = %g is not positive.\n", pParam->BSIM3vsattemp);

            Fatal_Flag = 1;
        }
/* Check Rout parameters */
        if (pParam->BSIM3pclm <= 0.0)
        {   cs_diagnostic(ckt, "Fatal: Pclm = %g is not positive.\n", pParam->BSIM3pclm);

            Fatal_Flag = 1;
        }

        if (pParam->BSIM3drout < 0.0)
        {   cs_diagnostic(ckt, "Fatal: Drout = %g is negative.\n", pParam->BSIM3drout);

            Fatal_Flag = 1;
        }

        if (pParam->BSIM3pscbe2 <= 0.0)
        {   cs_diagnostic(ckt, "Warning: Pscbe2 = %g is not positive.\n",
                    pParam->BSIM3pscbe2);

        }

      if (model->BSIM3unitLengthSidewallJctCap > 0.0 ||
            model->BSIM3unitLengthGateSidewallJctCap > 0.0)
      {
        if (here->BSIM3drainPerimeter < pParam->BSIM3weff)
        {   cs_diagnostic(ckt, "Warning: Pd = %g is less than W.\n",
                    here->BSIM3drainPerimeter);

        }
        if (here->BSIM3sourcePerimeter < pParam->BSIM3weff)
        {   cs_diagnostic(ckt, "Warning: Ps = %g is less than W.\n",
                    here->BSIM3sourcePerimeter);

        }
      }

        if (pParam->BSIM3noff < 0.1)
        {   cs_diagnostic(ckt, "Warning: Noff = %g is too small.\n",
                    pParam->BSIM3noff);

        }
        if (pParam->BSIM3noff > 4.0)
        {   cs_diagnostic(ckt, "Warning: Noff = %g is too large.\n",
                    pParam->BSIM3noff);

        }

        if (pParam->BSIM3voffcv < -0.5)
        {   cs_diagnostic(ckt, "Warning: Voffcv = %g is too small.\n",
                    pParam->BSIM3voffcv);

        }
        if (pParam->BSIM3voffcv > 0.5)
        {   cs_diagnostic(ckt, "Warning: Voffcv = %g is too large.\n",
                    pParam->BSIM3voffcv);

        }

        if (model->BSIM3ijth < 0.0)
        {   cs_diagnostic(ckt, "Fatal: Ijth = %g cannot be negative.\n",
                    model->BSIM3ijth);

            Fatal_Flag = 1;
        }

/* Check capacitance parameters */
        if (pParam->BSIM3clc < 0.0)
        {   cs_diagnostic(ckt, "Fatal: Clc = %g is negative.\n", pParam->BSIM3clc);

            Fatal_Flag = 1;
        }

        if (pParam->BSIM3moin < 5.0)
        {   cs_diagnostic(ckt, "Warning: Moin = %g is too small.\n",
                    pParam->BSIM3moin);

        }
        if (pParam->BSIM3moin > 25.0)
        {   cs_diagnostic(ckt, "Warning: Moin = %g is too large.\n",
                    pParam->BSIM3moin);

        }

        if(model->BSIM3capMod ==3) {
                if (pParam->BSIM3acde < 0.4)
                {   cs_diagnostic(ckt, "Warning:  Acde = %g is too small.\n",
                        pParam->BSIM3acde);

                }
                if (pParam->BSIM3acde > 1.6)
                {   cs_diagnostic(ckt, "Warning:  Acde = %g is too large.\n",
                        pParam->BSIM3acde);

                }
        }

      if (model->BSIM3paramChk ==1)
      {
/* Check L and W parameters */
        if (pParam->BSIM3leff <= 5.0e-8)
        {   cs_diagnostic(ckt, "Warning: Leff = %g may be too small.\n",
                    pParam->BSIM3leff);

        }

        if (pParam->BSIM3leffCV <= 5.0e-8)
        {   cs_diagnostic(ckt, "Warning: Leff for CV = %g may be too small.\n",
                    pParam->BSIM3leffCV);

        }

        if (pParam->BSIM3weff <= 1.0e-7)
        {   cs_diagnostic(ckt, "Warning: Weff = %g may be too small.\n",
                    pParam->BSIM3weff);

        }

        if (pParam->BSIM3weffCV <= 1.0e-7)
        {   cs_diagnostic(ckt, "Warning: Weff for CV = %g may be too small.\n",
                    pParam->BSIM3weffCV);

        }

/* Check threshold voltage parameters */
        if (pParam->BSIM3nlx < 0.0)
        {   cs_diagnostic(ckt, "Warning: Nlx = %g is negative.\n", pParam->BSIM3nlx);

        }
         if (model->BSIM3tox < 1.0e-9)
        {   cs_diagnostic(ckt, "Warning: Tox = %g is less than 10A.\n",
                    model->BSIM3tox);

        }

        if (pParam->BSIM3npeak <= 1.0e15)
        {   cs_diagnostic(ckt, "Warning: Nch = %g may be too small.\n",
                    pParam->BSIM3npeak);

        }
        else if (pParam->BSIM3npeak >= 1.0e21)
        {   cs_diagnostic(ckt, "Warning: Nch = %g may be too large.\n",
                    pParam->BSIM3npeak);

        }

         if (pParam->BSIM3nsub <= 1.0e14)
        {   cs_diagnostic(ckt, "Warning: Nsub = %g may be too small.\n",
                    pParam->BSIM3nsub);

        }
        else if (pParam->BSIM3nsub >= 1.0e21)
        {   cs_diagnostic(ckt, "Warning: Nsub = %g may be too large.\n",
                    pParam->BSIM3nsub);

        }

        if ((pParam->BSIM3ngate > 0.0) &&
            (pParam->BSIM3ngate <= 1.e18))
        {   cs_diagnostic(ckt, "Warning: Ngate = %g is less than 1.E18cm^-3.\n",
                    pParam->BSIM3ngate);

        }

        if (pParam->BSIM3dvt0 < 0.0)
        {   cs_diagnostic(ckt, "Warning: Dvt0 = %g is negative.\n",
                    pParam->BSIM3dvt0);

        }

        if (fabs(1.0e-6 / (pParam->BSIM3w0 + pParam->BSIM3weff)) > 10.0)
        {   cs_diagnostic(ckt, "Warning: (W0 + Weff) may be too small.\n");

        }

/* Check subthreshold parameters */
        if (pParam->BSIM3nfactor < 0.0)
        {   cs_diagnostic(ckt, "Warning: Nfactor = %g is negative.\n",
                    pParam->BSIM3nfactor);

        }
        if (pParam->BSIM3cdsc < 0.0)
        {   cs_diagnostic(ckt, "Warning: Cdsc = %g is negative.\n",
                    pParam->BSIM3cdsc);

        }
        if (pParam->BSIM3cdscd < 0.0)
        {   cs_diagnostic(ckt, "Warning: Cdscd = %g is negative.\n",
                    pParam->BSIM3cdscd);

        }
/* Check DIBL parameters */
        if (pParam->BSIM3eta0 < 0.0)
        {   cs_diagnostic(ckt, "Warning: Eta0 = %g is negative.\n",
                    pParam->BSIM3eta0);

        }

/* Check Abulk parameters */
         if (fabs(1.0e-6 / (pParam->BSIM3b1 + pParam->BSIM3weff)) > 10.0)
        {   cs_diagnostic(ckt, "Warning: (B1 + Weff) may be too small.\n");

        }


/* Check Saturation parameters */
        if (pParam->BSIM3a2 < 0.01)
        {   cs_diagnostic(ckt, "Warning: A2 = %g is too small. Set to 0.01.\n", pParam->BSIM3a2);

            pParam->BSIM3a2 = 0.01;
        }
        else if (pParam->BSIM3a2 > 1.0)
        {   cs_diagnostic(ckt, "Warning: A2 = %g is larger than 1. A2 is set to 1 and A1 is set to 0.\n",
                    pParam->BSIM3a2);

            pParam->BSIM3a2 = 1.0;
            pParam->BSIM3a1 = 0.0;
        }

        if (pParam->BSIM3rdsw < 0.0)
        {   cs_diagnostic(ckt, "Warning: Rdsw = %g is negative. Set to zero.\n",
                    pParam->BSIM3rdsw);

            pParam->BSIM3rdsw = 0.0;
            pParam->BSIM3rds0 = 0.0;
        }
        if (pParam->BSIM3rds0 < 0.0)
        {   cs_diagnostic(ckt, "Warning: Rds at current temperature = %g is negative. Set to zero.\n",
                    pParam->BSIM3rds0);

            pParam->BSIM3rds0 = 0.0;
        }

         if (pParam->BSIM3vsattemp < 1.0e3)
        {   cs_diagnostic(ckt, "Warning: Vsat at current temperature = %g may be too small.\n", pParam->BSIM3vsattemp);

        }

        if (pParam->BSIM3pdibl1 < 0.0)
        {   cs_diagnostic(ckt, "Warning: Pdibl1 = %g is negative.\n",
                    pParam->BSIM3pdibl1);

        }
        if (pParam->BSIM3pdibl2 < 0.0)
        {   cs_diagnostic(ckt, "Warning: Pdibl2 = %g is negative.\n",
                    pParam->BSIM3pdibl2);

        }
/* Check overlap capacitance parameters */
        if (model->BSIM3cgdo < 0.0)
        {   cs_diagnostic(ckt, "Warning: cgdo = %g is negative. Set to zero.\n", model->BSIM3cgdo);

            model->BSIM3cgdo = 0.0;
        }
        if (model->BSIM3cgso < 0.0)
        {   cs_diagnostic(ckt, "Warning: cgso = %g is negative. Set to zero.\n", model->BSIM3cgso);

            model->BSIM3cgso = 0.0;
        }
        if (model->BSIM3cgbo < 0.0)
        {   cs_diagnostic(ckt, "Warning: cgbo = %g is negative. Set to zero.\n", model->BSIM3cgbo);

            model->BSIM3cgbo = 0.0;
        }

     }/* loop for the parameter check for warning messages */

    }
    return(Fatal_Flag);
}
