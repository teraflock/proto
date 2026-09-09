# Design note: `ModelSpec` artifact parts + mmproj sidecar (additive, 2026-09-08)

Additive only; `buf breaking --against '.git#tag=v0.1.0'` clean. Consumers:
control-plane after the registry change (control-plane#36), flockd from the
first release that implements flockd#24. Older daemons ignore the new fields;
see "Compatibility" for what they see. Catalog shape: models#2.

| Message | Field | Why |
|---|---|---|
| `types.ArtifactPart` (new) | `url`, `sha256`, `size_bytes` | One pinned file of a multi-file artifact. Same three names as the catalog's per-part entries (`parts[].url/sha256/size_bytes`) so nothing is renamed between YAML, flat JSON and the wire. |
| `types.ModelSpec` | `parts = 14` (repeated `ArtifactPart`) | Sharded GGUFs (`<name>-00001-of-0000N.gguf` ...) need a per-part hash each — SPEC §6 pinning — which a single `artifact_url`/`sha256` cannot carry. Listed in series order; the daemon keeps the upstream basenames as sibling files so llama.cpp discovers the series from part 1. |
| `types.ModelSpec` | `mmproj = 15` (`ArtifactPart`) | Vision-language releases ship a projector sidecar (`mmproj-*.gguf`) that llama-server takes via `--mmproj`. Same shape, same pinning rules, not counted in `size_bytes`. |
| `types.ModelSpec` | comment on `sha256`, `artifact_url`, `size_bytes` | Semantics below. |

## Semantics

- Exactly one of (`artifact_url` + `sha256` as a file hash) or `parts` is
  set. Multi-part specs have an empty `artifact_url`.
- `size_bytes` is always the total across parts (mmproj excluded), so disk
  budgeting on a pre-`parts` daemon stays correct.
- **Composite id.** For a multi-part spec, `sha256` carries the composite id:
  `hex(sha256(concat(parts[0].sha256, parts[1].sha256, ...)))` where each
  part hash is its lowercase hex string and there are no separators. It is
  deterministic from the pinned part hashes, so the catalog emitter
  (`models/tools/validate/emit.go`), the registry loader
  (`control-plane/internal/registry/catalogfile.go`) and the daemon all
  derive the same value; `DispatchRequest.quant_sha256` and
  `ModelState`/local-API reports use it, and the per-file verification uses
  `parts[i].sha256`. A daemon must never hash-check a file against the
  composite.
- `mmproj` is verified and stored like a part; the runtime adapter passes
  its path to `llama-server --mmproj`.

## Compatibility

A daemon that predates these fields receives a multi-part assignment as a
spec with an empty `artifact_url` (and a `sha256` it cannot match to a
file). It must report the model `failed` with a clear reason
("no artifact in spec"); placement's per-node backoff for `failed` stops
the retry loop, and the coordinator additionally gates multi-part placement
on `CapabilityProfile.daemon_version` (control-plane#36).

## Rejected alternatives

- Comma-separated shard URLs in `artifact_url`, or relying on llama.cpp's
  implicit sibling discovery from `-00001-of-`: neither carries a per-part
  hash, so a corrupted or swapped shard would go unnoticed until fingerprint
  time.
- A separate `sharded_sha256` field for the composite: keeps `sha256` a pure
  file hash but forces every dispatch/report path to branch on which field
  is authoritative. Reusing `sha256` keeps `quant_sha256` pinning unchanged.

Out of scope: speculative-decode heads (`mtp-*`/`dflash-*`), TS publishing.
