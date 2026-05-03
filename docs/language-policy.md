# Language policy

> Workspace-level policy on language choice for new code. Applies to every feature in this workspace. Individual feature designs may cite this document but should not contradict it.

## Policy

1. **New standalone services are written in Go.**
   "Standalone service" means a process with its own deployable artifact (container, binary), reachable only over a network protocol (HTTP, gRPC, queue). It is not in-process with anything else the platform owns.
2. **Existing components stay in their current language.**
   Today the orchestrator core, the runner wrapper, and the executor are TypeScript. They remain TypeScript. We do not rewrite working code to follow a language preference.
3. **In-process additions to existing components stay in the host language.**
   A new TypeScript module added inside the orchestrator stays TypeScript. A new Go package added inside a Go service stays Go. Cross-language in-process interop (FFI, cgo, embedded JS engines, etc.) is **not allowed** without an explicit, documented exception.

## Why

The bar for adding a language to the workspace is high — it adds toolchain, CI, observability tooling, hiring surface, and cognitive cost. The policy passes that bar only where the payoff is concentrated and the boundary is clean:

- **Network boundary, language-neutral protocol.** A standalone service speaks HTTP/JSON or similar — language is a private implementation detail. Replacing or rewriting one service does not affect any other. This is the only safe place to mix languages.
- **Concentrated workload fit.** Standalone services are often concurrency-heavy infrastructure components (work queues, schedulers, gateways). Go's goroutines + channels, single-binary deployment, and predictable memory profile genuinely earn their keep there. The TypeScript orchestrator's I/O-heavy workflow logic is well-served by Node's event loop and shares ecosystem with the executor — no reason to move.
- **Avoid in-process interop.** Mixing languages inside one process (FFI, cgo, embedded engines) is where polyglot codebases break down: build complexity explodes, debugging gets opaque, and refactors become cross-language. The "network boundary only" rule is what makes this policy survivable.

## Consequences

- **CI and release pipelines must support both languages** the moment the first Go service ships. Plan for it (Go toolchain in CI image, separate `go test` and `tsc --noEmit` lanes, separate image builds).
- **Cross-language contracts are pinned as data, not code.** When two implementations of the same protocol exist in different languages (e.g. TypeScript reference + Go production of the same service), the contract lives as JSON fixtures or schemas (OpenAPI, Protobuf) checked into the repo — not as types shared between the two implementations. Both sides conform via fixture replay or schema validation.
- **Skill ownership is per-service.** A Go service is owned by people fluent in Go. A TypeScript service likewise. No single contributor is forced to be polyglot just to make a small change.
- **Tooling parity matters.** If a Go service ships, the workspace's observability story (logs, metrics, traces) must work for it on day one. Don't ship a service that's harder to operate than the rest of the system.

## How to apply

- **When proposing a new feature** — if the design introduces a standalone service, the technical design must declare its language in the "Repository impact" or "Chosen design" section. Default is Go unless an explicit reason argues otherwise.
- **When proposing a new module inside an existing component** — language is the host component's language. No design-level decision needed.
- **When in doubt** — ask. The trade-offs (additional language overhead vs. fit) are the kind of thing the team decides together, not the kind of thing an individual contributor chooses unilaterally.

## Current state

| Component                                            | Language    | Notes                                                                    |
|------------------------------------------------------|-------------|--------------------------------------------------------------------------|
| Orchestrator core (`runtime/orchestrator/`)          | TypeScript  | Existing — stays.                                                        |
| Claude executor (`runtime/executors/claude/`)        | TypeScript  | Existing — stays.                                                        |
| Runner wrapper (`runtime/runner-wrapper/`)           | TypeScript  | New in `runtime-portable-architecture` (T4); kept TS for type sharing with orchestrator. |
| In-memory broker (`runtime/orchestrator/broker/`)    | TypeScript  | New in `runtime-portable-architecture` (T3); embedded in orchestrator.   |
| **Redis-backed broker service**                      | **Go**      | New in `runtime-portable-architecture` (T7); workspace's first Go service. |

The Redis-backed broker service is the **beachhead** for this policy. It was chosen because:
- Genuinely standalone — runs in its own container with HTTP + Redis as its only interfaces.
- Workload (peek-and-lock work queue, visibility-timeout reclaim) fits Go's concurrency primitives well.
- Single-binary deployment; small image; cheap to run as a sidecar/service.
- HTTP+JSON contract is language-neutral; no interop pain on either side.

## History

- **2026-05-04** — Policy established. Beachhead at the broker service in feature `runtime-portable-architecture`. Authored by matthew@liquid-labs.xyz.
