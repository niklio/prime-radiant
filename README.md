# Prime Radiant

A native iOS app for modeling difficult decisions as probability-weighted game trees through
conversation. The user talks; the canvas renders. Each scenario is a persistent, resumable
workspace containing a chat transcript and a living decision tree, rendered in the visual
language of the Prime Radiant device from *Foundation*: luminous mathematics suspended in a
dark void.

Full specification: [docs/handoff.md](docs/handoff.md) as amended by
[docs/pivot-claude-tailscale.md](docs/pivot-claude-tailscale.md) and
[docs/pivot-v3-ssh-native.md](docs/pivot-v3-ssh-native.md).

## Architecture (SSH-native, zero box install)

There is **no backend at all**. The app embeds an SSH client and pairs once with "the box" —
any Mac on the owner's tailnet with the `claude` CLI logged in to their subscription. Chat
turns exec `claude` in streaming JSON print mode over SSH (tools disabled, login shell);
scenario sync is plain SFTP to `~/.prime-radiant/`. Auth is pairing: Tailscale SSH needs no
credentials at all; native Remote Login takes the system password exactly once, after which
the app installs its own ed25519 key and never sees the password again. Host keys are
TOFU-pinned in the Keychain. If the box is beyond reach, the app opens read-only from the
local store — quietly.

## Layout

```
/ios      Xcode project (SwiftUI + SceneKit) and PrimeRadiantCore (tree math, SwiftPM)
/worker   DEPRECATED — Cloudflare Worker from the pre-pivot architecture; teardown pending
/shared   Single source of truth: JSON Schemas, sample trees, prompt files, design tokens, mocks
```

## Privacy stance

Conversation traffic flows **only between the user's device and their own box** (then to
Anthropic via the owner's logged-in `claude` CLI, under the owner's subscription). No cloud
component exists; nothing else ever sees content. Transcripts land only on the device and on
the box (claude CLI local session files). One box, one subscription, one human.

## Development

- **Tree math** (`ios/PrimeRadiantCore`): `swift test` — runs on macOS with command-line tools alone.
- **App** (`ios/`): requires Xcode 16+, iOS 17+ target. Project is generated with XcodeGen
  (`ios/project.yml`).

All colors and type decisions live in `shared/tokens.json`; mocks under `shared/mocks/` are
regenerated from `shared/mocks/generate.py` — mocks and tokens must never drift apart.

## Conventions

Conventional commits; branch protection on `main`; every PR states whether tree math is
affected and whether tests were updated (see the PR template).
