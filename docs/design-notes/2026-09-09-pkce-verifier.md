# Design note: `EnrollRequest.pkce_verifier` (additive, 2026-09-09)

Additive only; `buf breaking --against '.git#tag=v0.1.0'` clean. Closes the
gap in control-plane#6: `tera login` generated a PKCE verifier and sent the
S256 challenge to the claim page, then threw the verifier away, so the
handshake proved nothing — anyone who caught the claim code off the loopback
redirect could redeem it.

| Message | Field | Why |
|---|---|---|
| `tunnel.EnrollRequest` | `pkce_verifier = 5` (string) | The proof of possession. The daemon sends the verifier it generated alongside the claim code; the coordinator computes `base64url(SHA256(verifier))` and compares it with the `code_challenge` the website stored on the claim code when it minted it (`claim_codes.code_challenge`, control-plane migration). |

## Semantics

- The check runs before the code is redeemed, so a wrong or missing verifier
  does not burn the code (same ordering as the banned-key check).
- A claim code with no stored challenge (`tera login --claim-code`, codes
  minted before this shipped, dev meshes with `dev_accept_any_claim`) is
  accepted with or without a verifier — the field is optional and unchecked
  there.
- A claim code with a stored challenge is refused when the verifier is empty
  or does not hash to it.

## Compatibility

- Daemons that predate the field (flockd <= 0.5.x) never send it. They keep
  enrolling with unbound codes; against a browser-flow code they are refused
  with a message that names the missing verifier, and the code survives for
  a retry with an upgraded daemon or via the claim page's `--claim-code`
  path.
- Coordinators that predate the check ignore the field (unknown fields are
  dropped by proto3).

## Rejected alternatives

- Sending the verifier to the website and letting it verify: the website
  never sees the daemon, only the browser; the coordinator is where the
  code is consumed, so it is the only place the check cannot be bypassed.
- A `code_challenge` field on `EnrollRequest` instead of the verifier: the
  challenge is public (it was in the browser URL), so it proves nothing.
