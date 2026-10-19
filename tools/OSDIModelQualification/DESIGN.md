# OSDI Model Family Qualification Capture

## Purpose and Scope

Own the common same-artifact capture boundary for the approved BSIM model-family
matrix. Parent: [CoreSpice](../../DESIGN.md#s3-osdi-dc-integration-contract).
Children are the independently owned [CMG](CMG/DESIGN.md), [IMG](IMG/DESIGN.md) and
[SOI](SOI/DESIGN.md) source/request qualifications. The historical SOI4.7.0 source
selection is retained separately from the current SOI101.0.0 profile. The existing unchanged BULK
107.2.1 authority remains the
[independent DC tool](../OSDIDCVerification/DESIGN.md). A successful capture
establishes only its recorded native circuit cases; model physics, foundry
qualification and other analysis/platform capabilities are outside this scope.
The S4 capture/replay entry point composes the independent
[dynamic ABI contract](../OSDIDCVerification/DESIGN.md#s4-independent-dynamic-qualification)
with the same admitted four model images. It does not infer dynamic results from
the preceding DC evidence.

## Responsibilities and Boundaries

Each child owns official-source version admission, source/archive/include identity,
actual full-residual compiler invocation, resulting artifact and exact circuit
requests. This parent validates their immutable fragment identities and composes
them with the existing independent C oracle. It owns neither physics, model
adaptation, parameter meaning, a new numerical solver nor the production adapter.
Root integration tests own CoreSpice API/CLI execution and independent validation
of the complete returned candidate through the recorded command.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | Four-family S3 evidence | Approval and integration owner | Captured ordinary points are not universal certification |
| [Independent DC oracle](../OSDIDCVerification/DESIGN.md) | depends on | Immutable C executable, checked request translation and bounded process runner | One independent implementation | Preserve original capture bytes |
| [CMG](CMG/DESIGN.md) | child | Exact official source and requests | CMG112.1.0 candidate | Child owns source/version correspondence |
| [IMG](IMG/DESIGN.md) | child | Exact official source and requests | IMG103.1.0 candidate | Child owns supported source options |
| [SOI](SOI/DESIGN.md) | child | Exact official source and requests | SOI4.7.0 selected formal VA release | Separate 4.x version series; no equivalence with the mismatched 100.1.1 label |

## Architecture

```text
unchanged BULK/analytic capture -> checked baseline oracle + request translator
official source/compiler/artifact/request fragment per additional family
  -> exact byte verification -> direct C circuit solve -> full candidate validate
  -> merged same-schema manifest + explicit complete/missing family matrix
CoreSpice API/CLI full candidate -> recorded validation command -> physical equations
```

## Contracts and Invariants

### Released SDK Profile Admission

The current migration uses `profiles.json` as the single authority for finite DC
family/version, exact source inventory, library/descriptor, required request IDs
and request-byte identity. `historical-soi47-v1` retains the previous four-family
matrix. `latest-soi101-v1` retains unchanged BULK/CMG/IMG inputs and requires the
separately generated SOI101 matrix. A stale historical `familyMatrix`, an appended
point, or an aggregate case count cannot establish either profile.

Every family also pins its already-qualified generated-image SHA-256. Library and
family-binding records cannot jointly nominate a replacement image. A fresh
compilation that changes image bytes requires a separate explicit artifact
qualification and profile-authority decision; unchanged source/version strings
alone cannot retain the same frozen profile. Availability paths may change while
the admitted image bytes remain exact.

`family_profile.py` checks the selected authority before capture and before publication.
The manifest records a profile ID/digest and per-family exact source, library,
compiler and request bindings. Every required case must bind the admitted library
and descriptor and retain its exact frozen request; matrix rows are derived from
these verified records. Complete-profile admission rejects missing/wrong families,
versions, source bytes, library identities, cases and stale matrix claims. Partial
capture remains explicitly incomplete. The Swift test-support admission reads the
same tracked authority and checks the same semantic joins before executing a
family circuit; it does not infer policy from a mutable manifest.

The latest SOI source/selector envelope and acquisition/compilation/solve flow are
owned by [SOI](SOI/DESIGN.md#soi101-current-finite-profile). New source/program or
compiler qualification is never inferred from this admission policy. Historical
compiler/image bindings remain valid only for their unchanged recorded inputs.

```text
tracked profile + exact child requests/source/compiler/artifact
  -> checked family bindings -> independent solve and complete-vector validation
  -> recomputed family matrix + profile binding -> Swift admission -> actual adapter
```

The historical common command is selected explicitly with
`--profile historical-soi47-v1`; the default is `latest-soi101-v1`:

```text
python3 tools/OSDIModelQualification/capture.py
  --profile <latest-soi101-v1 or historical-soi47-v1>
  --oracle-manifest <immutable original fifteen-case baseline manifest>
  --fragment <exact child fragment> [--fragment <another fragment>]
  --output <fresh output directory>
```

Each fragment uses `corespice.osdi.model-fragment.v1` with these fields:

| Field | Owner and contract |
|---|---|
| `family`, `version`, `officialSourceURL` | Child-authorized exact official-source version; no inferred upgrade |
| `library` | `id`, absolute `path`, `sha256`, `descriptorIndex`, `descriptorName` of generated native image |
| `sourceFiles` | Nonempty array of absolute `path` and SHA-256 pairs covering the primary source and all includes |
| `compiler` | Absolute `path` and exact SHA-256 of the approved compiler |
| `compilerProfileReceipt` | Absolute `path` and SHA-256 of the already qualified full-residual profile receipt |
| `requests` | Absolute `path` and SHA-256 of a child-owned `corespice.osdi.dc-inputs.v1` document |
| `provenanceReceipt` | Absolute `path` and SHA-256 of retained source/archive/compile command and diagnostics evidence |

The parent checks every listed file before execution and again before publishing.
The baseline manifest and its oracle/translator/header/library/snapshot identities
are checked independently. The translator is imported from its captured,
hash-verified snapshot, not from mutable current source. New compilation of the
oracle, a model, Rust or Swift is not part of this parent command.

### Historical SOI Version Authority Decision

The user resolved the source-version conflict by requiring the newest actual
official stable source. The SOI child verified that the official 4.7.0 archive dated
2025-05-19 contains formal Verilog-A source, while the public 100.1.1 link supplies
100.1.0 content from 2023. The selected target is therefore SOI4.7.0, in its separate
4.x version series. Admission requires its actual source identity; neither the
100.1.1 page label nor a renamed 100.1.0 archive can substitute. The earlier partial
capture remains an immutable historical record with its then-requested missing
100.1.1 target. A fresh capture owns the resolved four-family decision.

The merged result uses `corespice.osdi.dc-manifest.v1`, preserving the baseline
library/case records and appending fresh child cases and exact validation argv.
Each child circuit can reference only its admitted library ID. Global case/library
IDs are unique. The actual descriptor name must equal the fragment claim. Every
expected-converged case must solve and independently validate every unknown within
the frozen strict unit-specific equation absolute tolerances. There is no relative
residual inflation, dropped coordinate or policy adjustment after failure.

`qualificationComplete` is true only when all approved families and versions are
present with successful captured cases. A missing family remains explicitly
missing in `familyMatrix`; successful capture of available cases does not assert
four-family completion. Source-label/content conflicts require resolution by the
owning child and root before that family can be admitted. A receipt does not infer
official model correctness from a website label or successful compilation.

## Runtime Flows

Admit immutable baseline -> validate child fragment/source identities -> create a
fresh capture directory -> solve each new circuit -> validate its complete returned
vector -> verify all source identities again -> publish one manifest. A failed
solve, expected-outcome mismatch or changed file stops publication. Existing
baseline/child receipts are read-only and never rewritten. Downstream validation
uses `validationBaseCommand` plus one candidate assignment per semantic unknown.

## State, Ownership, and Lifecycle

Capture state belongs to one Python process. Every C invocation owns fresh native
storage and terminates before its result is consumed. Existing immutable artifact
files and manifests may be shared by readers. The merged manifest retains explicit
input-fragment and baseline-manifest paths/hashes and snapshots of those documents.

## Failure, Concurrency, and Constraints

The baseline runner supplies bounded argv, CPU/wall time and output-file limits.
Fragment and request JSON have the same one-MiB read ceiling; source file count,
family count and total case count are bounded. No shell command construction,
implicit artifact discovery, source modification or model fallback is used.
SHA mismatch, missing official source identity, duplicate IDs, unsupported family
version, wrong descriptor, native failure or residual rejection produces explicit
failure without a completed new manifest. Native code remains trusted.

## Verification and Change Impact

The baseline analytic solve/failure/invalid-candidate checks remain valid for the
unchanged oracle. Parent checks add cross-family identity joins and complete
new-family candidate revalidation. Child witnesses must include polarity,
reverse/body-bias behavior, free loaded drain/internal nodes and thermal balance
where supported by that exact official source. Changes to a child artifact/request
require a fresh parent capture, not mutation of a consumed receipt. Integration
tests own actual API/CLI comparison and do not substitute positive S2 point data.

### Retained partial native evidence

The first parent capture retained the original fifteen BULK/analytic/failure cases
and added eight CMG112.1.0 and ten IMG103.1.0 cases. All eighteen added cases solved
and passed complete-candidate physical re-evaluation through the unchanged C image;
the additional capture took 0.245 seconds. The published family matrix explicitly
leaves SOI missing and `qualificationComplete` false. Wrong model version, wrong
artifact hash and duplicate circuit identity each failed admission before any new
manifest publication. This evidence does not assert production API/CLI agreement.

### Retained resolved four-family evidence

A fresh capture following the SOI version decision retained the fifteen baseline
cases and solved/revalidated eight CMG, ten IMG and ten SOI cases through the same
unchanged independent C executable. The resulting forty-three cases contain
forty-one converged results and the two original expected failures. The additional
capture took 0.394 seconds, and its explicit family matrix is complete for BULK
107.2.1, CMG112.1.0, IMG103.1.0 and SOI4.7.0. All source/compiler/profile/artifact,
fragment/request and executable/tool snapshot identities were rechecked. A
fragment retaining the mismatched SOI100.1.1 label was explicitly rejected.
Prior captures remain unchanged; API/CLI agreement is still the integration owner.

### Retained S4 dynamic evidence

`dynamic.py capture` consumes `--dc-manifest`, the explicitly selected two-slot
`--protocol-source`, and one fresh `--output` directory. `dynamic.py validate`
consumes `--manifest`, `--case-id`, a complete `--candidate` JSON result and one
fresh output directory. The manifest records the complete command prefixes.
Analysis manifest/result JSON reads are bounded at eight MiB; request/fragment
JSON remains bounded at one MiB. The historical flattened C candidate and driver
are bounded at one MiB and 256 steps respectively; exceeding either fails explicitly.

The historical frozen fifty-case capture under the prior noise contract contains forty-six successful AC/noise/transient
cases and four expected reverse-polarity negative-source-PSD failures. Every
original real circuit remains present; each family also has a separately named
valid p-forward noise control using the same model image. Raw signed densities are retained verbatim with source index, name and frequency.
The fixed-bias contract migration below supersedes those four expected failures.

The final capture completed in 2.658 seconds. Eleven analytic checks cover complex
RC, voltage/current input PSD units, AC versus noise context, evaluated nonlinear
Q, non-ground UIC, mixed flow/thermal coordinates and actual generated retained
state under a rejected trial. `verify_dynamic.py` revalidated all forty-six
successful complete candidates, rejected corrupted complex/trajectory/PSD values,
and replayed an actual variable-step mixed BE/TR audit. Independent h/h2/h4 runs
passed for twelve real and two analytic trajectories; the analytic controls also
converged toward their closed-form ODE reference. These observations establish
only the recorded profiles. Production API/CLI agreement remains the integration
owner's evidence.

### Source-representable frequency profile

`source_sweep.py` derives one immutable analysis manifest from an explicitly
hash-admitted completed capture. It replaces only AC/noise frequency requests with
the seven points of the SPICE `dec 1 1k 1G` profile, then obtains fresh complete
references from the same admitted independent executable. A noise integral belongs
to that one full-frequency evaluation; separate single-point results are never
combined into a production result. The four negative-PSD failures remain failures.
Model images, circuits, parameters, compiler identities and transient inputs and
references remain byte-equivalent as JSON values. `derivedFrom` records the exact
parent manifest, frequency delta and unchanged transient accuracy receipt. The
original three-frequency evidence remains immutable. Candidate-only verification
rechecks the new complete references without repeating the unchanged h/h2/h4 proof.

The derived fifty-case capture regenerated all thirty-four AC/noise references at
seven frequencies in 0.279 seconds with the unchanged executable and images.
Sixteen transient inputs/references remain unchanged. Candidate-only verification
passed fifty checks, preserving forty-six successful cases and four expected
negative-PSD failures. The existing fourteen-trajectory h/h2/h4 receipt is bound
through `derivedFrom`; no time-accuracy run was repeated for the frequency change.

### Validation output resource profile

Capture/build retains its two-GiB free-disk admission. The default existing-image
validation profile preflights a separate 32-MiB output reserve on the destination
filesystem. Its complete write budget is two flattened candidate files of at most
one MiB each, two child logs of at most four MiB each, and one receipt of at most
eight MiB: eighteen MiB total, with fourteen MiB left for filesystem overhead and
concurrent availability variation. Input manifests/results are existing bounded
reads; validation performs no build or model materialization. The profile and
observed free bytes are recorded in validation receipts. Candidate writes enforce
their limits before exceeding them, and receipts publish atomically. Resource or
I/O errors remain explicit failures; partial logs/candidate files never constitute
a successful validation receipt. This admission change does not change equations,
numeric tolerances, admitted images or captured reference values.

### Explicit transient endpoint selection

The optional `--transient-stop-policy last-pwl-knot` qualification profile derives
a new manifest from the seven-frequency parent. For real-family transient cases
only, it selects the existing final PWL knot as the stop, updates the last step's
time and computes its h from the preceding accepted time. Every other step, PWL
knot, circuit, image, parameter and numeric policy remains unchanged. This is an
explicit fixture input selection, never runtime event coalescing. The prior
one-ulp adjacent endpoint remains preserved as a precision-failure witness.

Each changed case gets a fresh independent reference; its time-accuracy evidence
must be refreshed. Parent manifest/derivation chains and prior accuracy receipts
remain hash-bound historical inputs. All historical source snapshots remain
immutable and verified; the newest derivation/validator snapshots bind the active
tools, while historical working-file correspondence is metadata. This permits an explicitly recorded tool
revision without claiming its historical working-tree path still has old bytes.

The endpoint-qualified capture regenerated twelve real references in 0.132
seconds; all thirty-four AC/noise and four analytic references remain unchanged.
Fifty candidate/failure/audit checks and fourteen h/h2/h4 trajectories passed.
After the original verification reached its final historical-path correspondence
assertion, a hash-recorded finalizer checked immutable snapshots and the newest
tool snapshots, rechecked saved command receipts and recomputed accuracy metrics
from completed outputs. It did not rerun native children or rewrite old evidence.

### Capacity-qualified candidate verifier

`verifier_capacity.py` builds a new exact C verifier for the explicit Native
1000-step profile. It retains historical references and their `oracle`, adding
`validationOracle` and `validationProfile` records rather than relabeling the old
binary. Historical source snapshots remain immutable. New source/header/compiler
and executable receipts, measured static layout/stack usage, exact source-delta
proof, selected old-domain agreement and large-boundary witnesses own this change.
Model compilation and unchanged reference/accuracy captures are not repeated.
The new validation profile bounds two candidate files at eight MiB each, two child
logs at four MiB each and the receipt at eight MiB, for at most 32 MiB of file
contents. Its 64-MiB reserve is an operating policy, not a measured allocation.

The capacity qualification passed thirteen checks: nine exactly equal old-domain
results, a 1000-step solve/replay, explicit 1001-step rejection, corrupted large
candidate rejection and the actual Native BULK trajectory with 676 accepted steps,
677 complete points and nine coordinates. Measured static candidate/step storage
is 2,202,176 bytes. The largest compiler-reported function frame is 132,144 bytes;
the enlarged history arrays remain static. The largest exercised argv contains
4073 arguments and 62,237 encoded bytes, below the unchanged 8192/one-MiB bounds.

### S4D precision replay composition

The [independent compensated replay design](../OSDIDCVerification/DESIGN.md#s4d-independent-compensated-replay-design)
owns higher-precision arithmetic, endpoint/history reconstruction, strict circuit
gates and source-derived adversaries. This capture owner will bind the new
precision compiler/image/program/setup/tool identities and the actual Native
bit-preserving trajectory projection without rewriting the ordinary references.
Runtime's immutable cold `OSDIPrecisionProgram` exposes program/setup byte
snapshots; the reference independently checks their typed original inputs and
prepared topology. No production worker result or rounded native Q becomes the
reference. The independent child now implements and verifies raw precision point evaluation
and the pure circuit-assembly/history core. Complete Native trajectory decoding
and physical replay remain gated by the durable CLI paired-trajectory record;
point containment does not establish a complete accepted trajectory.

## Precision Consumer Manifest

`precision_manifest.py` owns the test-only `corespice.osdi.precision-manifest.v1`
consumer input. It binds the final compiler images/program inspection receipts,
qualified worker/numeric profile and actual public CLI option profile without
recompiling models or rerunning numerical captures. Its consumers are the shared
`OSDIPrecisionManifest` test DTO and Native/API/CLI qualification tests. The
independent evaluator and its proof remain owned by
[Independent Precision Replay](../OSDIDCVerification/Precision/DESIGN.md).

| Field | Authority |
|---|---|
| `worker {path,sha256,byteCount}` | Final worker receipt and exact executable bytes |
| `semanticProfileSHA256`, `numericProfileSHA256` | Final compiler inspection and numeric-profile receipts |
| `precisionBits`, `options` | All ten explicit options from the successful final public CLI request |
| `models [{id,path,sha256,byteCount,descriptorIndex,descriptorName}]` | Exact final images and descriptor/program inspection records; IDs `bsim/cmg/img/soi/compound/context` |
| `provenance`, `independentPointProof` | Immutable source/compiler/worker/public and independent receipts; no full-trajectory claim |

The generator creates one fresh directory, snapshots its own source and each
small authority receipt, checks exact image/program/source hashes, and writes the
manifest with exclusive creation. Model images and historical captures remain
unchanged. The selected operating profile is the already executed 64-MiB arena,
16-MiB program/map and 256-bit public CLI profile; these values are explicit
consumer choices, not new host defaults. Identity mismatch, missing receipt or
unsupported descriptor refuses publication. No stateful precision image is
admitted by the stateless version-one profile.

A derived consumer manifest may replace only the context fixture from an explicit
analysis-bridge compiler receipt. It preserves its parent manifest unchanged and
records `derivedFrom` plus the replacement authority. Each model retains its own
actual compile command/compiler identity; the newer context compiler is not
attributed to the existing four model images or compound fixture. The bridge
receipt's zero-analysis-input proof and exact retained program hashes authorize
reusing the four model point evidence. No numerical recapture follows from this
context-only compiler correction.

### Fixed-bias finite signed-noise migration

`dynamic.py migrate-fixed-bias-noise` consumes an explicit completed fifty-case
`--manifest` and fresh `--output`. It admits the exact four reverse-polarity
`invalidSourcePSD`/`expectedFailure` cases, checks that their recorded raw values
are finite and negative, and recaptures each with the independent C executable.
Successful capture requires finite `rawSignedDensity`, `density = abs(raw)` and
nonnegative source/output PSD; nonfinite values still fail. No generic failure is
promoted to success. The operation preserves every original case input, every
unaffected reference, library identity and validation capacity profile. It updates
only the four captured references/outcomes and command bindings needed to use the
fresh immutable manifest. The migration receipt owns old/new counts, exact parent,
source snapshots, compiler/executable and each bounded command. The old capture
remains immutable; ordinary integration now expects thirty-eight completed
AC/noise/analytic schedules and twelve separately owned precision trajectories.
