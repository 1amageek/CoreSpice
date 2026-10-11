#ifndef CORE_SPICE_BSIM45_H
#define CORE_SPICE_BSIM45_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Exact-release preparation and static I/Q/Jacobians and AC/transient NQS. */
typedef struct CSBSIM45Owner CSBSIM45Owner;
typedef enum {
 CS_BSIM45_OK, CS_BSIM45_VERSION, CS_BSIM45_SCHEMA, CS_BSIM45_PARAMETER,
 CS_BSIM45_STATE, CS_BSIM45_RESOURCE, CS_BSIM45_MEMORY, CS_BSIM45_DIAGNOSTICS,
 CS_BSIM45_KERNEL, CS_BSIM45_NONFINITE, CS_BSIM45_HISTORY
} CSBSIM45Status;
typedef enum { CS_BSIM45_INSTANCE, CS_BSIM45_MODEL, CS_BSIM45_KERNEL_ROLE = -1 } CSBSIM45Role;
typedef enum { CS_BSIM45_REAL=1, CS_BSIM45_INTEGER, CS_BSIM45_FLAG, CS_BSIM45_TEXT, CS_BSIM45_VECTOR } CSBSIM45Kind;
typedef enum { CS_BSIM45_DIAG_WARNING=1, CS_BSIM45_DIAG_FATAL, CS_BSIM45_DIAG_INPUT, CS_BSIM45_DIAG_RESOURCE } CSBSIM45DiagnosticCode;
enum { CS_BSIM45_MAX_DIAGNOSTICS=128, CS_BSIM45_LOCAL_SLOTS=13, CS_BSIM45_STATE_SLOTS=29 };
typedef struct {
 size_t maximumOwnerBytes;
 uint32_t maximumStressIterations;
 uint32_t maximumDiagnostics;
 double ambientKelvin, nominalKelvin;
 int noiseTopology;
} CSBSIM45Conditions;
typedef struct {
 CSBSIM45DiagnosticCode code;
 CSBSIM45Role role;
 int32_t parameterID;
 uint32_t sourceSite;
 double value;
 char text[192];
} CSBSIM45Diagnostic;
typedef struct { const char *name; int32_t selector; CSBSIM45Kind kind; } CSBSIM45ParameterInfo;
typedef struct {
 int nodeCount, drainPrime, sourcePrime, gatePrime, gateMid;
 int bodyPrime, drainBody, sourceBody, chargeNode, noiseTopology;
 int stateCount, polarity;
 uint32_t stressIterations;
 double length, width, fingers, effectiveLength, effectiveWidth;
 double effectiveCVLength, effectiveCVWidth, threshold, mobility, saturationVelocity;
 double nominalKelvin, ambientKelvin, ud, sc, sca, bulkPotential, criticalVoltage;
} CSBSIM45PreparedInfo;
typedef struct {
 double current[CS_BSIM45_LOCAL_SLOTS], charge[CS_BSIM45_LOCAL_SLOTS];
 double conductance[CS_BSIM45_LOCAL_SLOTS * CS_BSIM45_LOCAL_SLOTS];
 double capacitance[CS_BSIM45_LOCAL_SLOTS * CS_BSIM45_LOCAL_SLOTS];
} CSBSIM45StaticResult;
typedef struct {
 double real[CS_BSIM45_LOCAL_SLOTS * CS_BSIM45_LOCAL_SLOTS];
 double imaginary[CS_BSIM45_LOCAL_SLOTS * CS_BSIM45_LOCAL_SLOTS];
} CSBSIM45ACResult;
typedef enum { CS_BSIM45_BE=1, CS_BSIM45_TRAPEZOIDAL=2 } CSBSIM45IntegrationMethod;
/* Authorization is valid only during this owner's live allocation. No pointer
   is dereferenced through a token. Higher layers retain an identity marker. */
typedef struct { uintptr_t owner; uint64_t generation; } CSBSIM45TrialToken;
typedef struct {
 double residual[CS_BSIM45_LOCAL_SLOTS];
 double jacobian[CS_BSIM45_LOCAL_SLOTS * CS_BSIM45_LOCAL_SLOTS];
 double states[CS_BSIM45_STATE_SLOTS];
 CSBSIM45TrialToken token;
} CSBSIM45TransientResult;
typedef struct {
 double accepted[CS_BSIM45_STATE_SLOTS], older[CS_BSIM45_STATE_SLOTS];
} CSBSIM45History;
/* All calls, including destroy, require exclusive access to the owner.
   create borrows its arguments only for the call and clears *out on failure.
   The allocation contains every mutable byte; owner_size excludes malloc metadata.
   A failed setter/prepare is terminal. Prepared inspection is all-or-nothing.
   destroy accepts NULL; an acquired owner must be destroyed exactly once. */
size_t cs_bsim45_owner_size(void);
const char *cs_bsim45_release(void);
const char *cs_bsim45_adaptation(void);
CSBSIM45Status cs_bsim45_create(const char *release, uint32_t schemaRevision, int polarity,
 const CSBSIM45Conditions *conditions, CSBSIM45Owner **out);
CSBSIM45Status cs_bsim45_set_model(CSBSIM45Owner *, int32_t selector, CSBSIM45Kind, double value);
CSBSIM45Status cs_bsim45_set_instance(CSBSIM45Owner *, int32_t selector, CSBSIM45Kind, double value);
/* Copies 1..3 values into original IC fields; retains no caller pointer. */
CSBSIM45Status cs_bsim45_set_initial_conditions(CSBSIM45Owner *, const double *values, size_t count);
CSBSIM45Status cs_bsim45_prepare(CSBSIM45Owner *);
CSBSIM45Status cs_bsim45_prepared_info(const CSBSIM45Owner *, CSBSIM45PreparedInfo *out);
/* Static equilibrium at exact physical node voltages; ground/unused/NQS slots
   must be zero. Borrows bias and out for this exclusive call, retaining neither.
   At signed VDS=0, Jacobians differentiate the selected forward branch.
   No allocation/setup/history commit. Outputs are A, C, S and F, row-major.
   Every evaluation attempt invalidates pending trial authorization. Invalid input
   leaves accepted/older history and output unchanged; kernel failure is terminal.
   out is written only after every result element passes finite validation. */
CSBSIM45Status cs_bsim45_evaluate_static(CSBSIM45Owner *, const double *bias,
 size_t count, double gmin, CSBSIM45StaticResult *out);
/* Physical complex nodal admittance (S), row-major, angular frequency rad/s.
   Same bias/exclusivity/atomic-failure contract as static. omega is finite >= 0.
   No allocation/setup or accepted/older history mutation. State0 is scratch.
   Transient deficit row/column are zero; ACNQSMOD is preparation-owned. */
CSBSIM45Status cs_bsim45_evaluate_ac(CSBSIM45Owner *, const double *bias,
 size_t count, double gmin, double omega, CSBSIM45ACResult *out);
/* Establish equilibrium at supplied physical bias; deficit and charge currents
   are zero. Reinitialization is explicit and invalidates any pending trial.
   Finite 29-state validation precedes atomic accepted/older publication. */
CSBSIM45Status cs_bsim45_initialize_history(CSBSIM45Owner *, const double *bias,
 size_t count, double gmin);
/* bias obeys static's physical-voltage contract. The separate deficit coordinate
   is not volts: internal deficit is polarity * coordinate * 1e-9 C. QS requires
   zero deficit. dt is finite positive with finite 1/dt (BE) or 2/dt (TR).
   Full augmented residual is A; Jacobian columns differentiate physical volts
   or the scaled deficit coordinate. No accepted/older history writes.
   out publishes atomically, including a fresh owner-scoped commit token. */
CSBSIM45Status cs_bsim45_evaluate_transient(CSBSIM45Owner *, const double *bias,
 size_t count, double deficitCoordinate, double gmin,
 CSBSIM45IntegrationMethod method, double dt, CSBSIM45TransientResult *out);
CSBSIM45Status cs_bsim45_commit(CSBSIM45Owner *, CSBSIM45TrialToken);
CSBSIM45Status cs_bsim45_reject(CSBSIM45Owner *, CSBSIM45TrialToken);
/* Nonmutating inspection is available after internal failure if initialized. */
CSBSIM45Status cs_bsim45_history(const CSBSIM45Owner *, CSBSIM45History *out);
size_t cs_bsim45_diagnostic_count(const CSBSIM45Owner *);
CSBSIM45Status cs_bsim45_diagnostic_at(const CSBSIM45Owner *, size_t index, CSBSIM45Diagnostic *out);
size_t cs_bsim45_parameter_count(CSBSIM45Role);
CSBSIM45Status cs_bsim45_parameter_at(CSBSIM45Role, size_t index, CSBSIM45ParameterInfo *out);
void cs_bsim45_destroy(CSBSIM45Owner *);
#ifdef __cplusplus
}
#endif
#endif
