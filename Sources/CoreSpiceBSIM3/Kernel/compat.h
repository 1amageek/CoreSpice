#ifndef CS_COMPAT_H
#define CS_COMPAT_H
#define BSIM3setup cs_bsim3_setup
#define BSIM3temp cs_bsim3_temp
#define BSIM3load cs_bsim3_load
#define BSIM3acLoad cs_bsim3_acLoad
#define BSIM3mParam cs_bsim3_mParam
#define BSIM3param cs_bsim3_param
#define BSIM3checkModel cs_bsim3_checkModel
#define BSIM3unsetup cs_bsim3_unsetup
#define BSIM3pTable cs_bsim3_pTable
#define BSIM3mPTable cs_bsim3_mPTable
#define BSIM3pTSize cs_bsim3_pTSize
#define BSIM3mPTSize cs_bsim3_mPTSize
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#define NIintegrate cs_bsim3_integrate
#define cs_diagnostic cs_bsim3_diagnostic
#define cs_fatal cs_bsim3_fatal
#define cs_allocate_size cs_bsim3_allocate_size
#define TRUE 1
#define FALSE 0
#define OK 0
#define E_BADPARM 1
#define E_NOMEM 2
#define MAX(a,b) ((a)>(b)?(a):(b))
#define FABS fabs
#define Sqrt sqrt
#define CONSTvt0 0.02586419
#define CONSTroot2 1.4142135623730951
#define CONSTCtoK 273.15
#define CONSTKoverQ 8.617087e-5
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
typedef struct {const char *keyword;int id,dataType,writable;} IFparm;
typedef union { double rValue; int iValue; char *sValue; struct {int numValue; union {double *rVec;}vec;} v; } IFvalue;
typedef void GENmodel;
typedef void GENinstance;
typedef struct {double real,imag;} SPcomplex;
typedef void Ndata;
typedef struct {int number;} CKTnode;
typedef struct {double values[8][8][2];} SMPmatrix;
typedef struct {
 double CKTabstol,CKTreltol,CKTvoltTol,CKTgmin,CKTtemp,CKTnomTemp,CKTomega,CKTdelta;
 double CKTag[7],CKTdeltaOld[7];int CKTmode,CKTbypass,CKTnoncon,nodeCount,method;
 double *CKTrhs,*CKTrhsOld,*CKTstate0,*CKTstate1,*CKTstate2; CKTnode nodes[8];
 char diagnostic[32768]; size_t diagnosticCount; void *sizeStorage; size_t sizeCapacity; int sizeAllocated; int diagnosticOverflow;
} CKTcircuit;
static inline double *SMPmakeElt(SMPmatrix *m,int r,int c){return r>=0&&r<8&&c>=0&&c<8?m->values[r][c]:NULL;}
static inline int CKTmkVolt(CKTcircuit *c,CKTnode **n,IFuid name,const char *suffix){if(c->nodeCount>=7)return E_NOMEM;int i=++c->nodeCount;c->nodes[i].number=i;*n=&c->nodes[i];return OK;}
static inline int CKTdltNNum(CKTcircuit *c,int n){return OK;}
void cs_diagnostic(CKTcircuit *,const char *,...);
void cs_fatal(CKTcircuit *,const char *,IFuid *);
void *cs_allocate_size(CKTcircuit *,size_t);
static inline double cs_exact_fet_bias(double v,double old,double threshold){return v;}
static inline double cs_exact_drain_bias(double v,double old){return v;}
static inline double cs_exact_junction_bias(double v,double old,double vt,double crit,int *check){*check=0;return v;}
int NIintegrate(CKTcircuit *,double *,double *,double,int);
#endif
