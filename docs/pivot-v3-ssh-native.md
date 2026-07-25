# Pivot v3 addendum — SSH-native (zero box install)

**Supersedes the gateway service in `pivot-claude-tailscale.md` §2/§4** (owner decision,
2026-07-24: "zero commands on the box — one is not a compromise"). Everything else in that
doc stands: subscription-powered, no API keys anywhere, single user per box, Tailscale as
the security boundary, Cloudflare deleted.

## The design

There is **no box-side component at all**. The app embeds an SSH client and carries the
entire protocol:

```
iPhone (SwiftUI app, embedded SSH client)
   │  Tailscale (WireGuard) → SSH (port 22)
   ▼
Box: any Mac with `claude` logged in + Tailscale
   ├─ exec channel: claude (stream-json print mode, tools disabled) ← chat turns
   └─ SFTP: ~/.prime-radiant/scenarios/*.json                       ← backup/sync
```

- **Pairing:** user enters the box address (MagicDNS name or 100.x IP — SSH is the
  transport, so no TLS/ATS concerns). Auth order: Tailscale SSH if the node has it
  (no credentials at all) → system password once, after which the app installs its own
  key in `authorized_keys` and never sees the password again. Host key pinned on first
  connect (TOFU) in the Keychain.
- **Chat:** the app assembles the prompt (bundled system.md + transcript summary + tree
  JSON + focusedNodeId), execs `claude` in streaming JSON print mode through a login shell
  (so PATH resolves), streams `say`, validates `{say, patch}` and retries ≤2× — all logic
  that already lives in PrimeRadiantCore. A warm process per scenario session avoids
  per-turn cold starts; drop → respawn.
- **Sync/backup:** scenario JSON snapshots over SFTP, LWW on `updatedAt`. The device
  remains the source of truth; the box is the durable copy and the bridge to a future
  second device.
- **States:** box unreachable → read-only, "the radiant is beyond reach". Rate-limit
  errors from the CLI → "the radiant rests until the cycle renews".

## Rules that carry over unchanged

- Official surfaces only: all inference through the `claude` CLI; never extract or replay
  OAuth tokens against the API directly.
- If `ANTHROPIC_API_KEY` is set in the login-shell environment of the box, turns would
  silently bill API credits — the app must detect it (`env` probe at pairing time) and
  warn.
- Individual use: one box, one subscription, one human.
- Transcripts land only on the user's own device and their own box (claude CLI local
  session files). Nothing else ever sees content.

## What the app requires of a box

1. On the user's tailnet, SSH answerable (Tailscale SSH enabled, or macOS Remote Login —
   a Settings checkbox).
2. `claude` CLI installed and logged in to the owner's subscription.

That's the entire contract. No install, no service, no pairing codes.
