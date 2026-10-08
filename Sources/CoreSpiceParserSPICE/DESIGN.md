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

## Quoted Values and Source Diagnostics

### Confirmed Path and Owned Difference

The native replay of the untouched Sky130 TT library at CoreSpice `6a7e7a7`
fails at `corners/tt/nonfet.spice:4:13`: `cnwvc_tox='41.6503*1.024'`.
The existing lexer collapses both delimiters into a string token. The standalone
expression parser rejects that token, while generic parameter intake retains it
as opaque text. The serializer also emits opaque values with single quotes.
These three paths lose the distinction required by the
[ngspice numeric parameter specification](https://nmg.gitlab.io/ngspice-manual/circuitdescription/paramparametricnetlists/paramline.html).
The frontend owns this repair; ParsedIR already distinguishes expression and
string values, and Lowering consumes those contracts without another parser.

### Contract

- Tokens preserve single-quoted expression versus double-quoted opaque text.
- Numeric expression positions parse the complete single-quoted interior with
  the existing expression grammar, including references and function calls.
  Numeric `.param` positions reject opaque double-quoted text explicitly.
- Generic component, model, subcircuit-default and actual values map
  single-quoted numeric input to `ParsedParameterValue.expression`; they retain
  double-quoted text as `.string`. Conditional preprocessing uses the same
  expression parser through its existing dependency/function evaluator.
- Model `version` and include/library/HDL paths are explicit text roles. Either
  delimiter preserves their exact value; no arithmetic, suffix conversion or
  version normalization selects another model or path. Existing native model
  admission remains authoritative after parsing.
- The structural model `level` consumes a numeric value or a quoted literal,
  validated by exact integer conversion. A supplied nonliteral expression,
  opaque text, fractional or out-of-range value fails explicitly rather than
  silently retaining the default level. This structural role is distinct from
  model parameter expressions evaluated downstream.
- Unknown characters remain visible tokens so complete numeric expression
  parsing rejects quoted trailing invalid characters. The common lexical gate
  rejects unterminated quotes; raw control policy is not expanded by this repair.
- Opaque value serialization uses double quotes and reversible escaping for
  delimiters/backslashes. Expression serialization may retain the existing
  brace representation. Parse/serialize/parse preserves the IR meaning.
- Unterminated quotes, empty numeric interiors, malformed operators and
  unconsumed interior tokens yield `ParserDiagnostic` failures. Diagnostics
  inside quoted expressions retain the original physical file/line/column,
  including continued lines and CRLF. Unclosed text cannot become a success
  value through a partial lexer token or an empty path.
- Bare positional numeric values use the same quoted-expression intake as
  named values. A quoted token cannot be discarded when a positional slot is
  missing; opaque text in a numeric positional slot fails explicitly.
- The existing first-line title is free text, outside quoted-value syntax.
  Common unterminated-quote validation begins after that title is consumed;
  all remaining statements retain the lexical failure gate.
- Each parse owns its token/state lifetime. No new shared state, model backend,
  process policy, unit conversion or geometry bin selection is introduced.

```mermaid
flowchart LR
    Source[Physical quoted source] --> Lexer[Delimiter-preserving token]
    Lexer --> Numeric[Numeric role: shared expression parser]
    Lexer --> Text[Exact text role: path or model version]
    Numeric --> IR[Expression or string ParsedIR]
    Text --> IR
    IR --> Serialize[Semantic-preserving serializer]
    Serialize --> Source
```

| Requirement | Implementing owner | Behavioral proof |
|---|---|---|
| Numeric quotes and lexical distinction | Lexer, token and expression parser | Quoted AST, full-input rejection, physical errors |
| Canonical intake across actual consumers | SPICE parser and existing conditional evaluator | `.param`, `.model`, header/actual, `.if`, public parse/lower |
| Exact text and persistence | Text-role parser and serializer | Both path delimiters, exact unsupported version, opaque escaping round trip |
| Production admission | Native CLI with unchanged PDK/deck | Next actual failure or result; no model physics qualification inferred |

The package master indexes this child contract. Revalidate the parser target and
public IO consumer tests once after the implementation/test snapshot is frozen.
Lowering/model source remains unchanged; existing exact-version tests are direct
consumer checks rather than proof of new device support.

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
