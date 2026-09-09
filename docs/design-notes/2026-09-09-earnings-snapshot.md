# Design note: `EarningsSnapshot` on the tunnel (2026-09-09)

Additive change to `flock/tunnel/v1/tunnel.proto`: one new message
(`EarningsSnapshot`) and one new member of the `CoordinatorMessage` oneof
(`earnings = 8`). No existing field, message or RPC changes;
`buf breaking --against '.git#tag=v0.1.0'` clean. Regenerated with
protoc-gen-go v1.36.12 / protoc-gen-go-grpc v1.6.2 (the CI pins).

## Why

docs#24. The daemon's `/api/v1/earnings` fabricates USD from local engine
stats and the TUI / desktop render it as a dollar figure. Once a node is
enrolled the number an operator screenshots must be the ledger's
(plan 12 §2). The real figures exist only behind the gateway's
service-to-service console API, which a node cannot call: it holds a node
identity (the mTLS tunnel), not an operator session.

## What

The coordinator pushes `EarningsSnapshot` down the existing `Session`
stream — the channel that already authenticates the node and maps it to its
operator — right after `HelloAck`, on a periodic cadence
(`push_interval_seconds`, default 300 s) and a couple of seconds after each
metered request the node served. It carries the operator's settled
(`available_credits`, vested main balance) and pending (`escrow_credits`)
balances, today's / trailing-7-day / lifetime payout credits, the
`credits_per_usd` peg, `as_of`, and `next_vest_at`.

Figures are per operator account, not per node: the ledger has no per-node
balance, and the daemon labels the figure accordingly ("your account").
No customer identity crosses the tunnel (SPEC §2.1): the snapshot carries
balances and timestamps only, not entries, refs or request ids.

## Alternatives rejected

- A node-authenticated gateway endpoint: a second auth path on the public
  gateway for something the tunnel already proves.
- Piggybacking the fields on `HelloAck` / `ConfigUpdate`: those describe
  the session, not the account, and the snapshot has its own cadence.

## Compatibility

flockd 0.5.x / 0.6.0 handle `CoordinatorMessage` with a type switch over
the oneof and no default arm; protobuf-go keeps an unknown oneof member in
the message's unknown fields and `GetMsg()` returns nil, so older daemons
drop the snapshot without error. Verified on the daemon side with a
wire-level test (flockd `internal/tunnel`, unknown field number pushed
through a live session).
