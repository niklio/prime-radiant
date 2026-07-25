# Prime Radiant gateway (`/server`)

The box-side half of the hybrid architecture: the app pairs over **SSH first**
(pivot v3 posture — Tailscale SSH or Remote Login, host key TOFU-pinned), then
**installs this gateway by streaming `dist/provision-bundle.sh` over the SSH
channel**, then switches its traffic to the gateway (HTTP + SSE over the
tailnet) for latency and connection-suspension reasons. SSH remains the
repair/upgrade channel and transport fallback. Model runtime is the owner's
Claude subscription via the logged-in `claude` CLI — no API keys anywhere,
one box, one subscription, one human.

```
iPhone ── Tailscale ──▶ gateway (launchd: com.primeradiant.gateway)
                          ├─ GET  /v1/health          {ok, version, paired, agentReady, budget}
                          ├─ POST /v1/pair            hand-installed servers only
                          ├─ POST /v1/chat            SSE; ONE warm `claude` stream-json process
                          ├─ /v1/scenarios…           CRUD + sync (LWW, soft-delete/restore)
                          └─ ~/.prime-radiant/gateway/{server.mjs,config.json,data.sqlite,backups/}
```

Auth is `Authorization: Bearer <deviceToken>` on everything except `/v1/health`
and `/v1/pair`; the tailnet is the security boundary, the token distinguishes
the app from other tailnet traffic.

## Install paths

- **App-provisioned (normal).** The app runs
  `ssh box 'sh -s' < server/dist/provision-bundle.sh`. The script emits exact
  stage markers the app renders (`##stage:reach|plant|wake`, then
  `##token:<64-hex>` and `##addr:<url>`, or `##fail:<stage>:<one sentence>` —
  full grammar in the header of `provision.sh`). The device token is minted by
  the script into `config.json` and returned **in-band over SSH stdout**; the
  pairing-code path is never used here.
- **Hand-installed (fallback).** Copy `gateway/dist/server.mjs` anywhere and
  run `node server.mjs`. With no token in config, the server prints a one-time
  six-digit **pairing code** to stdout/log; the app's `1c-pairing-code` screen
  exchanges it at `POST /v1/pair` for the device token (single use, one device).

**Upgrade = re-provision.** Re-running the bundle replaces `server.mjs`, keeps
config/token/data, and kickstarts the service. That is the whole deploy story
(Settings → quiet *re-provision* action in the app).

## Build & test (dev machine only — boxes never run npm)

```
cd server
npm install
npm run build     # gateway/dist/server.mjs (single file, ajv + /shared bundled)
                  # dist/provision-bundle.sh (provision.sh + base64 payload)
npm test          # vitest; provision tests run the real bundle in a sandbox HOME
```

Runtime dependencies: **none** — `node:http`, `node:crypto`, `node:sqlite`.
Storage cutoff: `node:sqlite` needs Node ≥ 22.13 (flag-free); on Node 20 the
gateway transparently falls back to a JSON-file store behind the same
interface (`gateway/src/storage.ts`), and an existing `data.json` keeps
winning after a Node upgrade. Provisioning requires Node ≥ 20 on the box.

## Chat contract

The app assembles context; the gateway assembles the same prompt the app's
SSH path used (bundled `shared/prompts/system.md` + conversation + turn
contract), holds **one warm `claude -p --input-format stream-json …`
process** (login shell, tools disabled, model alias from config by mode:
`interactiveModel`/`restructureModel`), and serializes turns through it.
SSE events: `say` deltas (thinking deltas filtered) → `turn` with the final
`{say, patch}` **after ajv validation** against `shared/schema` (≤2 in-context
retries) → `done`; failures emit machine-readable `error` events —
`{"error":"budget_resting"}` on rate/usage exhaustion (the app's "the radiant
rests" state), `{"error":"invalid_turn"|"turn_failed", …}` otherwise. Dead
warm process → respawn; per-turn one-shot fallback.

## Backups & restore

An in-process job snapshots the store nightly to
`~/.prime-radiant/gateway/backups/scenarios-YYYY-MM-DD.{sqlite,json}` (14-day
rotation) and hard-purges scenarios soft-deleted more than 30 days ago.
**Restore:** stop the service (`launchctl bootout gui/$UID/com.primeradiant.gateway`),
copy a snapshot over `data.sqlite` (or `data.json`), bootstrap again.

## The footgun

If `ANTHROPIC_API_KEY` is present, the claude CLI **silently bills API
credits instead of the subscription** (pivot §5.2). Defense in depth:
provisioning fails on a key in the login environment; the gateway refuses to
start (exit 1) on a key in its own env **or** in the login shell it spawns
claude through; the LaunchAgent passes a minimal fixed environment. If you
edit shell profiles, re-run provisioning to re-check.

## Budget note

The June 2026 subscription plans include a separate monthly Agent SDK credit
(pivot §1) — but that upstream change is **paused**, so gateway turns
currently draw on the owner's normal subscription usage limits. The gateway
detects the paused/exhausted state from CLI rate-limit/usage errors and
reports `budget: "resting"` on `/v1/health` plus `budget_resting` on the
stream; it clears on the next successful turn. Decision-modeling turns are
small, but do not hide the state when limits bite.

## Operations crib

```
launchctl print gui/$(id -u)/com.primeradiant.gateway   # service state
tail -f ~/.prime-radiant/gateway/gateway.log            # ts/route/status/ms lines — never bodies
tail -f ~/.prime-radiant/gateway/provision.log          # full provisioning log
curl -s http://127.0.0.1:7717/v1/health                 # local health
tailscale serve status                                  # TLS fronting (optional; provision attempts it)
```

Never log request/response bodies, prompts, or tokens — transcripts exist
only on the user's device and their box.
