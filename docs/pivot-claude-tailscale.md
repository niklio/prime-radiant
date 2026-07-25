# Prime Radiant — Architecture Pivot: OpenAI OAuth → Claude Subscription over Tailscale

**For the executing agent.** This doc covers one change and only that change: the model runtime and auth architecture. The full product spec remains `prime-radiant-handoff.md` (already updated to match this doc); the art direction, interaction model, mocks, tree schema, and patch contract are **completely unaffected** — nothing in them ever depended on which provider answers the chat. If you have already built against the OpenAI/PKCE/Cloudflare design, this doc is your migration list. If you're starting fresh, build this version directly.

---

## 1. Why the pivot

The OpenAI user-facing OAuth program the previous design depended on is closed. The owner's requirements for the replacement, in priority order:

1. **No API keys, anywhere.** Not in the app, not on a server.
2. Inference is powered by the owner's existing **Claude Pro/Max subscription**.
3. Personal, single-user system on hardware the owner controls.

This is now an officially supported configuration: as of June 15, 2026, Claude subscription plans include a **separate monthly Agent SDK credit** covering Claude Agent SDK usage, `claude -p`, and third-party apps built on the Agent SDK — independent of the subscription's interactive usage limits. Verify current terms before building: https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan

**The hard constraint that comes with it:** subscription auth is licensed for *individual* use. This app serves exactly one user — the subscription holder. Never generalize it to multi-user without moving to API-key billing.

## 2. The new architecture in one paragraph

A small **gateway service runs on the owner's own machine** ("the box"), reachable **only over their Tailscale tailnet**. The iOS app pairs with the box once (MagicDNS address + one-time code) and thereafter talks to it for everything: chat turns and scenario sync. The gateway embeds the **Claude Agent SDK** as a long-running process, authenticated to the owner's Claude subscription via `claude login`. There is no OAuth flow in the app, no account system, no API key anywhere, no cloud component at all. Cloudflare (Worker/D1/KV) is **deleted from the architecture**.

```
iPhone (SwiftUI app)
   │  Tailscale (WireGuard; `tailscale serve` provides TLS)
   ▼
Box: gateway service (TypeScript, systemd)
   ├─ /v1/pair        one-time code → device token
   ├─ /v1/chat        SSE; wraps the Agent SDK
   ├─ /v1/scenarios   CRUD + sync → SQLite (WAL, nightly .backup)
   └─ Claude Agent SDK (long-running) ── owner's Claude subscription
```

## 3. App-side changes (`/ios`)

- **Onboarding:** the flythrough video and "touch to begin" are unchanged. Touching now opens a **single pairing field** for the server address instead of an OAuth sheet. Use the box's **MagicDNS name** (`radiant.<tailnet>.ts.net`) — instruct the user toward MagicDNS, not raw `100.x` IPs, so address churn never breaks pairing. Flow: health-check → user enters the one-time pairing code printed by the server CLI → app receives a long-lived device token → endpoint + token into Keychain (`AfterFirstUnlockThisDeviceOnly`). Settings shows the paired server + Unpair. The user does this once, ever.
- **Delete:** all OAuth code paths, `ASWebAuthenticationSession` usage, token refresh logic, and any API-key entry UI. None of these have a replacement — pairing is the entirety of auth.
- **Transport:** plain HTTPS to the MagicDNS host. `tailscale serve` fronts the gateway with a real TLS cert, so ATS needs no exceptions. The device token goes in an `Authorization: Bearer` header; it exists to distinguish this app from other tailnet traffic, not as the security boundary — the tailnet is the security boundary.
- **Offline stance (new):** if the tailnet/box is unreachable, the app opens **read-only** — scenarios and trees render from the local store; composer and marking disable quietly with one status line in the Radiant voice: "the radiant is beyond reach." No error dialogs.
- **Budget-exhausted state (new):** if the gateway reports the monthly Agent SDK credit is exhausted (and extra usage is off), surface it as "the radiant rests until the cycle renews" — again quiet, again no dialogs.

## 4. Server (`/server`, replaces `/worker`)

- **Stack:** TypeScript, `@anthropic-ai/claude-agent-sdk`, run as a **systemd unit**. Keep the SDK session/process **long-running** — do not spawn `claude -p` per request; process cold-start costs seconds and destroys conversational latency.
- **Endpoints:** `/v1/pair` (one-time code → device token; codes printed by the CLI on first run and on demand), `/v1/chat` (POST, streams SSE), `/v1/scenarios` (CRUD + sync). Bind to the tailnet interface; front with `tailscale serve`. **Never log request/response bodies.**
- **Chat contract (unchanged from the main spec):** the app sends transcript summary + full tree JSON (+ `focusedNodeId`); the engine is prompted to return strict `{say, patch}` JSON; the **gateway validates against the JSON Schemas in `/shared`** and retries up to 2× with the validator error in-context. Stream `say` tokens over SSE as they arrive; deliver `patch` at turn end (the canvas animates on patch application, so end-of-turn delivery is correct). Model selection lives in server config: Sonnet-class default for interactive turns, top-model toggle for restructures — model IDs are never shipped in the app binary.
- **Storage:** SQLite (WAL mode) for scenarios/trees/transcripts; nightly `sqlite3 .backup` to a local snapshot path; soft-delete with 30-day purge job. This replaces D1/KV entirely.
- **Deploys:** `git pull && systemctl restart radiant` on the box. Document in `/server/README`. There is no cloud deploy; remove any wrangler/Cloudflare CI steps.

## 5. Subscription auth on the box — the rules that matter

1. **Login:** `claude login` on the box with the owner's **subscription credentials only** — no Console credentials attached, so nothing can silently fall through to API billing.
2. **The env-var footgun (encode as a startup check):** if `ANTHROPIC_API_KEY` is present in the service environment, Claude Code/Agent SDK **silently uses it and bills API credits** instead of the subscription. `server/install.sh` and the systemd unit must check for this and **refuse to start** with a clear message if it's set.
3. **Stay inside the official surfaces.** All inference goes through the Agent SDK / official CLI. Never extract or replay OAuth tokens against the API directly — that pattern is explicitly prohibited; the SDK path is the supported one.
4. **Budget model:** the Agent SDK credit is monthly and separate from interactive limits (Pro ≈ $20/mo of Sonnet-equivalent, Max tiers larger — verify current figures). Past the credit: usage moves to extra-usage API rates only if the owner enabled that, otherwise the SDK pauses until the cycle renews. The gateway should detect the paused state and report it to the app as the budget-exhausted status (§3). Decision-modeling turns are small; Pro is likely sufficient, but do not hide the state when it isn't.
5. **Single user.** One subscription, one human, one device token in practice. Do not add multi-account support.

## 6. Migration checklist (if any OpenAI-era code exists)

- [ ] Remove OpenAI SDK/deps, OAuth/PKCE flows, token refresh, and any `Sign in with ChatGPT` strings or entitlements
- [ ] Remove `/worker`, wrangler config, D1/KV bindings, and Cloudflare CI jobs
- [ ] Add `/server` (gateway + Agent SDK + install script + systemd unit); port `/v1/scenarios` handlers from the Worker to SQLite
- [ ] Replace app networking base URL + auth header with paired endpoint + device token
- [ ] Add pairing UI (one field + one code entry), offline read-only state, budget-rest state
- [ ] Update the system prompt's single policy sentence to reference Anthropic's usage policies (already done in §5.2 of the main spec)
- [ ] CI: server typecheck/tests replace Worker jobs; TestFlight lane unchanged
- [ ] Verify: no `ANTHROPIC_API_KEY` in any environment; `claude login` state on the box; `tailscale serve` cert valid; pairing round-trip; SSE streaming end-to-end; kill the box → app degrades to read-only gracefully

## 7. What did NOT change

The tree/patch schemas, the deterministic client-side math (EV, conditioning, backward induction, distributions), the entire art direction (through-the-void rendering, orbital shell, nebula, capsule, ridge), the gesture lexicon and motion design (`radiant-implementation-notes.md`), the no-instruction doctrine, milestones M1's canvas work, and the TestFlight pipeline. The system prompt in §5.2 changes exactly one sentence (the policy reference). Everything the user sees and touches is identical to the mocks — the pivot is entirely about where the intelligence lives and how the app reaches it.
