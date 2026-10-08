# CoreSpiceParserSPICE

## Purpose and Scope

This SwiftPM module owns the SPICE frontend. Parent: [CoreSpice](../../DESIGN.md). This module has no newly introduced child components.

## Responsibilities and Boundaries

The lexer preserves dotted version literals; parser retains an exact model version string and MOS IC vector coordinates. Numerical model admission remains downstream.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | Package composition | Owned module boundary | Revalidate direct consumers when contracts change |

## Architecture

```mermaid
flowchart LR
    Input[Typed inputs] --> Owner[CoreSpiceParserSPICE]
    Owner --> Output[Validated outputs or typed failure]
```

## Contracts and Invariants

Continuation lines beginning with a plus after optional whitespace extend the last non-comment logical statement across full-line comments and blank lines. Tokenization folds intervening separators/comments only when a continuation is present; ordinary next statements remain separated and standalone comments remain available. Leading whitespace does not change full-line star-comment semantics. Retained tokens keep their physical source locations, including line and column. This grammar follows the original [ngspice 46 continuation stitcher](https://github.com/imr/ngspice/blob/ngspice-46/src/frontend/inpcom.c#L634-L710) and addresses the comment-interrupted continuations in unchanged Sky130 model cards; model evaluation/version support remains downstream. An unquoted dotted version is not rounded through Double. Numeric contexts reject version literals. MOS OFF is a flag, and IC accepts one to three DS/GS/BS values, defaulting omitted coordinates to zero.

## Subcircuit Header Defaults

The parser owns the SPICE header boundary: ports end at the first identifier followed
by `=`, or at an optional `PARAMS`/`PARAMS:` marker. Both marked and unmarked
headers produce the same `ParsedSubcircuit.parameters` values. The definition
retains numeric, signed, reference and brace-expression defaults; header names
never become ports or body components. All remaining header fields must be named
assignments with values. Missing values/assignment delimiters and malformed values
produce physical-location parser diagnostics instead of dropping fields.

The existing conditional preprocessor consumes the same admitted header defaults,
including logical continuation lines, in the definition's local parameter scope.
It retains its existing parse-time conditional semantics; this change does not
introduce per-instance conditional re-elaboration. Header values and body `.param`
state remain local and do not escape the matching `.ends` boundary. Lowering
remains the owner of instance-over-default precedence and numerical dependency
resolution under its [module contract](../CoreSpiceLowering/DESIGN.md).

```mermaid
flowchart LR
    Header[Ports and optional marker plus named defaults] --> Parser[ParsedSubcircuit]
    Header --> Conditional[Local parse-time conditional scope]
    Parser --> Lowering[Instance overrides then dependency resolution]
    Lowering --> Body[Scoped body expressions and flat IR]
```

The unmarked header in the immutable installed Sky130
`sky130_fd_pr__nfet_g5v0d16v0__subcircuit.pm3.spice:16` is a concrete admission
counterexample; the identical library/deck executed under ngspice. Grammar authority
is the [ngspice parameter manual](https://nmg.gitlab.io/ngspice-manual/circuitdescription/paramparametricnetlists/subcircuitparameters.html).
Its historical default-value warning does not override CoreSpice's verified
instance/default resolver or the current executable oracle; only the unmarked
header grammar is used here.

## State, Ownership, and Lifecycle

Lexer and parser state is local to a parse. Parsed results are owned Sendable values.

## Failure, Concurrency, and Constraints

Malformed version/numeric contexts and invalid IC arity are parser diagnostics; unknown exact versions remain available for typed model admission failure.

## Verification and Change Impact

Public behavioral tests verify marked/unmarked headers, numeric ports, continuation defaults, local conditional scope, malformed-field diagnostics and actual lowering/default override results. Integration tests use the actual parser for quoted/unquoted version, IC and OFF, invalid version, and malformed numeric input. [Parser tests](../../Tests/CoreSpiceParserSPICETests/) verify comment-interrupted continuations through parsed model/parameter values, ordinary statement separation and physical diagnostic locations. Revalidate Lowering when token semantics change; replay unchanged real PDK library inputs through the native CLI to distinguish parser admission from later numerical model support.

## Canonical PWL Source Migration

Parsed numeric vectors preserve alternating PWL time/value values. SPICE PWL syntax
parses and serializes this vector, lowering retains `ParameterValue.realVector`,
and device admission owns strict time/value validation. Partial/unknown source
waveforms produce typed parse/binding failure, never successful DC substitution.
Scalar option/measurement/expression consumers reject vectors explicitly.
