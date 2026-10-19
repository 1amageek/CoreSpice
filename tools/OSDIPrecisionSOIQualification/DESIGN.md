# Latest SOI Compensated Circuit Qualification

## Purpose and Scope

Parent: [CoreSpice released OSDI contract](../../DESIGN.md#released-osdi-adoption-and-semiconductor-production-gates).
Own finite SOI 101.0.0 n/p PD/DD compensated circuit witnesses. The existing
ordinary/legacy qualification profiles remain independent and immutable.

## Responsibilities and Boundaries

`driver.py prepare` admits the released SOI source/model/program evidence and a
caller-selected exact 1.0.1 worker build receipt. It freezes four explicit loaded
circuits and the original 2 ns PWL gate schedule. Only TYPE, SOIMOD and signed
supply/gate/initial electrical potentials vary from the retained n-DD circuit.
Original current/voltage/thermal equation tolerances remain 1e-12 A, 1e-10 V and
1e-12 W. Self-heating is disabled in this original six-terminal circuit profile;
thermal/private-node point evidence does not imply circuit coverage here.

The dedicated CLI test owns actual prepared command execution, direct Native API
rerun, batch/prepared executable invocation, strict paired persistence and typed
refusal/cancellation/release behavior. This tool owns independent complete saved
trajectory replay; no ordinary Q difference, C*x or copied worker output replaces
source-program F/DeltaQ evaluation.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Released adoption](../../DESIGN.md#released-osdi-adoption-and-semiconductor-production-gates) | parent | Exact public dependency and worker identities | CS1.3 evidence | No old worker receipt certifies a new executable |
| [Precision replay](../OSDIDCVerification/Precision/DESIGN.md) | depends on | Saved paired artifact admission and independent 512-bit F/DeltaQ | Whole returned candidate validation | Original strict equation policy is unchanged |
| [CLI tests](../../Tests/CoreSpiceOSDICLITests/DESIGN.md) | used by | Dedicated four-case witnesses | API/batch/prepared artifact publication | No changes to historical family helpers |

## Architecture

```text
released source/model/program proof + new worker receipt + original circuit
  -> immutable four-case input/profile manifest
  -> actual Native API / batch / prepared execution
  -> complete high/low/time/history/configuration artifact
  -> independent 512-bit F/DeltaQ projection and BE/TR residual replay
```

## Contracts and Invariants

Preparation validates every referenced source/model/program/worker/profile hash,
requires the actual four n/p PD/DD qualification selectors, and retains the exact
old point proof as provenance rather than worker qualification. An unchanged exact build receipt can be reused after its sources match the public
tag byte-for-byte. The numeric profile must name the selected worker image and
the same complete released source set as its build receipt. Any semantic-profile
identity declared by that profile must match the admitted compiler program.
New circuit execution and independent replay bind the selected
worker; existing point receipts do not certify those new circuit runs. No external
compiler is invoked and the large model is referenced rather than duplicated.
The full stop is 2e-9 seconds with maximum requested step 1e-10 seconds and the
original three PWL knots. No pilot shortening or tolerance inflation is admitted.
Before generating source, preparation checks the complete retained base-request
SHA-256 `2e04e9b4ca3fca95cd60da6eec48aa3c6e4c79f7beb421d3bcfac3b7b130c80e`
and analysis-manifest SHA-256
`569a695ffd173701bfb840316053e4ef6436782eebedb4a35ee0870ba6c4e3b7`.
These frozen identities cover the circuit, all tolerances and the complete stimulus;
changing the original profile requires an explicit qualification contract update.
All four cases are mandatory; missing inputs and unsupported runtime behavior
fail explicitly. API/CLI candidate equality permits independent replay once per
bit-identical trajectory, retaining each lane's identity. Each distinct candidate
must otherwise receive its own complete replay.

## State, Ownership, and Lifecycle

One serialized test suite owns each fresh case directory. Metadata preparation
closes its image before source execution. Each completed Native execution has
released model/worker owners; fresh rerun and cancellation/refusal followed by
successful fresh execution demonstrate continued availability. Artifacts remain
for diagnostics. Prepared owners and foreign worker processes are production
owners; tests do not implement substitute arithmetic or hidden state acceptance.
Separately filtered cases may execute concurrently in distinct processes after
the compiled test bundle is frozen. Their output directories, mutable state and
resource accountants are independent; model/program/worker inputs are read-only.

## Failure, Concurrency, and Constraints

Native CLI and independent replay commands have caller-selected positive timeouts
and process-group cleanup. Read-only Git identity commands have ten-second
deadlines and launch no model/compiler/worker. Swift CLI calls delegate to SignoffToolSupport and retain raw bytes,
typed failure and a pending cleanup owner when bounded cleanup cannot complete. Expected refusals publish no waveform/paired files. Python optimized mode
is refused because the independent replay dependency contains assertion checks.
The fixture uses the public adapter capacity calculator and explicit original
Native/live envelopes plus worker/precision ownership. No guessed allocator/RSS
claim is made. Independent replay retains its 128 MiB output reserve and bounded
one-child-at-a-time profile.
Original full qualification methods retain their 20-minute deadline; individual
CLI and model calls retain their own bounded policies. Outer test termination
must clean all owned descendant process groups, including new-session children.
After the first two API lanes complete, the root may freeze an explicit API
witness receipt for the DD continuation methods documented by the
[CLI tests](../../Tests/CoreSpiceOSDICLITests/DESIGN.md). This is test-execution
granularity only: it preserves the exact completed artifacts and all remaining
numerical lanes. Continuation requires explicit filtering and the receipt
environment variable; it is never automatic path/existence reuse. Its 24-minute
per-test deadline changes no numerical or resource ceiling.

## Verification and Change Impact

Run prepare, then the separately filterable four `OSDISoi101PrecisionCLITests`
methods using the emitted input manifest, newly built CLI and an external timeout.
Run `driver.py replay` with the retained independent oracle build receipt and new
case outputs. Root owns all build/execution. Completion requires all four schedules,
all API/batch/prepared bit-preserving persisted artifacts, refusal/lifetime checks
and independent same-candidate residual replay. A failed case remains a blocker;
these finite trajectories establish neither all-history nor foundry qualification.


### Reproducible Commands

```sh
python3 tools/OSDIPrecisionSOIQualification/driver.py prepare \
  --qualification <swift-osdi-SOI101/latest-qualification.json> \
  --base-request <retained-latest-soi/request.json> \
  --analysis-manifest <retained-latest-soi/analysis-manifest.json> \
  --worker-receipt <released-1.0.1-worker/receipt.json> \
  --osdi-root <clean-public-swift-osdi-1.0.1-checkout> --output <fresh-inputs>
```

Set `CORESPICE_OSDI_SOI101_QUALIFICATION=<fresh-inputs>/inputs.json`,
`CORESPICE_OSDI_CLI_EXECUTABLE=<new-public-graph-corespice>` and
`CORESPICE_OSDI_SOI101_TIMEOUT_SECONDS=600`. Root builds
`CoreSpiceOSDICLITests` once and runs each of `fullNPD`, `fullNDD`, `fullPPD` and
`fullPDD` with `swift test --test-product CoreSpiceOSDICLITests --skip-build
--disable-xctest --force-resolved-versions --filter
OSDISoi101PrecisionCLITests/<method>` under an external timeout.

```sh
python3 tools/OSDIPrecisionSOIQualification/driver.py replay \
  --inputs <fresh-inputs>/inputs.json --oracle-build <independent-build-receipt> \
  --output <fresh-replay> --timeout 660
```

The released SDK's retained SOI 101 independent-oracle receipt may supply the
existing compatible engine; no duplicate oracle/model compilation is required.
The driver validates that engine through the existing replay owner's admission.


`check_admission.py` accepts the same prepare input flags and a fresh output
folder. It corrupts the qualification outcome, required polarity/mode coverage,
source identity, worker identity, numeric-profile/worker association, original
equation gate, relative gate and middle PWL knot independently. The profile/worker
counterexample updates both the copied numeric profile and its enclosing receipt's
file digest, so hash validity alone cannot satisfy the association. Each
must refuse before `inputs.json` publication. It performs only bounded file/hash/Git
admission, never library loading or arithmetic execution. Root runs these controls
with an external timeout; a valid prepare run is the positive witness.
