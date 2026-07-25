# Prime Radiant — UX Update: Onboarding & Scenario Creation

Handoff doc for the two interaction systems added after the main spec's mock set: **tailnet onboarding** (pairing + self-provisioning over SSH) and **scenario creation** (capsule + hold-to-birth). Companion mocks are the PNGs shipped alongside this doc; the authoritative product spec remains `prime-radiant-handoff.md` and the motion bible remains `radiant-implementation-notes.md` — both already incorporate everything here. Screens keep the app's standing doctrine: nebula void everywhere, no chrome, no instructions, state expressed through light.

---

## 1. Onboarding — pairing with the box

**Architecture context (one line):** the app talks to a gateway on the user's own machine over their Tailscale tailnet; the model runtime is the user's Claude subscription via the Agent SDK on that box; there are no accounts and no API keys. Full detail: `radiant-pivot-claude-tailscale.md`.

### Flow

```
1-onboarding ──touch──▶ 1b-address ──submit──▶ probe:
                                        ├─ gateway already running ──────────────▶ 1d-paired
                                        ├─ Tailscale SSH available (no creds) ──▶ 1c2-provisioning ─▶ 1d-paired
                                        ├─ plain sshd ─▶ 1b3-credentials ───────▶ 1c2-provisioning ─▶ 1d-paired
                                        └─ unreachable ─▶ 1b2 (inline state, not a screen change)
   manual-install fallback only:  1c-pairing-code ─▶ 1d-paired
```

### Screens

- **`1-onboarding`** — flythrough video still, one line: *touch to begin*. Anywhere-tap advances. (Unchanged.)
- **`1b-pairing-address`** — a dim waiting node above a single capsule-styled field, ghost text `radiant.tailnet.ts.net`. Accepts MagicDNS name or raw 100.x IP; steer copy toward MagicDNS. On submit the node pulses (~1/s) while the app probes — **no spinner exists in this app**. Probe order: existing gateway → Tailscale SSH → plain sshd.
- **`1b2-pairing-unreachable`** — the same screen's failure state: field border warms to ember, node dims, one line fades in below (400ms): *"the radiant is beyond reach"* — deliberately the same phrase as the app's offline state, one vocabulary. It fades out when typing resumes. **Editing the field is the retry**; there are no alerts and no retry buttons.
- **`1b3-pairing-credentials`** — appears **only** on the plain-sshd path (Tailscale SSH makes it unnecessary — auth there is tailnet node identity). Address locked at top; `user` + password fields; one whisper: *"used once, then discarded."* Credentials are held in memory for the provisioning session only — never written to Keychain or disk.
- **`1c2-provisioning`** — the app installs the server itself by streaming the idempotent `server/provision.sh` over the SSH channel. Visual: a condensing node (the birth visual language — the radiant taking root *is* a birth) above three stage lines that map to real script phases: *reaching the box ✓ · planting the radiant ● · waking the engine*. On failure, halt on the failing line with one plain sentence — canonical case: the box has no `claude login` (browser OAuth, unautomatable) → show that single instruction; retry resumes. No logs on screen; full log kept server-side. The device token returns **in-band over SSH stdout** — no code entry in this path. Provisioning reruns later as the update mechanism via a quiet *re-provision* action in Settings.
- **`1c-pairing-code`** — fallback for hand-installed servers only: address whispered above a brightening node, six code cells (cyan caret in the active cell), caption *"code shown by your server."* Auto-advance per character; wrong code = shake-and-clear + error haptic.
- **`1d-paired`** — the node ignites fully, two rings expand outward (~700ms, success haptic), the server address glows gold beneath. This frame lasts under a second before the ~900ms camera flight to the empty home. Pairing is seen exactly once; Unpair lives in Settings.

**Reduce Motion:** pulses and rings become opacity steps; the flight becomes a cut.

## 2. Scenario creation — two canonical paths

The `+` button is deleted from the app (it was the last piece of chrome, and it was invisible against the void anyway). Creation now has two paths, both first-class:

- **Speech-first — the capsule.** The home carries the same capsule as every other screen (placeholder: *"describe the decision…"*). Describing a decision from the home creates a scenario: a node ignites at a system-chosen point on the shell, the camera flies to it, and the canvas assembles as the engine's first patch arrives. The mic path is identical.
- **Place-first — hold-to-birth (`10b-home-birth`).** Press-and-hold any **blank stretch of void** on the home for **~900ms**: the shared hold-ring fills at the touch point while an unborn node *condenses* beneath it — glow gathering out of the nebula. Existing constellations dim to ~60% during the hold (the same focus language as node selection). Completing the hold ignites the node **at those shell coordinates** and focuses the capsule; the first utterance names and seeds the scenario. This is how a user chooses *where* on the shell a future lives.
- **No empty scenarios can exist:** early release, or dismissing the capsule without describing, dissolves the unborn node back into cloud (~450ms). Nothing is created until something is said.

## 3. The hold-ring — one component, everywhere

Every hold gesture in the app renders **the identical ring**: track circle r=26, amber, 2px, 22% opacity; gold fill arc, 2.4px, round caps, sweeping clockwise from 12 o'clock. No decorations — no directional motes, trails, arrows, or halos around it, ever. Contexts differ only in:

| Context | Duration | Beneath the ring | Complete → |
|---|---|---|---|
| mark node reached (canvas) | ~700ms | the existing node | path solidifies, siblings ghost, EV recounts |
| unmark / resolve (canvas) | ~700ms | the reached/terminal node | reverse / resolve flow |
| birth a scenario (home void) | ~900ms | a condensing unborn node | node ignites at that point, capsule focuses |

The 900ms birth duration is deliberately longer than the 700ms mark so the two can't collide in muscle memory. Haptics: ramp during any fill; mark completes with a single strong thud, birth with a distinct double-pop. Early release always drains the ring fast (~150ms), no completion haptic. Reduce Motion: the ring fills in opacity steps.

## 4. What did not change

Everything else: the through-the-void rendering, the orbital shell and single-globe model, the capsule/ridge footer system, the breadcrumb ribbon, chat and voice surfaces, the gesture lexicon outside creation, and the whole visual language. This update adds screens `1b, 1b2, 1b3, 1c, 1c2, 1d, 10b`, modifies `10` (capsule added, `+` removed) and `2` (unchanged visually; its unborn node is now understood as the same birth motif), and unifies the hold-ring across `7` and `10b`.

**Files in this package:** this doc + the ten screens above (`1-onboarding`, `1b-pairing-address`, `1b2-pairing-unreachable`, `1b3-pairing-credentials`, `1c2-provisioning`, `1c-pairing-code`, `1d-paired`, `2-home-empty`, `10-home-constellation`, `10b-home-birth`).
