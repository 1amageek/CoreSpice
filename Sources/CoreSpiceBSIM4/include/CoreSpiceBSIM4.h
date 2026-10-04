#ifndef CORE_SPICE_BSIM4_H
#define CORE_SPICE_BSIM4_H
#include <stdint.h>
#define CS_BSIM4_SLOTS 13
#define CS_BSIM4_STATES 29
#define CS_BSIM4_MATRIX 169
/* Opaque owner. The caller serializes all calls and exactly-once destruction.
   No borrowed input/output is retained. Diagnostics borrow the handle lifetime. */
typedef struct CSBSIM4Handle CSBSIM4Handle;
typedef struct {
 int nodeCount,drainPrime,sourcePrime,gatePrime,gateMid,bodyPrime,drainBody,sourceBody,chargeNode;
 int noiseRequested,maintainerUnsupportedNoiseMode;
} CSBSIM4Topology;
typedef struct {
 double residual[13],rhs[13],charge[13],real[169],imaginary[169],states[29],operatingPoint[8],intrinsicCharges[4];
 uint64_t token;
} CSBSIM4Result;
enum {CS_BSIM4_OK=0,CS_BSIM4_PARAMETER=1,CS_BSIM4_MEMORY=2,CS_BSIM4_NUMERICAL=3,
      CS_BSIM4_HISTORY=4,CS_BSIM4_DIAGNOSTICS=5,CS_BSIM4_VERSION=6,CS_BSIM4_RESOURCE=7};
int cs_bsim4_create(int polarity,const char *version,double temperature,int noiseRequested,CSBSIM4Handle **);
void cs_bsim4_destroy(CSBSIM4Handle *);
int cs_bsim4_parameter(CSBSIM4Handle *,int model,const char *name,double value);
int cs_bsim4_set_stress_budget(CSBSIM4Handle *,uint32_t maximumIterations);
int cs_bsim4_initial_conditions(CSBSIM4Handle *,const double values[3]);
int cs_bsim4_prepare(CSBSIM4Handle *,CSBSIM4Topology *);
const char *cs_bsim4_diagnostics(const CSBSIM4Handle *);
int cs_bsim4_initialize_history(CSBSIM4Handle *,const double bias[13]);
/* Slots: ground=0,D=1,G=2,S=3,B=4; other roles come from topology.
   mode: 0 DC,1 AC,2 backward Euler,3 trapezoidal; omega is rad/s.
   Original current/charge multipliers are applied; outer parallel m is external. */
int cs_bsim4_evaluate(CSBSIM4Handle *,const double bias[13],int mode,double omega,double dt,double gmin,CSBSIM4Result *);
void cs_bsim4_invalidate_trial(CSBSIM4Handle *);
int cs_bsim4_commit(CSBSIM4Handle *,uint64_t token);
int cs_bsim4_accepted_states(const CSBSIM4Handle *,double states[29]);
#endif
