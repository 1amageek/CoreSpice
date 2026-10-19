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

This source publication provides the dependency baseline needed by bounded
`CoreSpiceIO` profile consumers. It preserves the implementation and thirteen
products from `bb754369fd2e4796eb4ac44ba07856565529a797`, with only publication
scope and current dependency-inventory documentation changes, on the public
`eee5576fddf54cdbad887063668a205dd02b3ebd` parent. See the
[prerequisite contract](DESIGN.md#finite-prerequisite-source-publication).
It does not certify the remaining complete-release gates, validated circuit
flow, or all-phase/all-history guarantees. The retired `CoreSpiceCompactModels`
product remains removed; migration to the OSDI boundary is explicit.

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
