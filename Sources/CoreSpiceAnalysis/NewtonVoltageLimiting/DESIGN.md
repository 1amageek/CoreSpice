# NewtonVoltageLimiting

## Purpose and Scope

Internal simultaneous admission of a binary64 Newton direction. Parent:
[CoreSpiceAnalysis](../DESIGN.md). No children.

## Responsibilities and Boundaries

The helper selects a common step scale. Each bound device remains the authority
for its own limiting rule; this helper owns no device law or stamping behavior.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Analysis](../DESIGN.md) | parent | Newton buffers, cancellation and operation budget | Caller owns the solve | Exhaustion must remain a convergence failure |
| [Devices](../../CoreSpiceDevices/DESIGN.md) | depends on | VoltageLimitingDevice | Independent candidate admission | First-iteration eligibility is preserved |

## Architecture

```text
previous + alpha*(raw-previous) -> candidate
  -> independent device limiter probes -> unchanged by every limiter -> accepted
                                      -> changed -> halve alpha -> bounded retry
```

## Contracts and Invariants

All eligible limiters inspect the same candidate independently. Candidate and
scratch are caller-owned, matching finite vectors. No sequential modification
can invalidate an earlier limiter. Returned scale includes the caller's damping.
Exhaustion restores the previous candidate and returns nil. No device evaluation
error is suppressed. Compensated coordinates remain outside this binary64 helper.

## State, Ownership, and Lifecycle

No retained or shared state. One Newton solve owns all arrays. Existing candidate
and scratch storage are overwritten without array materialization per probe;
borrowed raw/previous vectors do not escape. No I/O or callback runs under a lock.

## Failure, Concurrency, and Constraints

Positive maximum probes bounds halving. Checked work admission precedes each
probe/copy/device call. Cancellation, invalid dimensions, invalid damping and
nonfinite device output are explicit errors. Device callbacks retain their own
ownership/isolation contracts on every target; Native CPU evidence is local.

## Verification and Change Impact

NewtonVoltageLimitingTests owns the actual three-diode shared-terminal overflow
counterexample, independent ordering, first-iteration eligibility, damping,
exhaustion, nonfinite failure, cancellation and work admission. Analysis owns
full convergence and consumer regressions after helper integration.
