# BSIM-IMG Native DC Qualification

## Purpose and Scope

Child of [model qualification](../DESIGN.md). Own reproducible acquisition and
native DC requests for the unchanged Berkeley BSIM-IMG Standard 103.1.0 source.
This is artifact/consumer qualification, not foundry or all-history qualification.
No children.

## Responsibilities and Boundaries

The official archive owns physics. The pinned external full-residual compiler
owns generated OSDI equations. This directory owns exact acquisition, selected
inputs, source/compiler/artifact receipts, and ordinary DC observations. The
[independent oracle](../../OSDIDCVerification/DESIGN.md) owns circuit equations
and physical residual acceptance; production comparison belongs to its consumer.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Qualification](../DESIGN.md) | parent | Exact model-family admission | Fourth-terminal semantics remain explicit | No physics approximation |
| [DC oracle](../../OSDIDCVerification/DESIGN.md) | depends on | dc-inputs/result v1 and strict physical tolerances | Independent solve/validate | Same exact native image |
| [swift-osdi](../../../../swift-osdi/DESIGN.md) | coordinates with | OSDI 0.4 generated metadata | Native arm64 artifact | No WASM claim |

## Architecture

```text
Berkeley HTTPS archive + pinned SHA -> unchanged source/includes/license/notice
  -> pinned compiler --full-residuals -> native OSDI + metadata point receipt
  -> explicit n/p/front/back/ambient/series/thermal requests
  -> independent C DC solve -> complete-vector residual revalidation
```

## Contracts and Invariants

Official model page: https://www.bsim.berkeley.edu/models/bsimimg/ . The latest
standard listing is 103.1.0 dated 2024-09-11; source banner says released
2024-09-10. Archive URL and SHA-256 are fixed in `qualify.py`; the date difference
is preserved rather than normalized. `LICENSE.txt` declares ECL-2.0 and
`NOTICE.txt` credits Si2 CMC support. Source and all four project includes remain
byte-identical to archive contents; compiler-provided standard Verilog-A headers
are bound through the exact compiler identity.

Actual generated descriptor index 0 is `bsimimg`: external order d, fg, s, bg, t;
raw order continues di, si, ge, gi, n. All electrical unknowns are V/A and t is
K/W. Previous state is empty. With four connected terminals and default SHMOD=0,
t and n collapse to ground; di/si collapse to d/s, ge/gi to fg. `RDSMOD=1`
retains di/si, `RGATEMOD=1` retains ge, and `SHMOD=1` retains private thermal t.
Front and back gates have independent voltage sources. Ambient Kelvin and
thermal rise are distinct values. Requested TYPE/RDSMOD/RGATEMOD/SHMOD are
model integer assignments; L/W are instance real assignments, confirmed through
actual generated parameter access.

The unchanged source emits a compiler warning for `type="both"` on DELHCI.
This compiler treats it as a model parameter. Qualification uses the default
DELHCI=0 and does not claim instance-scoped aging-handle support. No equation,
macro or version is changed to suppress this limitation.

Requests freeze absolute equation limits at 1e-12 A, 1e-10 V, 1e-12 W before
capture. Relative tolerance affects updates only. Every converged complete vector
is re-evaluated without Newton or repair, and every physical normalized residual
must be at most one. Backgate and temperature pair checks require actual
changes in branch drain current; private-node and thermal checks use projection
and units rather than merely counting nodes. Changing inputs or policy requires
a fresh output directory and retained new evidence.

## Runtime Flows

Bounded download -> exact archive check -> safe extraction -> source receipts ->
bounded compile -> direct-ABI metadata -> bounded per-case solve and validate ->
immutable manifest. Every command records argv/status/stdout/stderr hashes.

## State, Ownership, and Lifecycle

Each output directory owns its acquisition, artifact and receipts; existing output
is refused. Each oracle invocation owns separate model/instance native storage.
No production library, persistent session or mutable model cache is introduced.

## Failure, Concurrency, and Constraints

The shared subprocess helper bounds each child to 30 seconds CPU/wall time and
4 MiB per output file with process-group termination. Network acquisition uses
30-second operations and a 16 MiB archive bound; source extraction rejects links,
nonregular files and path escape. Exact identity mismatch, compiler failure,
nonconvergence, missing coordinates and failed behavior checks fail explicitly.
No older version, altered equation, default-value substitution or larger residual
tolerance is selected after a failure.

## Verification and Change Impact

`qualify.py` self-checks archive/source identities, actual descriptor/natures and
parameter assignments, n/p polarity, independent backgate response, ambient
response, retained di/si and thermal balance, and complete-vector revalidation.
The resulting manifest uses the DC capture schema for production adapter tests.
Compiler, source/include, oracle, request or policy changes invalidate affected
capture evidence. AC/transient/noise, aging and external-simulator parity remain
outside this DC scope.

### Retained Native Capture

The fresh `CoreSpice/.verification/osdi-models/img/qualification-2/fragment.json`
capture completed acquisition, compilation and ten solve/validate pairs in
2.225 seconds. Generated artifact SHA-256:
`3b107bef58deb1871686f152f8b740cfa1e35e5b391d1ddde47174ae7f37252f`.

| Observation | Actual result |
|---|---|
| NMOS VD branch current, BG=0 / +0.5 V | -0.726035116 / -0.933765658 mA |
| PMOS VD branch current, BG=0 / -0.5 V | +0.864475729 / +1.075938860 mA |
| NMOS 350.15 K ambient VD current | -0.747876450 mA |
| Retained di / si under 0.5 V drain bias | 0.459545912 / 0.040454088 V |
| Free thermal rise / heat-balance residual | 4.048208196 K / 1.409462824e-18 W |
| 5 kOhm loaded free drain / Newton iterations | 0.038545803 V / 7 |
| Maximum normalized equation residual across all cases | 1.791645e-5 |

The first scripted attempt stopped before acquisition because the Python
installation had no default CA issuer chain. The script now uses the existing
macOS `/etc/ssl/cert.pem` trust bundle with certificate verification enabled.
No environment or system trust configuration was changed.

Reproduce from the workspace root with a fresh output path:

```bash
python3 CoreSpice/tools/OSDIModelQualification/IMG/qualify.py \
  --compiler swift-osdi/.verification/s2-compiler/build-attempt-4-release/products/openvaf-r \
  --compiler-profile-receipt swift-osdi/.verification/s2-full-residuals-capture/compiler-profile-receipt.json \
  --oracle-manifest CoreSpice/.verification/s3-dc-capture-1/manifest.json \
  --point-oracle swift-osdi/.verification/s2-full-residuals-capture/oracle \
  --output CoreSpice/.verification/osdi-models/img/<fresh-capture>
```
