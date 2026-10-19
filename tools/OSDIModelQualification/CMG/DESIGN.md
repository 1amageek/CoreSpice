# BSIM-CMG DC Model Qualification

## Purpose and Scope

Own acquisition and native generation of the unchanged official BSIM-CMG
112.1.0 standard release (2026-04-28), plus representative DC input fragments.
Parent: [Model qualification](../DESIGN.md). No children.

## Responsibilities and Boundaries

The official equations remain the model owner's responsibility. This tool pins
archive, source/include, license, compiler and generated image identities.
[Independent DC verification](../../OSDIDCVerification/DESIGN.md) owns circuit
solving and complete physical residual validation. Production CoreSpice tests own
agreement with that independent result; compilation alone is not qualification.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Model qualification](../DESIGN.md) | parent | Explicit family evidence | Four-family integration | No support inference from enum cases |
| [DC oracle](../../OSDIDCVerification/DESIGN.md) | depends on | DC input/result schemas | Independent equations | Strict absolute A/V/W residual tolerances |
| [swift-osdi](../../../../swift-osdi/DESIGN.md) | verification target | OSDI 0.4 metadata and evaluation | Native consumer | No model physics certification |

## Architecture

```text
Official standard page -> exact release archive -> hash-checked unchanged source
  -> pinned full-residuals compiler -> signed native OSDI image + provenance
  -> explicit DC cases -> direct ABI oracle -> CoreSpice comparison
```

## Contracts and Invariants

The official module is `bsimcmg_va(d,g,s,e,t)`: four electrical terminals and
one thermal terminal. Four connected terminals leave `t` as a private K/W
coordinate. `type=1/-1` selects n/p; `rdsmod=1` externalizes source/drain
resistance; `shmod=1` activates the source's power/thermal conductance equation.
Ambient Kelvin and thermal rise are separate. Source `bsimcmg_body.include`
supplies the full DC current and self-heating equations without modification.
All source/includes, LICENSE and NOTICE remain intact in ignored evidence.

## Runtime Flows

Bounded HTTPS acquisition -> archive SHA check -> bounded safe regular-file
extraction -> exact compiler SHA admission -> timed native compilation with
`--full-residuals` -> code signature verification -> artifact receipt. Every
output directory is new; failures preserve diagnostics without a success receipt.

## Failure, Concurrency, and Constraints

No compiler installation or Rust/Swift build is performed. Compiler target is
`aarch64-apple-darwin`, optimization level 1. Every child has a 30-second wall and
CPU limit with process-group cleanup and a 4 MiB output bound. Download and
extraction are bounded to 64 MiB archive and 128 MiB unpacked files. The selected
compiler is SHA-256 `386a0f9b52e083c3f15f3642ef76937def3258c16e8f270fa797a853941f913c`.

## Verification and Change Impact

The DC fragment freezes strict absolute equation tolerances at A=1e-12,
V=1e-10, W=1e-12. Cases cover n/p, forward/reverse drain polarity, 300.15/350.15 K
ambient, loaded free drain, retained series nodes and free thermal balance.
Every coordinate and voltage-source current must independently revalidate.
No AC, transient, noise, interval or foundry qualification is implied.
Changes to source/compiler/request hashes invalidate the corresponding capture.

Run `python3 tools/OSDIModelQualification/CMG/qualify.py` from the package root
with explicit `--compiler`, `--compiler-profile-receipt`, `--header`,
`--point-oracle` and fresh `--output` paths. The point observer is the unchanged
existing direct-ABI S2 executable. The resulting `fragment.json` is consumed by
the parent's common capture command; no second C oracle is introduced here.

The retained native preparation at
`.verification/osdi-models/cmg/prepared-2/fragment.json` records an actual
2.311-second compilation and image SHA-256
`8bde13c0f795ff72c820047549cbe643f4804700e2eae362fdc78f956cd66528`.
Direct ABI observation found 17 raw nodes, five descriptor terminals, zero
history states, lowercase scoped parameters and K/W thermal metadata. Those
observations qualify preparation only; circuit captures and production agreement
remain distinct required evidence.

The common same-artifact capture at
`.verification/s3-dc-families-1/manifest.json` subsequently solved all eight CMG
cases and revalidated every complete returned candidate with the independent
direct-ABI evaluator. Its CMG artifact has the exact SHA above. The largest
normalized physical residual was below `1.4e-7` under the frozen policy.
The retained `rdsmod=1, shmod=1` cases solved private drain/source coordinates
and thermal rises of 2.4990505707728 K (n) and 2.977459539288491 K (p).
This establishes the independent reference path; production CoreSpice agreement
is owned by the consuming integration tests.
