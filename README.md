# teraflock/proto

Protocol contracts for the Teraflock mesh — the single shared dependency between the
open-source node daemon ([flockd](../flockd)) and the private control plane.
Apache-2.0.

## Packages

| Package | Purpose |
|---|---|
| `flock.types.v1` | Shared types: `CapabilityProfile`, `ModelSpec`, `ResourceBudget`, `GenerationParams`, tiers, node states |
| `flock.tunnel.v1` | Node ↔ coordinator: `Enroll` + the persistent bidirectional `Session` stream (heartbeats, dispatch, token streaming, fingerprint challenges, model assignment, drain) |
| `flock.control.v1` | Internal control-plane RPCs: gateway → coordinator routing, fleet/registry queries |

## Design invariants

These are load-bearing for the whole system — see `SPEC.md` §2, §6:

- **Nodes dial out, never listen.** All coordinator→node traffic is pushed down the
  node-initiated `Session` stream. There is no RPC the coordinator initiates to a node.
- **No customer identity crosses the tunnel.** `DispatchRequest.request_id` is a
  per-request ephemeral ID minted by the coordinator; the gateway's metering ID never
  reaches a node.
- **Every dispatch is signed** by the coordinator's Ed25519 key (pinned at enrollment);
  nodes verify before serving.
- **Seeds are always set** so retries are idempotent and greedy canary comparisons are
  exact.

## Toolchain

Managed with [buf](https://buf.build) (`buf.yaml` / `buf.gen.yaml`); `protoc` fallback
for local dev. Generated Go is committed under `gen/go/` so consumers can depend on
this module without running codegen.

```sh
# regenerate (buf if installed, else protoc + protoc-gen-go/protoc-gen-go-grpc)
./gen.sh

# or
just gen
```

Consumers (until this is published to a real module path) use a sibling-checkout
replace directive:

```
require github.com/teraflock/proto v0.0.0
replace github.com/teraflock/proto => ../proto
```

TypeScript types for the console are generated in the control-plane repo's build
(`buf generate --template buf.gen.ts.yaml` — Phase 4).

## Rules of the road

- **No proto change without a design note in the PR.** This repo is the coordination
  point for parallel workstreams (SPEC §A2.1); breaking it breaks everyone.
- `buf breaking` gates CI against the last tag. Additive changes only within a
  `v1` package; incompatible changes mean a `v2` package.
- Semver tags; the daemon reports its proto version indirectly via `daemon_version`
  in heartbeats, and the coordinator enforces `min_supported_version`.

### Tagging

`buf breaking` compares against the **last reachable semver tag**, so the tag
is the gate: CI fails outright when no tag is reachable. `v0.1.0` is the
contract flockd v0.5.0 / control-plane c4aaafb ship against.

- Before opening a PR that touches `flock/`, run it locally:
  `buf breaking --against ".git#tag=$(git describe --tags --abbrev=0)"`.
- Every merged proto change gets a tag: **minor** bump for additive changes
  (`v0.2.0`), **major** for breaking ones — and breaking needs the design
  note plus a `min_daemon_version` plan so old nodes drain politely.
  `git tag -a vX.Y.Z -m "..." && git push origin vX.Y.Z`.
- Codegen is pinned in CI: `protoc-gen-go` follows the
  `google.golang.org/protobuf` version in `go.mod` (bump both together);
  `protoc-gen-go-grpc` is pinned explicitly in `.github/workflows/ci.yml`.
  Regenerate with the same versions before committing `gen/`.
