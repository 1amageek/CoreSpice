# CoreSpiceParser

## Purpose and Scope

This module owns parser protocols, registry dispatch and resolved source documents.
Parent: [CoreSpice](../../DESIGN.md). There are no child design units.

## Responsibilities and Boundaries

A FileResolver returns the selected path and its consumed text in one document.
Filesystem capture lifetime, limits and content hashing belong to [IO](../CoreSpiceIO/DESIGN.md#consumed-source-capture-required-migration).
Uncaptured convenience parsing retains an explicitly absent capture identity.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | Package composition | Parser boundary | No qualification from syntax |
| [ParsedIR](../CoreSpiceParsedIR/DESIGN.md) | depends on | Parsed values and declaration origin | Parser output | No filesystem state |
| [ParserSPICE](../CoreSpiceParserSPICE/DESIGN.md) | used by | Resolved source document | Include/library input | No second path lookup |
| [IO](../CoreSpiceIO/DESIGN.md) | used by | Captured source admission | Production loading | Capture policy is owned by IO |

## Architecture

```mermaid
flowchart LR
  Resolver[FileResolver] --> Document[Text plus chosen path and optional capture identity]
  Document --> Parser[NetlistParser]
  Parser --> Parsed[ParsedNetlist]
```

## Contracts and Invariants

FileResolver include, library and root reads return SPICESourceDocument.
The document's path comes from the same selection as its text. Library projection
blanks nonselected lines and preserves physical newline positions and selected
columns. Its capture identity names the full source, not a fabricated section file.
NetlistParser accepts documents as a protocol requirement; String convenience
entry points create uncaptured documents. Missing identity never invents provenance.
An explicit unknown format fails; content detection is used only when no format
was selected. File dispatch preserves the resolver's document and chosen path.

## State, Ownership, and Lifecycle

Documents are immutable Sendable values. Registry state retains its common Mutex.
The production capture registry is owned by IO, not parser dispatch.

## Failure, Concurrency, and Constraints

Missing files/sections and invalid projections fail explicitly. This module does
not turn missing capture identity into a successful model receipt.

## Verification and Change Impact

[Loader tests](../../Tests/CoreSpiceIOTests/SPICEDeckLoaderTests.swift) verify actual
selected library locations and source identity. Parser tests verify custom document
resolvers; registry file dispatch must preserve the returned document.
[Registry document tests](../../Tests/CoreSpiceParserSPICETests/ParserRegistryDocumentTests.swift)
verify selected-document origin and explicit unsupported-format refusal.

### Cooperative library projection

`SPICESourceDocument.selectingLibrarySection` accepts the CoreSpice-owned
`SPICESourceWorkAccounting` requirements. Exact IO supplies the same invocation
work accountant used by the grammar; projected-byte counts precede reserve
and cancellation is checked every 256 characters and at line boundaries. These
counts do not reserve retained/temporary capacity or trim/split/normalization
scratch; bounded storage requires the designed contract below.
Ordinary callers retain the existing optional-accounting behavior. Physical
newline positions and the full-file capture identity survive selection. Native
[exact IO tests](../../Tests/CoreSpiceIOTests/SPICEExactSourceIntakeTests.swift)
verify selected original declaration lines and finite budget/cancellation failure.


### Bounded contextual source contract

Status: designed, not implemented. Parser owns this source/context boundary;
[ParsedIR](../CoreSpiceParsedIR/DESIGN.md#bounded-source-storage-and-occurrence-values)
owns storage and occurrence vocabulary. Standalone FileResolver remains available;
required bounded parsing cannot silently inject it.

Proposed requirement:
`SPICEContextualFileResolver.resolve(_ request: SPICESourceDependencyRequest)
async throws -> SPICESourceDocument`. Grammar creates the immutable request before
acquisition await. Fields are parent source key/occurrence, original physical UTF-8
statement offset/source-local ordinal, include/external-lib kind, literal route,
parent section, requested child section and checked child-entry environment.
Returned document carries its actual fresh occurrence, full-source binding and
actual section. Include parses full child with nil section; external lib uses its
requested section. Never substitute parent section for nil child section.
Diagnostic paths grant no access. A refused request performs no child acquisition.

A document retains owned text/projection and full-source owners with copies.
One content owner can back multiple occurrences/sections. Existing section grammar
preserves original physical line/column and an accounted original-byte-offset map:
projected byte offsets must not replace physical offsets after blanking. Reserve
transform/location-map logical extent before allocation. Borrowed views stay
within owner lifetime. Missing/wrong occurrence, section mismatch and resolver
failure cannot produce partial successful input.

### Child-entry environment identity

Status: designed, not implemented. Proposed `SPICEPreprocessingEnvironment` is an
immutable checked value holding sorted parameter entries and a derived identity.
Only checked factories derive identity from actual inputs; no initializer accepts
a detached identity string. Empty-root construction takes actual inspection-policy
identity/configuration; first native PDK adapter permits only that empty input.
Standalone construction can admit explicit initial parameters. Case-colliding
initial or inherited keys fail rather than depending on Dictionary traversal order.

This is entry to a fresh child preprocessor, not parent's local branch scope.
[ParserSPICE](../CoreSpiceParserSPICE/DESIGN.md#bounded-profile-grammar) owns existing
inheritance. It builds one snapshot before request publication and passes the same
snapshot into child construction. Expression text is exactly that used by existing
child evaluation, without new expression normalization/evaluation semantics.

Fingerprint feed uses existing SHA-256 digest sessions in bounded chunks, not a
new document/expression codec. Feed fields: framed UTF-8 domain
`CoreSpice.Preprocessing.Entry`, UInt64 version 1, framed actual inspection-policy
identity, framed fixed conditional-semantics identity, actual case-insensitive flag
(0/1 byte), UInt64 parameter count, then lowercase-name/expression-text pairs in
UTF-8 byte order, then UInt64 zero function-entry count. Integers are big endian;
strings are UInt64 UTF-8 length then bytes. Result is `sha256:` plus lowercase hex.
Sorting, copies and hash bytes are accounted. Semantics identity commits existing
whole-document preprocessing and parameter-only child inheritance; semantic changes
require another identity. Sections/corners/source bindings stay separate context
fields. Host paths and resource ceilings do not change environment identity.

The Core-owned factory implements that feed at the Parser host boundary using
CircuiteFoundationCrypto; ParsedIR stays independent of Crypto/PDK. Actual child
functions start empty; parent functions are parent branch evidence, not silently
inherited. Guarantee only bounded operations supported by the fixed backend:
unavailable cooperative Unicode normalization returns typed capability refusal,
while ordinary parser behavior remains unchanged. Acquisition is already async;
no sync/async bridge, detached tasks or filesystem fallback is needed.

Verification owner: focused bounded-source/environment tests in
[ParserSPICETests](../../Tests/CoreSpiceParserSPICETests/) and
[IOTests](../../Tests/CoreSpiceIOTests/). Prove pre-await refusal, child nil section,
immutable snapshot passed to child, insertion-order-independent fingerprints,
changed-input identity, case collision refusal and physical CRLF/continuation
mapping. Unsupported Unicode returns the specified typed failure before an
unbounded normalization; existing work tests do not prove capacity ownership.
