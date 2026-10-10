#ifndef CORE_SPICE_BSIM3_H
#define CORE_SPICE_BSIM3_H
#include <stddef.h>
#include <stdint.h>
/* Private ABI: caller serializes all handle accesses, including destruction.
   Inputs are borrowed for the call only; results own no pointers. */
typedef struct CSBSIM3Handle CSBSIM3Handle;
typedef struct { int nodeCount, drainPrime, sourcePrime, chargeNode; } CSBSIM3Topology;
typedef struct {
 double residual[8], rhs[8], charge[8], real[64], imaginary[64], states[32], operatingPoint[8];
 uint64_t token;
} CSBSIM3Result;
enum { CS_BSIM3_OK=0, CS_BSIM3_PARAMETER=1, CS_BSIM3_MEMORY=2,
       CS_BSIM3_NUMERICAL=3, CS_BSIM3_HISTORY=4, CS_BSIM3_DIAGNOSTICS=5 };
CSBSIM3Handle *cs_bsim3_create(int polarity,double temperature);
/* Exact single-owner calloc payload, without allocator metadata. */
size_t cs_bsim3_owner_size(void);
void cs_bsim3_destroy(CSBSIM3Handle *handle);
int cs_bsim3_parameter(CSBSIM3Handle *,int model,const char *name,double value);
int cs_bsim3_initial_conditions(CSBSIM3Handle *,const double values[3]);
int cs_bsim3_prepare(CSBSIM3Handle *,CSBSIM3Topology *);
const char *cs_bsim3_diagnostics(const CSBSIM3Handle *);
int cs_bsim3_initialize_history(CSBSIM3Handle *,const double bias[8]);
/* mode: 0 DC, 1 AC, 2 backward Euler, 3 trapezoidal. Frequency is angular Hz (rad/s).
   Slot zero is ground. Charge-node bias is the original scaled deficit variable. */
int cs_bsim3_evaluate(CSBSIM3Handle *,const double bias[8],int mode,double angularFrequency,
                     double dt,double gmin,CSBSIM3Result *);
int cs_bsim3_commit(CSBSIM3Handle *,uint64_t token);
/* Four uncorrelated current PSDs in A^2/Hz: rd, rs, id, flicker.
   Frequency is strictly positive Hz. No retained output or noise history. */
int cs_bsim3_noise_spectrum(CSBSIM3Handle *,const double bias[8],double frequency,
                            double gmin,double densities[4]);
void cs_bsim3_accepted_states(const CSBSIM3Handle *,double states[32]);
#endif
