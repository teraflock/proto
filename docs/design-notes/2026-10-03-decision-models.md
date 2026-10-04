# Design note: typed decision models, `/v1/systemone` end to end (additive, 2026-10-03)

Additive only; `buf breaking` against the latest tag is clean. Decided with
Anderson 2026-10-03. This note is the contract for every repo that
implements the feature (epic in teraflock/docs); where a repo's code and
this note disagree, fix one of them in the same PR.

## What this is

Decision models answer bounded, typed questions about a piece of state and
return probabilities instead of text: no tokens are generated. TypeSafe
defined the public API with its hosted model Jev ("System One",
`POST /v1/systemone`, https://docs.typesafe.ai/api); open-weight models
followed (Laya, Cloudflare's Clef and Clef-flash, Julia-1, Kev-4B), and
llama.cpp serves them natively from its own `/v1/systemone` since
ggml-org/llama.cpp#29818 (2026-10-02) and #29831 (Clef, 2026-10-03). We
expose the same API on the mesh gateway and on the daemon's local API,
serve it from the existing llama.cpp runtime after a pin bump, and carry
it over the tunnel as a fourth request kind.

## Public contract (gateway `POST /v1/systemone`, daemon local `/v1/systemone`)

Request, exactly TypeSafe's shape:

```json
{
  "model": "flock/laya",
  "state": "Help! My payouts have been failing for 3 days.",
  "questions": {
    "department": {"type": "choice", "instructions": "Which team should handle this?",
                   "criteria": {"billing": "Payments, invoicing, refunds", "technical": null}},
    "urgency":    {"type": "score", "instructions": "How urgent is this?",
                   "criteria": ["can wait", "this week", "today", "right now"]},
    "escalate":   {"type": "noul", "instructions": "Does this need a human within the hour?"}
  }
}
```

- `model` (string, required): a catalog id or `flock/<id>` alias of a model
  with `decision: true`. Any other model is `404 model_not_found` with a
  message naming `/v1/chat/completions`.
- `state` (required): string, object or array. Non-strings reach the model
  as compact JSON text.
- `questions` (required): object, 1..64 entries, keys are the customer's
  ids. **Key order is preserved** end to end (decode with an ordered
  decoder, never a Go map): answers come back in request order and options
  are shown to the model in the order written.
  - `type`: `choice` | `score` | `noul`.
  - `instructions` (required): string, object or array; not empty.
  - `criteria`: `choice` requires an object of 2..255 options, each value a
    description (string/object/array) or `null`; `score` requires an array
    of 2..10 level descriptions, lowest first; `noul` optional, an object
    with exactly `true` and `false` descriptions.
- `images` is rejected in v1 (`422`, "image input is not supported by this
  model"): none of the catalog's decision models takes images under
  llama.cpp yet (Clef is text-only there; OpenJev is CC BY-NC and not in
  the catalog).
- Unknown top-level fields are ignored, like the chat endpoints do.

Validation details both surfaces implement identically (amended 2026-10-03
from flockd#53's reference implementation, `flockd/internal/decision`):
a body that is not a JSON object is `400`, every other failure `422`; any
non-null `images` is rejected, including `[]`; `null` is a valid
description only for `choice` options (score levels and noul `true`/`false`
must be string/object/array); duplicate or empty question ids and option
keys are rejected; `state` must be present but may be an empty string;
noul `criteria` may list `true` and `false` in either order and that order
is kept. Upstream llama-server is laxer on all of these; we are strict so
the contract does not depend on a runtime's leniency.

The daemon's local API differs from the gateway only where the surface
does: no `401`/`429`, and "node not serving" is `503` (the local
convention) rather than `529`.

Response:

```json
{
  "model": "laya-q8_0",
  "answers": {
    "department": {"type": "choice", "choice": "billing",
                   "probabilities": {"billing": 0.91, "technical": 0.09}, "confidence": 0.82},
    "urgency":    {"type": "score", "score": 2.09,
                   "legend": {"0": "can wait", "1": "this week", "2": "today", "3": "right now"},
                   "probabilities": {"0": 0.0, "1": 0.12, "2": 0.67, "3": 0.21}, "confidence": 0.67},
    "escalate":   {"type": "noul", "noul": 0.63}
  },
  "usage": {"input_tokens": 239, "output_tokens": 0}
}
```

`answers` and every `probabilities`/`legend` object are written in request
order. `legend` is rebuilt by the gateway from the request's `criteria`; it
is not carried on the wire. `usage.output_tokens` is always 0.

Errors use the gateway's existing error envelope with TypeSafe's statuses:
`401` bad key, `404` unknown or non-decision model, `422` validation
failure (the message names the offending `questions.<id>` path) and
runtime-rejected input (`DecisionResult.invalid_input`), `429` rate limit
or no funds, `529` no node could serve it (retry with backoff). No
streaming. Batch: `/v1/systemone` joins the batch endpoint whitelist with
the same body per line.

## Wire

| Message | Field | Why |
|---|---|---|
| `types.RequestKind` | `REQUEST_KIND_DECISION = 4` | The fourth kind. |
| `types.ModelSpec` | `decision = 16` (bool) | Same shape as `embeddings = 13`: tells the daemon how to start the runtime and which endpoint the model serves. Mutually exclusive with `embeddings`. |
| `types.DecisionQuestionType` (new) | `CHOICE`, `SCORE`, `NOUL` | |
| `types.DecisionInput` (new) | `state_json`, `questions` | The validated request. |
| `types.DecisionQuestion` (new) | `id`, `type`, `instructions_json`, `options` | Ordered list, not a map. |
| `types.DecisionOption` (new) | `key`, `description_json` | Empty `description_json` = JSON `null`. For `score` the key is the level index. |
| `types.DecisionAnswer` / `DecisionProbability` (new) | see proto | Typed result; probabilities ordered like the options. |
| `tunnel.DispatchRequest` | `decision = 11` (`DecisionInput`) | kind=DECISION payload; covered by the dispatch signature like every other field. |
| `tunnel.NodeMessage` | `decision_result = 9` (`DecisionResult`) | One message, no stream; delivered by `request_id` like `EmbeddingResult`. |
| `tunnel.DecisionResult` (new) | `answers`, `usage`, `error`, `invalid_input` | `invalid_input` = the runtime rejected the input (llama-server 400): do not retry on another node. |
| `tunnel.Challenge` | `decision = 5` | Fingerprint probe for a decision model. |
| `tunnel.ChallengeResponse` | `answers = 6` | Its result; `output`/`output_sha256` stay empty. |
| `control.ControlService` | `RouteDecision` + `RouteDecisionRequest/Response` | Gateway -> coordinator, modelled on `RouteEmbedding`, plus `latency_class`/`max_latency_ms` so batch pricing and SLA routing work as for chat. |

## Semantics

- **The gateway owns validation.** It parses the public JSON with an
  ordered decoder into `DecisionInput` (types above), enforces every limit
  in "Public contract", and compacts each JSON leaf. The node trusts the
  shape but not the size: the runtime may still reject (model-specific
  option limits, context), which comes back as `invalid_input`.
- **The node rebuilds the llama-server body** from `DecisionInput`, writing
  `questions` and `criteria` objects in list order, POSTs it to the
  runtime's `/v1/systemone`, and maps the JSON answer onto `DecisionAnswer`
  in question order. Runtime `400` -> `invalid_input`; `501` (not a
  decision model) and anything else -> `error`. One exception: llama-server
  checks the batch before the context, so an over-long prompt on a
  whole-prompt-batch model is a `500` "too large to process"; the adapter
  maps that specific reply to `invalid_input` when it set the batch itself.
- **Usage.** `Usage.prompt_tokens` = llama-server's `usage.input_tokens`;
  `completion_tokens` = 0. The public `usage` uses TypeSafe's names
  (`input_tokens`/`output_tokens`).
- **Runtime flags.** A `decision` model starts llama-server without
  `--embeddings` (the server enables embedding mode itself).
  Whole-prompt-batch models (Laya-family including Julia-1, and Clef)
  evaluate a prompt in one batch, so the adapter sets `--batch-size` and
  `--ubatch-size` to one slot's context, `ceil(ctx-size / parallel)`: the
  longest prompt a slot admits. Causal decision models (Kev) take no batch
  flags. A server running Clef serves only `/v1/systemone`. (Amended
  2026-10-03 after flockd#53 measured it: total context would have
  allocated 131,072 for Julia-1 at 16 slots, and Kev needs none.)
- **Runtime build.** Needs a llama.cpp build with both upstream PRs
  (>= b11382). The runtimes pin moves from b9892; the new
  `runtime_build_id` goes through the staging manifest, and every
  fingerprint keyed by build id is regenerated (SPEC §2.2).
- **Pricing (SPEC §7).** Input tokens at the model's hardware-class input
  rate and payout share; there are no output tokens, so the ledger formula
  is unchanged (`CustomerCharge(class, prompt, 0, ...)`). Batch is 0.5x as
  everywhere. No new price row and no new `ModelClass`.
- **Trust.** Decode-speed envelopes do not apply (nothing is decoded):
  decision requests are exempt from timing checks the way embeddings are;
  the usage bound still applies to `prompt_tokens`. Fingerprints use a new
  prompt-set kind `decision` (public: fixed state + questions; private:
  expected probabilities per `(model_sha, quant, runtime_build_id)`),
  compared within an absolute tolerance per probability, never by hash:
  backends differ in the last bits. Canary cross-checks between two nodes
  use the same tolerance comparison.
- **Catalog.** `decision: true` on a manifest (mutually exclusive with
  `embeddings`), GGUF artifacts from the `ggml-org/*-GGUF` conversions,
  class by total params as usual: Julia-1 (0.144B) and Laya (0.421B) nano,
  Kev-4B small, Clef-flash (9B) small, Clef (27B) mid.

## Compatibility

- A daemon that predates `REQUEST_KIND_DECISION` maps unknown kinds to chat
  (`toRuntimeRequest` default) and would answer a decision dispatch with a
  chat error. It must never be sent one: the coordinator dispatches
  DECISION only to sessions reporting the model `ready`, and placement
  assigns `decision` models only to nodes whose
  `CapabilityProfile.daemon_version` is at least the first flockd release
  implementing this note. An older daemon also cannot load the artifact
  (unknown GGUF architecture on the old runtime build) and reports the
  model `failed`.
- A new daemon on the old runtime build fails the load the same way; the
  daemon should refuse a `decision` assignment up front when its runtime
  build predates the pin bump, with a reason that says so.
- Old gateways never produce `RouteDecision`; old coordinators return
  `Unimplemented`, which the gateway maps to `529`.
- `ChallengeResponse.answers` and `Challenge.decision` are ignored by old
  peers; the coordinator only issues decision challenges to nodes that
  serve a decision model, which are new by the rule above.

## Rejected alternatives

- **Opaque JSON passthrough** (`bytes body` in `DispatchRequest`, raw JSON
  back): the least code, but the gateway could not bound what it signs and
  forwards, trust could not compare answers without re-parsing an
  unversioned blob, and it would be the mesh's first untyped payload.
- **`map<string, DecisionQuestion>`**: proto maps are unordered; order is
  part of the public contract.
- **`google.protobuf.Struct`/`Value` for the JSON leaves**: loses number
  fidelity (everything becomes a double) and key order inside objects.
  Compact JSON text is what the runtime consumes anyway.
- **A `ModelTask` enum replacing `embeddings`**: cleaner, but it would
  strand every deployed daemon that reads `embeddings = 13`. A second bool
  is the additive move; an enum can absorb both later.
- **Reusing `Route` with a new kind and `RouteChunk` fields**: `Route` is a
  token stream with per-chunk trust capture; a decision is one message.
  `RouteEmbedding` is the precedent.
- **A flat decision price row** (as embeddings has): a 27B model and a 0.4B
  model would cost the same. Class input rate needs no new row.
- **Running Laya/Clef outside llama.cpp** (ONNX runtime, Python sidecar):
  a second runtime to build, sign and fingerprint on every platform, for
  models upstream llama.cpp now serves.
- **Emulating decisions with chat models** (upstream draft #29832): works
  without fine-tuning, but it is not merged, and the ask is the trained
  open-weight models.

Out of scope: image input (`images`, chat-message state with `image_url`),
per-request calibration temperatures, streaming, an MCP tool.
