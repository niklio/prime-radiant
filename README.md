# Prime Radiant

A native iOS app for modeling difficult decisions as probability-weighted game trees through
conversation. The user talks; the canvas renders. Each scenario is a persistent, resumable
workspace containing a chat transcript and a living decision tree, rendered in the visual
language of the Prime Radiant device from *Foundation*: luminous mathematics suspended in a
dark void.

Full specification: [docs/handoff.md](docs/handoff.md).

## Layout

```
/ios      Xcode project (SwiftUI + SceneKit) and PrimeRadiantCore (tree math, SwiftPM)
/worker   Cloudflare Worker (TypeScript): scenario sync backend
/shared   Single source of truth: JSON Schemas, sample trees, prompt files, design tokens, mocks
```

## Privacy stance

Conversation traffic flows **only between the user's device and OpenAI**, under the user's own
account (OAuth with PKCE — no app-owned OpenAI credential exists anywhere). The sync backend
stores scenario data but never sees, proxies, or logs chat requests. Request/response bodies are
not logged. There are no analytics on content — only operational metrics (latency, error rates).

## Development

- **Tree math** (`ios/PrimeRadiantCore`): `swift test` — runs on macOS with command-line tools alone.
- **Worker** (`worker/`): `npm test` (vitest), `npm run deploy` (wrangler).
- **App** (`ios/`): requires Xcode 16+, iOS 17+ target. Project is generated with XcodeGen
  (`ios/project.yml`).

All colors and type decisions live in `shared/tokens.json`; mocks under `shared/mocks/` are
regenerated from `shared/mocks/generate.py` — mocks and tokens must never drift apart.

## Conventions

Conventional commits; branch protection on `main`; every PR states whether tree math is
affected and whether tests were updated (see the PR template).
