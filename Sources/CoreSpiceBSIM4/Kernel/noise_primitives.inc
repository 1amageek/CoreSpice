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
