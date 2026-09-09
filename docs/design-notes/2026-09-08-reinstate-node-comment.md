# Design note: `ReinstateNode` comment (comment-only, 2026-09-08)

Comment-only change to `flock/control/v1/control.proto`; no field, message
or RPC changes; `buf breaking --against '.git#tag=v0.1.0'` clean.

The `ReinstateNode` doc comment claimed "the daemon does not retry after a
ban-drain, so the operator still restarts flockd". Verified false
(control-plane#13, #33): flockd's tunnel client redials with backoff after
any session error, and since control-plane `609f6d2` a ban closes the
tunnel after the `Drain` so the daemon actually goes back through Hello.
The comment now describes the real contract — ban drains then closes,
redials are refused while banned, the first dial after `ReinstateNode` is
admitted into probation, no restart. Generated Go regenerated for the
comment text only.
