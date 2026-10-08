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
accountant used by the grammar; full projection storage is charged before reserve
and cancellation is checked every 256 characters and at line boundaries.
Ordinary callers retain the existing optional-accounting behavior. Physical
newline positions and the full-file capture identity survive selection. Native
[exact IO tests](../../Tests/CoreSpiceIOTests/SPICEExactSourceIntakeTests.swift)
verify selected original declaration lines and finite budget/cancellation failure.
