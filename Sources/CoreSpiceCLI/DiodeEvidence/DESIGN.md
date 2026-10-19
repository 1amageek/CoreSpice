# Completed Diode Evidence

## Purpose and Scope

Parent: [CLI](../DESIGN.md). No children. Owns host Codable projection of actual prepared diode owners.

## Responsibilities and Boundaries

Owns the inspection projection and host artifact emission of actual consumed diode inputs. Numerical preparation and source selection remain domain-owned.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CLI](../DESIGN.md) | parent | Actual completed phase and atomic publication | Host composition | Completion precedes emission |
| [Native](../../CoreSpice/NativeExecution/DESIGN.md) | depends on | Actual execution facts | Exact owner evidence | Prepared-only is not completed |
| [ToolQualification](../../../../ToolQualification/DESIGN.md) | used by | Original canonical schemas | Independent trust decision | Never issue qualification |

## Architecture

```text
completed domain facts -> host projection -> canonical artifacts -> atomic publication
```

## Contracts and Invariants

Exact role-separated model/instance values, frozen environment, source occurrence, profile/law/implementation and capability/budget facts. Projection cannot construct executable authority; records are collected only from completed native phases. Source-free coordinates stay absent, and canonical case model receipts require a checked compiled declaration/captured source. Unsupported inputs emit no completed record.

## State, Ownership, and Lifecycle

Immutable projection values; per-invocation phase collector owns synchronized history.
Publication owns staging files and removes partial output on failure/cancellation.
No device state or executable owner is reconstructed by decoding a receipt.

## Failure, Concurrency, and Constraints

Missing identity/meaning and byte/capacity violations fail explicitly. Existing
collector Mutex and publication owner keep the same isolation and cleanup contract.
No callbacks or I/O run under the collector lock.

## Verification and Change Impact

DiodeCLIAdmissionTests and affected case-output tests execute real adapters, decode
canonical artifacts and verify exact links; built CLI fixtures check success and
no-publication failures. Recheck native assumptions when preparation schema changes.
