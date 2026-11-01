# Design note: explainable placements — `ModelState.reason`, `ModelAssignment.placements`, `BudgetUpdate` (additive, 2026-11-01)

Additive only; `buf breaking --against '.git#tag=v0.1.0'` clean. Consumers:
control-plane (coordinator, admin node page, console node endpoint) and
flockd from v0.9.0, which is the version the coordinator gates on. Older
daemons and older coordinators keep working unchanged; see
"Compatibility".

## Why

A triage on 2026-11-01 found every node declining `qwen3.6-27b` for days
with "model not in this node's catalog" while the coordinator recorded
only "node reported declined" (`handleModelState`): the daemon knew the
cause, the wire did not carry it, and nobody saw it from the admin
console. Two neighbouring gaps have the same shape:

- operators watch models arrive with no indication whether the floor
  policy, demand or a warm-on-request placed them — the daemon is told
  *what* to load, never *why*;
- the daemon's Hello budget (`max_disk_mb`, `max_ram_mb`) is frozen at
  session start, so a change in the app only reaches placement at the
  next reconnect.

| Message | Field | Why |
|---|---|---|
| `types.ModelState` | `reason = 5` (string) | The daemon's reason for a `declined` or `failed` report — the same text its local API and activity feed already show — so the coordinator can store it on the `assign_declined` / `assign_failed` node events and the admin and console node pages can show it. For `assigned` / `downloading` (and the `cached` that ends a stage) the node echoes the placement reason it was given (`floor`, `demand`, `warm`, `stage`), so `ListNodes` and the node agree on why a model is in flight. |
| `tunnel.PlacementReason` (new enum) | `FLOOR`, `DEMAND`, `WARM`, `STAGE` | Which part of placement (SPEC §4.4) produced the entry: the floor pass, the demand pass, warm-on-request, or the floor pass staging a download. One value per pass, so the daemon can render a sentence per value without parsing. |
| `tunnel.Placement` (new) | `model_id`, `reason` | One reason per model in an assignment. A side list keyed by id rather than a field on `ModelSpec`: the spec is the catalog entry, shared with every other message that carries one, and must not grow placement bookkeeping. |
| `tunnel.ModelAssignment` | `placements = 4` (repeated `Placement`) | Reasons for the models in `assign` and `stage`. Not for `evict_model_ids`: an eviction's "why" is always "to make room", which the activity row already says. |
| `tunnel.BudgetUpdate` (new) | `budget` (`types.ResourceBudget`) | A fresh copy of the budget the Hello carried, sent when the operator changes a budget setting live. The whole budget, never a delta, so the coordinator's `SetBudget` is the same call for both. |
| `tunnel.NodeMessage` | `budget_update = 10` | New oneof member. |

## Semantics

- **`ModelState.reason` is free text, written for the operator.** The
  daemon sends the reason it already has (`assign.conclude`): policy
  refusals ("mesh-managed models are off on this node", "model is in
  models.exclude", "model not in this node's catalog", "does not fit in
  max_disk_mb", a too-old runtime), hash pinning ("catalog sha256 differs
  from the coordinator's") and load or download errors. The coordinator
  never parses it; it stores it as the node event's `detail`
  (`"node reported declined: <reason>"`, keeping the prefix every
  existing consumer and test matches on) and shows it verbatim. Keep it
  short: it is a cell on a page, not a log line.
- **The placement reason is a closed enum.** The coordinator fills it from
  the placer's plan: `scheduler.Assignment.Reason` is set per pass
  (`demand` by the demand pass, `floor` / `stage` by the floor pass) and
  `placeNow` rewrites its assignments to `warm`. The daemon maps it to
  the short name and records it on the activity row ("mesh assigned X
  (mesh floor)"), on the local API's `Assignment.reason` while the
  placement is in flight, and durably on the model's cache entry
  (`ModelRow.placement_reason`) once it is on disk, so the desktop can say
  "placed by the mesh floor" vs "requested by a customer" for as long as
  the model is there. A later assignment for the same model (a warm of a
  cached copy) replaces it.
- **`BudgetUpdate` replaces, it does not merge.** The coordinator applies
  it exactly as it applies the Hello budget (`registry.SetBudget`): the
  next placement round and the admin's node page read the new ceilings.
  The daemon sends one whenever a limits PUT changes any field that is in
  `ResourceBudget` (`max_disk_mb`, `max_ram_mb`, `max_concurrent`,
  `serve_on_battery`, `max_temp_celsius`, `serve_policy`) and skips it
  when the resulting budget equals the last one sent on this session. The
  Hello itself now reads the live values too, so a reconnect never
  resurrects the config file's numbers over the operator's.

## Compatibility

- **Old daemon, new coordinator.** `ModelState.reason` arrives empty and
  the coordinator records `"node reported declined"` as before. The
  coordinator gates `placements` on `CapabilityProfile.daemon_version`
  (`placementReasonMinDaemonVersion = v0.9.0`, same shape as
  `gateMultiPart`) and leaves the field out for older daemons; even if it
  did not, proto3 unknown fields are harmless there. No `BudgetUpdate`
  is ever sent, so nothing changes.
- **New daemon, old coordinator.** The coordinator ignores `reason` (an
  unknown field) and drops `budget_update` (an unknown oneof member;
  `GetMsg()` is nil and the session switch has no default) — the budget
  then follows at the next reconnect, exactly as today. The daemon never
  receives `placements`, records no placement reason, and its UI falls
  back to the plain "mesh" badge.
- `buf breaking` is clean: every change is a new field, a new message or
  a new enum; nothing is renumbered or renamed.

## Where it lands

- proto: this note; `types.proto`, `tunnel.proto`; `gen/` regenerated with
  the pinned plugins.
- flockd v0.9.0: `internal/assign` sends reasons and records placement
  reasons; `internal/localapi` (`Assignment.reason`,
  `ModelRow.placement_reason`, `model_assignment` SSE payload) and the
  limits API sends `BudgetUpdate`; `internal/tunnel` carries both.
- control-plane: `handleModelState` stores the reason; `registry`
  remembers a placement's reason and the daemon's; `ListNodes` carries
  both in `ModelState.reason`; the admin node page and
  `/v1/console/nodes/{id}` show them; `assignmentsFor` + a version gate
  fill `placements`; the session loop applies `BudgetUpdate`.
- desktop: Models screen says why the mesh placed a model.
