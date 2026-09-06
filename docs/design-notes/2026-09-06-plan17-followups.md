# Design note: plan 17 follow-ups (additive, 2026-09-06)

Additive fields only; `buf breaking` clean. Consumers: flockd ≥ 0.5.0,
control-plane after the matching deploy. Older daemons ignore the new
fields and keep working.

| Message | Field | Why |
|---|---|---|
| `types.ModelState` | `origin` | Admin and placement need to know mesh-placed vs operator-installed without inferring it from coordinator memory (lost on restart). |
| `tunnel.TokenChunk`, `control.RouteChunk` | `reasoning` | Reasoning models' chain-of-thought travels separately from `delta`, so the gateway can emit OpenAI's `reasoning_content` instead of inline `<think>` tags. Both streams stay fully relayed (billing, canary diffs). |
| `tunnel.Heartbeat` | comment on `ram_used_mb`/`vram_used_mb` | Since flockd 0.4.0 these carry the measured footprint of loaded runtimes, not host usage. |
| `tunnel.ModelAssignment` | `stage` | The floor pass stages models that fit disk but not memory; the daemon downloads and reports `cached` without trying to load. Removes the staged-vs-warm ambiguity in the registry. |
| `tunnel.ConfigUpdate` | `latest_version`, `minimum_version`, `release_url` | Nodes learn about releases and the drain minimum from the mesh; the public feed stays for apps. |
| `control.NodeSummary` | `budget`, `ram_used_mb`, `vram_used_mb` | Admin node page shows operator ceilings and live memory. |

State strings (`cached`, `declined`, `failed`) were already in use as a
free-string contract; the `ModelState.state` comment now lists them.
