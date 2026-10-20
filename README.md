# CoreSpice

CoreSpice is an independently usable SPICE parser, in-process circuit simulator,
waveform library, and bounded external-simulator adapter.

## Responsibility

| CoreSpice owns | CoreSpice does not own |
|---|---|
| SPICE parsing, lowering, circuit IR, and supported device models | DesignDatabase persistence or workspace state |
| DC, AC, transient, noise, transfer, sweep, and Monte Carlo analysis | Flow scheduling, review, or release policy |
| Waveform data, measurements, metric reports, and simulation diagnostics | PDK discovery or tool qualification |
| Bounded external simulator invocation and raw execution evidence | Silent fallback from unsupported compact models |

Native elementary MOS paths provide explicit Level 1/2/3. BSIM compact-model
physics uses swift-osdi; in-tree BSIM kernels, custom Swift physics wrappers and
the former independent BSIM-BULK-swift implementation are retired. The OSDI path connects compiled official BSIM-BULK 107.2.1, BSIM-CMG
112.1.0, BSIM-IMG 103.1.0 and BSIM-SOI 101.0.0 models. Exact model artifacts,
parameters, analysis capabilities and operating conditions are checked; unsupported
configurations fail explicitly. No simpler-model fallback is used.

CoreSpice owns circuit equations, sparse solvers, Newton vector kernels and
generalized Schur pole-zero analysis in Swift. The electrical API and CLI do not
depend on Accelerate/LAPACK algorithms or the optional Metal backend. Compiled
OSDI models and their compiler are external to this Pure Swift simulator boundary.
Pole-zero classification is numerical: unresolved roundoff-scale homogeneous
eigenvalues fail explicitly rather than returning a guessed finite/infinite root.

The toolchain baseline is **Swift 6.4.0 release on macOS 27 or later**. Native
finite-fixture qualification and performance evidence are recorded in the
[design and production gates](DESIGN.md#released-osdi-adoption-and-semiconductor-production-gates).
The complete production release is in progress: all-history enclosure and other
open gates are not certified by ordinary successful simulation traces.

## Source prerequisite scope

This source publication makes the finite conditional prescribed-voltage Flow API
and its retained, borrowed source/model scope available to downstream consumers.
It preserves the committed implementation, tests, resources and all thirteen
products from `39443965441b175f57198a1d98706895f5453280`, on the sole public
parent `cfcadac5aeff5d95681d2d91c0bf3e75bd35f169`. See the
[prerequisite contract](DESIGN.md#finite-prerequisite-source-publication).
The conditional numerical result does not establish common source-family
nonemptiness, an actual Physical candidate/circuit correspondence, or the
remaining all-phase/all-history release gates. External model and precision
worker artifacts are supplied separately under their own terms. This is a source
prerequisite, without a stable-version or complete-production-release claim.

## Public products

| Product | Role |
|---|---|
| `CoreSpice` | Circuit construction and analysis API |
| `CoreSpiceIR` | Circuit and analysis values |
| `CoreSpiceIO` | SPICE and waveform parsing/serialization |
| `CoreSpiceProcessBackend` | Isolated external-simulator boundary |
| `CoreSpiceBackend` | Explicit optional Metal compute product; import it directly when used |
| `PluginsPhotonic` | Optional photonic device models |
| `corespice` | Headless CLI |

## Start here

```bash
swift build
swift run corespice --help
```

## Documentation

- [CLI reference](Sources/CoreSpiceCLI/README.md)
- [Design](DESIGN.md)
- [Requirements](REQUIREMENTS.md)
- [Current work](REMAINING_TASKS.md)

## License

Original CoreSpice code uses [MIT](LICENSE). The directly linked swift-osdi
dependency and the incorporated OSDI verification header use GPL-3.0-only. See
[third-party notices](THIRD_PARTY_NOTICES.md) and the
[distribution boundary](docs/distribution-licensing.md) for combined-distribution
obligations and separately licensed external model artifacts. The translated
generalized Schur algorithms retain their [Reference-LAPACK BSD-style notice](Sources/CoreSpiceAnalysis/GeneralizedSchur/THIRD_PARTY_NOTICES.txt).
