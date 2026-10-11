#ifndef CORE_SPICE_BSIM45_H
#define CORE_SPICE_BSIM45_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Preparation only: this ABI does not provide numerical evaluation capability. */
typedef struct CSBSIM45Owner CSBSIM45Owner;
typedef enum {
 CS_BSIM45_OK, CS_BSIM45_VERSION, CS_BSIM45_SCHEMA, CS_BSIM45_PARAMETER,
 CS_BSIM45_STATE, CS_BSIM45_RESOURCE, CS_BSIM45_MEMORY, CS_BSIM45_DIAGNOSTICS,
 CS_BSIM45_KERNEL, CS_BSIM45_NONFINITE
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
size_t cs_bsim45_diagnostic_count(const CSBSIM45Owner *);
CSBSIM45Status cs_bsim45_diagnostic_at(const CSBSIM45Owner *, size_t index, CSBSIM45Diagnostic *out);
size_t cs_bsim45_parameter_count(CSBSIM45Role);
CSBSIM45Status cs_bsim45_parameter_at(CSBSIM45Role, size_t index, CSBSIM45ParameterInfo *out);
void cs_bsim45_destroy(CSBSIM45Owner *);
#ifdef __cplusplus
}
#endif
#endif
