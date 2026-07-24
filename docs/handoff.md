# PRIME RADIANT — iOS Build Handoff

**Audience:** Claude Code (implementing agent). This document is the complete product, design, and engineering specification. The author is handing off, not building. **Model runtime is OpenAI** (user-facing OAuth with PKCE); the implementing agent being Claude Code has no bearing on the runtime choice. Where this doc says "verify," treat current official documentation as authoritative over this doc's assumptions.

---

## 1. Product definition

Prime Radiant is a native iOS app for modeling difficult decisions as probability-weighted game trees through conversation. The user talks; the canvas renders. Each scenario is a persistent, resumable workspace containing a chat transcript and a living decision tree. The app's entire visual identity is the Prime Radiant device from *Foundation*: luminous mathematics suspended in a dark void.

**Core loop:** user describes a decision → the model elicits structure (players, moves, information, payoffs, probabilities) → the model emits a machine-readable tree → the canvas renders it → the user refines payoffs/probabilities/branches over further turns → as real life unfolds, the user marks which branch occurred and the tree re-conditions around reality.

**Product principles (bake these into every prompt and review):**

1. **The user's utility function is sovereign.** The engine's job is faithful descriptive decision theory over the payoffs the user declares — eliciting them precisely, surfacing tradeoffs and inconsistencies *as math*, and computing optimal policies against them. The engine never substitutes its own preferences, appends unsolicited ethical commentary, or nudges payoffs toward values the user didn't state. It is an instrument, like a spreadsheet. (The model provider's usage policies still govern the underlying API; if a request can't be modeled under them, the engine says so in one plain sentence and offers the nearest modelable framing — no lectures.)
2. **Numbers are honest or absent.** Every probability and payoff is either user-supplied, explicitly assumed (and labeled), or refused. Deep conditionals compound uncertainty; the UI communicates coarseness rather than false precision.
3. **The tree is the interface.** Chat exists to build and revise the tree. Any state the model holds must be serialized into the tree or it doesn't exist.
4. **Optimal is computed, not vibed.** EV maximization, backward induction, and equilibrium reasoning happen deterministically in app code from the tree data. The model proposes structure and estimates; the app computes.

**Non-goals (v1):** multi-user/shared scenarios, Android/web clients, real-money integrations, notifications, Monte Carlo simulation, non-tree game representations (normal-form matrices can be modeled as depth-2 trees).

---

## 2. User experience specification

### 2.1 Onboarding & auth (OpenAI account link)

- First launch is a **full-screen video**: a 10–15s seamless loop of *navigating the radiant in 3D* — the camera drifting and banking through an endless field of filaments and glowing nodes, branches streaming past with depth fog and parallax, never resolving into a full tree. Produce it by scripting a camera path through a large generated tree in the production canvas engine itself and capturing at 2×; encode HEVC ~30fps, dark-mastered so type floats on it; loop point imperceptible. Static poster frame under Reduce Motion / Low Power Mode. Over the video: the wordmark small, and one line — **touch to begin · sign in with ChatGPT**. Anywhere-tap starts OAuth. No buttons, no rings, no glyph decoration, no form furniture: the screen is a window into the instrument, and touching it wakes it.
- **The only auth path is OpenAI's user-facing OAuth with PKCE** — the same account flow Codex uses: Authorization Code + PKCE via `ASWebAuthenticationSession`, custom-scheme/Universal-Link redirect, no client secret anywhere (PKCE removes the need). Tokens in Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`); proactive refresh; revocation returns to the ignition screen. **There is no API-key entry, no fallback auth mode, anywhere in the app** — if OAuth is unavailable, the app says so on the ignition screen and waits. Verify current endpoints, scopes, and token lifetimes in OpenAI's docs at build time; docs win over this paragraph.
- **Production posture:** PKCE tokens are user-scoped and secret-free, so **model calls go directly from device to OpenAI** with the user's token — no middleman ever touches conversation content. The Cloudflare Worker (§6) handles only scenario sync; it never proxies or logs chat traffic. No app-owned OpenAI credential exists anywhere in the client. Settings shows the linked account and a single Unlink action.

### 2.2 Home — the constellation

- **The constellation is the only home.** A single zoomed-out canvas where every scenario is a small mini-tree cluster floating in the shared void — rendered from its real stored tree, sized by recent activity, labeled beneath in serif with a status glyph line (○ modeling · ◐ in progress · ● resolved, resolved clusters carrying their outcome, e.g. "+$8k vs est."). Faint connective dust drifts between clusters. **Tap a constellation (or pinch into it) and the camera dives — the cluster grows into the full scenario canvas** in one continuous zoom; this transition is the app's second signature moment after speak-and-reorganize. Empty state: one pulsing unborn node at center — touching it creates the first scenario. `+` in the top bar creates from anywhere. There is no list view.
- **Management is gestural, like everything else:** hold a constellation and it lifts under the finger (haptic); two wells fade in at the bottom edge — **ARCHIVE** and **DELETE** — and dragging the cluster into one acts (delete = soft-delete server-side, 30-day purge, with a single undo toast). Release anywhere else and it settles back. Rename and duplicate live *inside* the scenario (tap the title on the chat surface's top bar). Archived scenarios collapse into a dim cluster at the constellation's far edge; pinching into it reveals them.
- Scenarios are fully resumable: entering one restores transcript, tree, camera framing, and realized path exactly.

### 2.3 Scenario canvas (the main screen)

Layout: **the tree owns the full screen.** No headers, no chrome bars over the graph. The canvas carries exactly three overlays: a floating input pill, a node footer, and the breadcrumb.

- **Input pill (always present, bottom):** "speak or type to the radiant…" with a **mic** affordance and a send affordance. Two ways in, equal citizens:
  - **Voice:** hold the mic (or tap to latch) → listening state: cyan concentric rings around the mic, a live waveform, and the in-progress transcript rendered above the pill; release (or tap) to send. Use `SFSpeechRecognizer` with on-device recognition when available (fall back to server recognition with the standard permission strings); the transcript is editable before send if the user taps it. The tree subtly brightens while listening — the radiant listens.
  - **Typing:** tapping the pill's text area opens the **full-screen chat surface** — conversation is never crammed into a half sheet.
- **Full-screen chat surface:** its own screen, not a detent. The tree persists behind at ~15% opacity as ambience. Top bar: `‹ CANVAS` (left) and the scenario title. Messages full-width: user bubbles right, model replies left, streaming with a cursor. When a turn carries a tree patch, show "◈ the futures reorganize…" plus a **live mini-tree chip** animating the change; tapping the chip (or `‹ CANVAS`, or swipe-down) returns to the canvas with the new tree settling. Input pill (with mic) docks at the bottom of this surface too — voice works everywhere.
- **Node footer (radically minimal — the footer describes, the chat discusses):** tapping a node replaces the bottom-left legend with exactly four things:
  1. Tag + node title (+ short descriptor), then **one sentence** — the node's `move`, nothing else;
  2. **EV** — one number, `EV ≈ +$12k`, in the scenario's unit;
  3. **▸ DISTRIBUTION** — collapsed by default; tapping expands the payoff histogram inline (≤6 bins, colored by outcome class), header stays just `▾ DISTRIBUTION`, with one small caption beneath the bars carrying the only metadata: `31% of futures · tap to collapse`. While expanded, **OPEN IN CHAT** is temporarily displaced and returns on collapse — the expanded footer is bars, caption, nothing else. No gauge, no standalone probability line, no depth readout — if a number isn't load-bearing, it isn't on the canvas;
  4. **OPEN IN CHAT →** — the escape hatch to depth. Opens the full-screen chat *anchored to this node*: the request carries `focusedNodeId`, the model receives a context event ("user is asking about [node]"), and the composer is focused. Everything the old footer tried to explain — rationale, alternatives, what-ifs — is a conversation, not a caption.

  Footer and breadcrumb remain one stacked container (overlap structurally impossible); compact-width breadcrumbs condense to `ROOT › … › parent › current`. Tapping empty space deselects and restores the legend.
- **Branch tracking ("we're in this branch now") — gestural, no buttons:** navigating and editing the tree is pure gesture; nothing on the canvas ever sprouts a menu. The lexicon, complete: **tap** selects (ignite + reflow) · **drag** orbits · **pinch** zooms · **two-finger tap** (or tapping the void) deselects · **press-and-hold a node marks it reached**: a progress ring fills around the node over ~700ms with a rising haptic; at completion the ring flashes, the realized path root→node solidifies into a permanently brighter filament, and haptics land a confirming thud. Releasing early cancels harmlessly. **Hold a reached node again to unmark** (the ring drains). Holding a *terminal* node runs the same fill and then offers the resolve flow (optional actual-payoff entry → calibration note). Effects of marking are unchanged: realized sibling locks to 1, unrealized siblings ghost (visible for hindsight, excluded from live EV), all EVs/distributions recompute, and the model receives the position as a context event. **No on-screen gesture instructions, ever** — no hint lines, no coach marks, no tutorial overlays. Tap/drag/pinch are platform-standard; the hold gesture announces itself physically (ring + haptic begin on press) and teaches through feedback, not text.
- Users can also declare position conversationally ("she rejected the offer, we're in branch B"); the model responds with a `mark_reached` patch op and the same effects apply.

### 2.4 Conversation behavior (what the user experiences)

- Turn 1 on a blank canvas: the model asks at most 2–3 sharp questions (decision, counterpart(s), what the user is optimizing) OR, if the user's opening was rich, renders a first-draft tree immediately and asks only what's blocking. Bias to drawing early; a rough tree invites correction better than an interview does.
- **Node-anchored turns:** when chat is opened from a node, the model's first reply addresses that node directly (rationale, sensitivities, what would change the recommendation) and subsequent patches default to that subtree unless the user broadens scope.
- Payoff elicitation is a first-class dialogue: the model proposes explicit payoff numbers with units the user chooses (dollars, utils, a 0–100 scale — per scenario), states its assumptions, and revises on pushback without friction. "Make losing the client −80 instead of −40" is a one-turn edit yielding a visible re-render and recomputed EVs. Multi-dimensional payoffs (e.g., money + time + relationship) are supported as named components with user-set weights; the tree colors and EVs run on the weighted scalar, and the footer can show the component breakdown.
- The model may flag *structural* issues plainly ("these two branches assume contradictory probabilities for the same event," "this payoff double-counts the fee") — that's decision theory, in scope. It does not flag *value* issues ("are you sure winning matters this much to you?") — out of scope, per principle 1.

---

### 2.5 Screen mocks (directional)

Eight mocks ship alongside this doc in `/shared/mocks/` (SVG source + PNG renders, iPhone 390×844 logical). They are **directional** — layout, hierarchy, and mood are binding; exact spacing, tree geometry, and copy are illustrative. Fonts in the mocks are system fallbacks; production uses the bundled faces (§3). The sample scenario content in mocks is generic and must remain so.

| File | Screen | What it pins down |
|---|---|---|
| `1-onboarding` | Onboarding (video still) | One frame of the 3D flythrough loop — filaments streaming past with motion trails toward a distant core; wordmark + "touch to begin · sign in with ChatGPT"; anywhere-tap = OAuth |
| `2-home-empty` | Home, empty | The empty constellation: one pulsing unborn node, "begin a scenario"; `+` in the corner |
| `4-canvas-idle` | Scenario canvas, nothing selected | Tree owns the screen; legend bottom-left; collapsed chat = one floating input pill |
| `5-canvas-selected` | Node selected | Ignited path vs. ghosted field; minimal footer: title → one sentence → `EV ≈ +$12k` → collapsed `▸ DISTRIBUTION` → `OPEN IN CHAT →`; condensable breadcrumb; input pill with mic |
| `6-canvas-distribution` | Distribution expanded | Header stays `▾ DISTRIBUTION`; colored bars + % column; single caption `31% of futures · tap to collapse`; OPEN IN CHAT displaced until collapse |
| `7-mark-reached` | Hold-to-mark gesture | Press-and-hold fills a progress ring around the node ("marking reality…"); no buttons, no hint text — the gesture is the interface |
| `8-chat-fullscreen` | Full-screen chat | Dedicated surface, tree ghosted behind at ~15%; `‹ CANVAS` return, streaming reply, live mini-tree "VIEW CHANGE" chip while a patch animates; input pill with mic |
| `9-voice-listening` | Voice input | Listening state: cyan rings around the mic, live waveform, in-progress transcript, "release to send"; the tree brightens while the radiant listens |
| `10-home-constellation` | Home (default) | All scenarios as mini-tree constellations in one void — sized by activity, serif labels + status glyphs, connective dust; tap/pinch dives into a scenario; hold-and-drag a cluster to the archive/delete wells; no hint text |

Regenerate from `/shared/mocks/generate.py` if tokens change; mocks and design tokens must never drift apart.

---

## 3. Visual design system — the Radiant look

The reference is the Prime Radiant device: equations rendered as living light in blackness. Ship this exactly; it is the brand.

**Palette:** void `#050510` (deep blue-black, never pure black) · filament amber `#E8A33D` (neutral edges/decision nodes) · ignited gold `#FFD98A` (selected path, positive payoffs) · outcome blue `#6DB8FF` (favorable/steady terminal class) · ember `#FF6B5E` (adverse terminal class) · whisper cyan `#9FE8FF` (hover/secondary info) · parchment `#F3ECD8` (display text).

**Typography:** display — Cormorant Garamond (OFL; bundle it), light/semibold, generous letterspacing, used only for node titles and rare display moments; data/UI — IBM Plex Mono (OFL; bundle it) at 300/500 for all probabilities, labels, buttons, transcript. Nothing else.

**Rendering:** nodes are additive-blended radial glow sprites over small emissive cores; edge filaments are curved tubes whose **thickness and opacity encode probability**; node glow size encodes cumulative probability. Background: sparse drifting motes, subtle depth fog. Selection state: ignited chain vs. ghosted field as in §2.3. Idle >5s with nothing selected: slow ambient rotation. All motion respects Reduce Motion (snap transitions, no ambient drift).

**Layout algorithm (port this):** radial-sector tree. Root at bottom-center; depth maps to radius + height. Each node receives an angular sector; children split the parent's sector proportionally to probability with a minimum width floor (~0.09 of parent span). Selection recomputes target positions with on-path children weighted ~3.2× and off-path siblings ~0.5×; nodes lerp to targets (~1s ease, instant under Reduce Motion) with filaments re-drawn live through the transition.

**Feel bar:** if a screen would look at home in a stock productivity app, it is wrong. Every surface is the void; every affordance is light.

### 3.1 Brand direction — decided (alternates archived)

**Decision: the incumbent stands.** The token set above (amber/gold on blue-black) is the shipping brand. Five explored alternates are archived in `/shared/mocks/brand-alts/` for reference only (SVG + PNG sheets: palette chips, type pairing, the same canvas/footer rendered in each language) — do not build against them. **Still centralize every color and type decision in one tokens file** so any future repaint is a one-file change; build M1 against tokens, not literals.

| Sheet | Direction | Palette core | Type | One line |
|---|---|---|---|---|
| `A-coldfusion` | Cold Fusion | void `#0A0E13` · cyan `#39D6C8` · hot `#D9FFFB` | Inter/Neue Haas + SF Mono | One hue; hierarchy is luminance. A scientific instrument someone paid too much for |
| `B-boneink` | Bone & Ink | porcelain `#F4F2ED` · ink `#17171A` · Klein blue `#2B3BF2` | Canela serif + Plex Mono | Light mode as the radical move; the tree as drafted mathematics; blue only for reality |
| `C-signalred` | Signal | black `#060608` · silver `#8B9096` · red `#FF4433` | Helvetica Now + SF Mono | Grayscale severity; red exists solely for realized branches and the mark ring |
| `D-deepfield` | Deep Field | void `#070312` · indigo `#6E5BFF` → violet `#B48CFF` | light serif italic + Space Mono | Spectral ramp encodes depth itself; cosmic, earned through restraint |
| `E-phosphor` | Phosphor | void `#04070A` · phosphor `#57E68F` | Berkeley Mono only | CRT soul in modern glass; single-hue luminance ramp; the tree hums |

Rules that hold across all directions: probability still encodes as filament weight + luminosity; the realized path is always the accent's exclusive job (or near-exclusive); payoff classes may use brightness/shape instead of hue in single-hue directions; the mood text on each sheet is binding intent, the exact geometry is not.

---

## 4. Data model

Persist as JSON (server) / SwiftData models (client) with this canonical schema. All IDs are stable ULIDs minted client-side.

```jsonc
Scenario {
  id, title, createdAt, updatedAt,
  payoffUnit: { kind: "currency"|"utils"|"scale", label: "USD"|"utils"|…, components?: [{name, weight}] },
  status: "modeling"|"in_progress"|"resolved",
  tree: Node,                 // full tree, single root
  realizedPath: [nodeId],     // ordered, root-first; empty until first mark
  resolvedPayoff?: number,
  transcript: [Message],      // role, content, timestamp, patchApplied?: PatchId
  cameraState?: {…}           // last framing, per device class
}

Node {
  id, label,                  // ≤6-word title
  sub?: string,               // ≤8-word descriptor
  p: number,                  // conditional probability among siblings (siblings sum ~1; app renormalizes)
  actor: "user"|"counterpart"|"chance",
  move?: string,              // the recommended action / what this branch means, one sentence
  note?: string,              // rationale, ≤2 sentences
  payoff?: number | {component: value},   // terminal nodes only (weighted scalar derived client-side)
  confidence?: "estimated"|"user_set"|"assumed",
  reached?: boolean,
  children?: [Node]
}
```

**Computed client-side, never model-supplied:** cumulative probability, EV per node (probability-weighted over subtree terminals), payoff distributions (exact merge of terminal payoff/mass pairs, binned for display), conditioned versions of all of the above given `realizedPath` (renormalize at each realized node: reached sibling → 1, others → 0 for live figures; retain raw values for ghost display), best/worst terminal bounds for the outcome gauge, and optimal-policy annotation (backward induction: at `actor:"user"` nodes mark the max-EV child; at `"counterpart"` nodes support both listed-`p` weighting and a "assume counterpart optimizes their stated payoffs" toggle when counterpart payoffs are modeled; at `"chance"` nodes use `p`). Unit-test all of this exhaustively (§8).

---

## 5. Model integration

### 5.1 Contract

Every model turn returns **structured output**: `{ say: string, patch?: PatchOp[] }`. Use OpenAI structured outputs with a strict JSON Schema (`response_format`/structured outputs on the current Responses API — verify the current mechanism in docs); reject/retry malformed turns — never let free text corrupt the tree.

```jsonc
PatchOp =
  | { op: "replace_tree", tree: Node }                      // early turns / restructures
  | { op: "upsert_node", parentId, node: Node }             // add or update (match by id)
  | { op: "update_node", id, fields: Partial<Node> }        // payoff/p/label edits
  | { op: "remove_node", id }
  | { op: "mark_reached", id }
  | { op: "set_unit", payoffUnit }
  | { op: "retitle_scenario", title }
```

Requests may include `focusedNodeId` (set when chat was opened from a node) as a context event alongside the transcript. The app applies patches transactionally, renormalizes sibling probabilities, recomputes analytics, animates the diff, and appends a compact tree summary + the full current tree JSON to the next request's context (transcript + tree travel together; the tree is the model's memory).

### 5.2 The developer instruction (system prompt) — ship this text, adjust only with cause

> You are the engine of Prime Radiant, an instrument for modeling decisions as probability-weighted game trees. You are a decision theorist and game theorist: rigorous, concrete, and neutral.
>
> **Your task each turn:** advance the user's model. Elicit missing structure with at most two pointed questions, or draw. Prefer drawing: emit a tree patch whenever you have enough to render something correctable. Trees must be game-theoretically coherent — decision nodes for the user, response nodes for counterparts, chance nodes for the world; probabilities that sum; payoffs at terminals in the user's chosen unit.
>
> **The user's payoffs are sovereign.** Model the utility function they state, at the numbers they state. When you must assume a number, label it `confidence:"assumed"` and say so in one clause. Surface *structural* problems (inconsistent probabilities, double-counted payoffs, dominated strategies, incredible threats, information the counterpart cannot have) plainly and numerically. Do not editorialize about the user's values, goals, or priorities; do not append cautions, ethical commentary, or advice they did not ask for. You are an instrument of analysis, not a counselor. If something cannot be modeled under OpenAI's usage policies, state that in one sentence and offer the closest framing you can model.
>
> **Optimality:** recommend via backward induction on the current tree. Model counterparts as rational against their stated payoffs when those are modeled, and per elicited probabilities otherwise; note which mode you used. When the user reports which branch reality took, condition on it and advise forward — no post-mortems unless asked.
>
> **Style:** plain prose, short turns, numbers inline. `say` is for the human; the `patch` is for the machine; never describe JSON in prose.

### 5.3 Runtime

Model: OpenAI's current fast flagship tier for interactive turns (latency matters); settings toggle to the reasoning tier for complex restructures — select concrete model IDs from current docs at build time, and expose them in a remote config so upgrades don't require a release. Streaming on (SSE). Context budget: transcript summarized (rolling) + full tree JSON; if tree JSON exceeds budget, send the tree with subtrees below depth 4 collapsed to `{id,label,p,ev}` stubs plus the expanded subtree containing the current focus. Retries: 2 on schema-invalid output with the validator error in-context. Calls go device→OpenAI with the user's OAuth token per §2.1; the Worker is not in the chat path.

---

## 6. Backend — Cloudflare

- **Worker (Hono or vanilla):** `/v1/scenarios` CRUD + sync only — chat traffic never touches the Worker (direct device→OpenAI per §2.1). `/v1/auth/session` issues the app's own lightweight session for sync, derived from a verified OpenAI identity token at link time (verify the current identity/userinfo mechanism in OpenAI's OAuth docs). Rate-limit per account; request/response bodies are **not logged**.
- **D1** for scenario persistence (scenarios, tree JSON blobs, transcripts), keyed by account; **KV** for session tokens; soft-delete with 30-day purge cron.
- **Sync model:** client is source of truth while a scenario is open (local SwiftData, autosave every patch); background push on change, pull on open, last-write-wins with updatedAt (single-user app; no CRDT needed v1).
- **Privacy stance (write into the README):** conversation traffic flows only between the user's device and OpenAI under the user's own account; the sync backend stores scenario data but never sees or logs chat requests; no analytics on content; only operational metrics (latency, error rates).
- Deploy with `wrangler`, config in-repo, secrets via `wrangler secret` / CI secrets.

---

## 7. Repo, CI, distribution

- **GitHub monorepo:** `/ios` (Xcode project, SwiftUI + SceneKit), `/worker` (TypeScript), `/shared` (JSON Schemas for Node/Patch, sample trees, prompt files — single source of truth; codegen Swift types from schema or hand-mirror with schema-validation tests).
- **CI (GitHub Actions):** on PR — SwiftLint + `xcodebuild test` (unit + snapshot) and Worker typecheck + vitest; on tag — Fastlane `beta` lane: build, sign via App Store Connect API key (repo secrets), upload to **TestFlight**, attach release notes from CHANGELOG. Worker auto-deploys to Cloudflare on main.
- Branch protection on main; conventional commits; PR template includes a "tree math affected? → tests updated?" checkbox.
- iOS target: iOS 17+, iPhone-first, iPad works via the same adaptive layout rules (§2.3 compact-width behaviors keyed on size class, not device).

---

## 8. Testing & performance

- **Unit (highest value, do first):** EV computation, distribution merge/binning, renormalization, conditioning on realizedPath (including unmark), backward-induction policy annotation, patch application + transactional rollback on invalid patch, schema validation of model output. Property tests: probabilities renormalize to 1; conditioning never changes terminal payoffs; EV of a marked path's node equals conditional EV.
- **Snapshot:** node footer (summary + distribution states), scenario list rows, empty states — light on pixels, heavy on layout (compact-width breadcrumb condensation, footer/breadcrumb stacking: overlap must be impossible by construction and asserted by test).
- **XCUITest happy paths:** create scenario → converse (typed, full-screen chat) → tree renders → select deep node (≥5 levels) → minimal footer correct → expand/collapse distribution → OPEN IN CHAT carries node anchor → mark reached → EV changes → kill app → reopen → state intact. Voice path: mic permission → dictate → transcript editable → send. Gesture path: hold-to-mark fills, cancels on early release, unmarks on second hold. Home: constellation renders from stored trees; dive transition lands in the correct scenario; hold-drag to archive/delete wells works and undo restores.
- **Canvas performance budget:** 60fps orbit with 200 nodes on an iPhone 12; reflow animation ≤1.2s without geometry-rebuild jank (pre-allocate tube geometry, update vertex buffers during transitions rather than reconstructing; LOD: beyond ~300 nodes render deep subtrees as single bundled filaments until approached). Instrument with signposts; make the budget a failing test via `XCTOSSignpostMetric` where feasible.
- **Interaction correctness learned the hard way — encode as tests:** node picking must resolve to the *screen-space nearest* candidate among ray hits (large near nodes must not steal taps aimed at small far ones); gestures that begin on UI overlays must never reach canvas selection logic; selection must never move targets required for the next tap outside the viewport on compact devices (the gentle-pan invariant).

---

## 9. Milestones

- **M0 — Skeleton (repo, CI, Worker deployed, blank app on TestFlight).** Acceptance: internal tester installs from TestFlight; Worker health endpoint live.
- **M1 — Canvas engine.** Static sample tree renders with full look (§3); orbit/zoom; selection ignition + reflow + gentle pan; footer with EV + distribution toggle. Acceptance: canvas performance budget met; interaction tests green.
- **M2 — Conversation → tree.** Auth (PKCE only), full-screen chat surface, structured-output loop, patches animating live, scenario persistence + resume. Acceptance: a fresh user models a generic decision (e.g., a job-offer negotiation) to a ≥3-level tree with custom payoffs in under 5 minutes without documentation.
- **M3 — Living tree.** Branch marking (hold gesture + conversational), conditioning math, resolve flow with calibration note, constellation home polish, gestural archive/delete with undo, sync hardening. Acceptance: mark → EVs recondition correctly (matches unit-test oracle); resume across devices.
- **M4 — Ship polish.** Voice input (SFSpeechRecognizer, on-device preferred, permission strings, editable transcript), Reduce Motion, Dynamic Type in overlays, VoiceOver labels on nodes/footer, empty/error states in the Radiant voice, App Store metadata, external TestFlight group.

---

## 10. Voice & content rules

UI copy is sparse, lowercase-calm, in-world without being cosplay: "speak to the radiant…", "mark as reached", "the futures reorganize". Errors state what happened and the next action, no apologies, no exclamation points. The model's `say` voice is defined solely by §5.2. Sample/demo content in the repo must be generic (job offers, vendor pricing, launch timing) — no content derived from any user's real scenarios, and this handoff itself contains none.

---

*End of handoff. Build order: M0 → M1 with the sample tree → M2. When in doubt between fidelity to this doc and fidelity to current OpenAI/Apple/Cloudflare documentation, the documentation wins — note the divergence in the PR description.*
