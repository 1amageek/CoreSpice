#ifndef CS_BSIM45_COMPAT_H
#define CS_BSIM45_COMPAT_H
#include "../include/CoreSpiceBSIM45.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#define BSIM4noise cs_bsim45_noise
#define Eval1ovFNoise cs_bsim45_Eval1ovFNoise
#define CONSTboltz 1.3806226e-23
#define N_MINLOG 1e-38
#define SHOTNOISE 1
#define THERMNOISE 2
#define N_GAIN 3
#define BSIM4acLoad cs_bsim45_acLoad
#define BSIM4load cs_bsim45_load
#define BSIM4polyDepletion cs_bsim45_polyDepletion
#define NIintegrate cs_bsim45_integrate
#define DEVfetlim cs_exact_fet_bias
#define DEVlimvds cs_exact_drain_bias
#define DEVpnjlim cs_exact_junction_bias
#define BSIM4setup cs_bsim45_setup
#define BSIM4temp cs_bsim45_temp
#define BSIM4mParam cs_bsim45_mParam
#define BSIM4param cs_bsim45_param
#define BSIM4checkModel cs_bsim45_checkModel
#define BSIM4pTable cs_bsim45_pTable
#define BSIM4mPTable cs_bsim45_mPTable
#define BSIM4pTSize cs_bsim45_pTSize
#define BSIM4mPTSize cs_bsim45_mPTSize
#define BSIM4NumFingerDiff cs_bsim45_NumFingerDiff
#define BSIM4PAeffGeo cs_bsim45_PAeffGeo
#define BSIM4RdseffGeo cs_bsim45_RdseffGeo
#define BSIM4RdsEndIso cs_bsim45_RdsEndIso
#define BSIM4RdsEndSha cs_bsim45_RdsEndSha
#define BSIM4DioIjthVjmEval cs_bsim45_DioIjthVjmEval
#define cs_diagnostic cs_bsim45_record_diagnostic
#define cs_fatal cs_bsim45_record_fatal
#define cs_allocate_size cs_bsim45_allocate_geometry
#define TRUE 1
#define FALSE 0
#define OK 0
#define E_BADPARM 1
#define E_NOMEM 2
#define E_NONFINITE 3
#define MAX(a,b) ((a)>(b)?(a):(b))
#define MIN(a,b) ((a)<(b)?(a):(b))
#define FABS fabs
#define Sqrt sqrt
/* SPICE3f5 src/include/const.h and src/bin/main.c (pinned in NOTICE.md).
   Do not substitute SI2019 constants or the rounded 4.8.3 host VT constant. */
#define CHARGE 1.6021918e-19
#define MODEDCOP (1<<0)
#define MODEAC (1<<1)
#define MODETRAN (1<<2)
#define MODEINITSMSIG (1<<3)
#define MODEINITTRAN (1<<4)
#define MODEINITJCT (1<<5)
#define MODEINITFIX (1<<6)
#define MODEINITPRED (1<<7)
#define MODEUIC (1<<8)
#define MODETRANOP (1<<9)
#define MODEDCTRANCURVE (1<<10)
#define CONSTCtoK 273.15
#define CONSTroot2 (sqrt(2.0))
#define CONSTvt0 (1.3806226e-23 * (27.0 + CONSTCtoK) / 1.6021918e-19)
#define IF_REAL 1
#define IF_INTEGER 2
#define IF_FLAG 3
#define IF_STRING 4
#define IF_REALVEC 5
#define IOP(n,i,t,d) {n,i,t,1}
#define IP(n,i,t,d) {n,i,t,1}
#define OP(n,i,t,d) {n,i,t,0}
#define NSTATVARS 3
#define NDEV 3
#define NUMELEMS(a) (sizeof(a)/sizeof((a)[0]))
typedef const char *IFuid;
typedef struct {const char *keyword; int id,dataType,writable;} IFparm;
typedef union { double rValue; int iValue; char *sValue; struct {int numValue; union {double *rVec;} vec;} v;} IFvalue;
typedef void GENmodel;
typedef void GENinstance;
typedef struct {double real,imag;} SPcomplex;
typedef void Ndata;
typedef struct {int number;} CKTnode;
typedef struct {double values[13][13][2];} SMPmatrix;
typedef struct {
 double CKTtemp,CKTnomTemp,CKTomega;
 double CKTabstol,CKTreltol,CKTvoltTol,CKTgmin,CKTdelta,CKTag[7],CKTdeltaOld[7];
 int CKTmode,CKTbypass,CKTnoncon,integrationMethod;
 double *CKTrhs,*CKTrhsOld,*CKTstate0,*CKTstate1,*CKTstate2;
 double *CKTstates[3];
 int nodeCount,noiseRequested;
 CKTnode nodes[13];
 void *sizeStorage; size_t sizeCapacity; int sizeAllocated,allocationFailed;
 CSBSIM45Diagnostic diagnostics[CS_BSIM45_MAX_DIAGNOSTICS];
 uint32_t diagnosticCount,diagnosticLimit; int diagnosticOverflow,fatalSeen;
} CKTcircuit;
static inline double *SMPmakeElt(SMPmatrix *m,int r,int c) {
 return r>=0&&r<13&&c>=0&&c<13 ? m->values[r][c] : NULL;
}
static inline int CKTmkVolt(CKTcircuit *c,CKTnode **n,IFuid name,const char *suffix) {
 if(c->nodeCount>=12)return E_NOMEM;
 int index=++c->nodeCount; c->nodes[index].number=index; *n=&c->nodes[index]; return OK;
}
int BSIM4NumFingerDiff(CKTcircuit *,double,int,double *,double *,double *,double *);
int BSIM4PAeffGeo(CKTcircuit *,double,int,int,double,double,double,double,double *,double *,double *,double *);
int BSIM4RdseffGeo(CKTcircuit *,double,int,int,int,double,double,double,double,double,int,double *);
int BSIM4RdsEndIso(CKTcircuit *,double,double,double,double,double,double,int,int,double *);
int BSIM4RdsEndSha(CKTcircuit *,double,double,double,double,double,double,int,int,double *);
void cs_diagnostic(CKTcircuit *,uint32_t,CSBSIM45DiagnosticCode,int,int,double,const char *,...);
void cs_fatal(CKTcircuit *,uint32_t,const char *,IFuid *);
void *cs_allocate_size(CKTcircuit *,size_t);
/* Exact-bias physics never owns Newton limiting or convergence policy. */
static inline double cs_exact_fet_bias(double v,double old,double threshold){return v;}
static inline double cs_exact_drain_bias(double v,double old){return v;}
static inline double cs_exact_junction_bias(double v,double old,double vt,double crit,int *check){*check=0;return v;}
int NIintegrate(CKTcircuit *,double *,double *,double,int);
int BSIM4load(GENmodel *,CKTcircuit *);
/* Stable H=1/(1+j*omega*tau), including an overflowing omega*tau.
   Validated nonnegative finite inputs; no history or caller storage retained. */
static inline void cs_bsim45_relaxation(double omega,double tau,double *real,double *lag,double *conductanceScale) {
 if(tau==0||omega==0){*real=1;*lag=0;*conductanceScale=0;return;}
 if(omega<=1/tau){double x=omega*tau,d=1+x*x;*real=1/d;*lag=x/d;*conductanceScale=omega*(*lag);}
 else {double r=(1/omega)/tau,d=1+r*r;*real=r*r/d;*lag=r/d;*conductanceScale=(1/tau)/d;}
}
int BSIM4acLoad(GENmodel *,CKTcircuit *);
#endif
