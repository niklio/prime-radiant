# Prime Radiant — Implementation Notes: Motion, Gesture, and World Dynamics

Companion to `prime-radiant-handoff.md` and the nine mocks in `shared/mocks/`. The mocks are stills of a moving instrument; this doc is everything the stills can't show. Where this conflicts with the main spec, the main spec wins — flag the divergence.

---

## 1. The world model (get this right first)

- **One void, one shell, one camera.** All content — every scenario's tree, every home constellation — lives at persistent coordinates on a single spherical *coordinate shell* (reference R≈280 layout units) floating in a nebula that surrounds the camera on all sides. There is **no ground, no horizon, no sky, no up**. The user is never *on* anything; they fly *through*.
- **Two reference camera states, one rig:** home (distance ≈1.5R from shell, tilt ≈0.22rad) and canvas (close, ≈0.4R, tilt ≈0.58rad). Every screen transition between home and a scenario is a **continuous camera flight** between these states aimed at the scenario's shell coordinates — no scene swaps, no crossfades, ever. SceneKit: one scene, one `SCNCamera`, animate the rig.
- **Depth cues, in priority order:** (1) perspective foreshortening from the shell arrangement (near nodes ~1.4× larger than far at equal tree depth — measured reference in the mocks); (2) depth dimming, `opacity ∝ clamp(scale^1.9, 0.34, 1)`; (3) **depth-of-field** — nodes with projected scale <0.88 blur softly (SceneKit camera DoF with focus at selection distance, or per-node gaussian at LOD); (4) edge widths scale with the mean of their endpoints' depth factors; (5) frame-edge vignette. The nebula itself never clips or bands — cloud density varies smoothly.
- **The nebula is alive but glacial:** turbulence fields drift imperceptibly (full-texture migration over ~3–5 min); dark rifts wander. Parallax: nebula layers move at ~0.15×/0.35×/0.6× of camera motion so orbiting reveals volume. Under Reduce Motion: static nebula, no drift.

## 2. Gesture lexicon (complete; nothing else exists)

| Gesture | Context | Effect |
|---|---|---|
| tap node | canvas | select: ignite + reflow + capsule loads context |
| tap void | canvas | deselect: reflow back, capsule → idle |
| drag | canvas/home | swing the camera through the void around the shell |
| pinch | canvas/home | zoom (continuous; pinching out far enough on canvas begins the flight home; pinching into a home cluster begins the dive) |
| press-and-hold node | canvas | mark-reached ring fills (~700ms); release early = cancel; hold a reached node = unmark; hold a terminal = resolve flow |
| tap cluster | home | dive (camera flight to canvas state at that scenario's coordinates) |
| press-and-hold cluster | home | lifts under finger (haptic); ARCHIVE / DELETE wells fade in at bottom edge; drag in to act (delete soft, single undo toast); release elsewhere = settle back |
| tap ribbon label | canvas | jump selection to that ancestor (full ignite + reflow) |
| horizontal drag on ribbon | canvas | scrolls the path with momentum; edge fades persist at every position |
| tap capsule text area | anywhere | opens full-screen chat (carries any typed text + `focusedNodeId` anchor) |
| swipe down | chat | return to canvas (chat collapses into the capsule) |
| partial swipe down + hold | chat | **peek**: chat slides off to reveal live canvas at full brightness; release snaps back |
| hold mic / tap-latch mic | anywhere | voice input |
| tap EV / ▸ | capsule | expand/collapse the luminous ridge |
| tap unborn node | empty home | create first scenario |

**Doctrine: no on-screen gesture instruction of any kind** — no hints, coach marks, tutorials, or labels. Feedback teaches: the hold gesture announces itself through the ring + haptic beginning on finger-down.

## 3. Motion design (timings are targets; feel > numbers)

- **Selection reflow:** on-path sectors bloom to ~3.2× angular weight, siblings compress to ~0.5×; nodes lerp ~0.9–1.1s ease-in-out with chords redrawn live every frame (pre-allocate geometry; never rebuild per frame). Simultaneously the path ignites: gold sweeps root→node along the chords (~350ms, slightly ahead of the reflow), under-glow fades in. **Gentle-pan invariant:** camera may pan (never zoom) on selection, sized so the selected node and its children stay in-viewport; deselect pans back.
- **Hold-to-mark:** ring fills over ~700ms with a rising haptic ramp; at completion: ring flash, single strong haptic, realized path solidifies (permanent brighter filament, ~250ms sweep), unrealized siblings ghost down over ~400ms, EVs recount visibly in the capsule (number ticks to new value, ~300ms). Early release: ring drains fast (~150ms), no haptic thud.
- **Dive (home ↔ canvas):** ~900ms camera flight, ease-in-out, curvature continuous; target cluster's nodes sharpen out of depth-of-field as approached while other clusters blur/dim past the frame; nebula parallax sells the motion. Reverse identical. During flight, UI chrome (labels, capsule) crossfades at the endpoints only.
- **Chat enter:** capsule morphs upward into the full-screen surface (~350ms); tree settles to 15% ghost. **Patch arrival in chat:** ghost brightens 15%→35%, reorganization animates behind the messages, "◈ the futures reorganize…" status line, settle back over ~600ms after the animation completes. **Peek:** chat translates with the finger 1:1; past ~40% travel, releasing returns to canvas; under that, spring-snap back (~250ms).
- **Distribution ridge:** expands inside the capsule (~300ms): capsule grows, ridge line *draws* left→right (~400ms) with the fill rising beneath it; μ meanline fades in last. Collapse reverses fast (~200ms).
- **Voice listening:** concentric rings around the mic pulse outward (~1.6s period); the whole tree brightens ~15%; live waveform; transcript assembles above the capsule and is tap-to-edit before send.
- **Composing:** capsule grows with content; context header compresses to the single anchor line over ~200ms.
- **Idle (>5s, nothing selected):** slow ambient camera drift (fraction of a degree/s).
- **Empty-home unborn node:** slow pulse (~2.4s period), glow radius ±20%.
- **Reduce Motion:** all of the above become instant state changes (no lerps, no drift, no pulse, static nebula); haptics unchanged; DoF still applies (it's depth, not motion).

## 4. States, statuses, and copy

- **Status is luminance, not iconography:** resolved constellations render at ~42% with dimmed labels. No glyphs, timestamps, or status text anywhere on home; each cluster carries exactly one serif title line.
- **Context-aware composer placeholders (the placeholder is state, never instruction):** idle canvas → `describe the decision…`; node selected → `ask about this branch…`; mid-thread chat → `…`. Anchor chip (`◉ <node> ✕`) appears in the chat composer when node-anchored; `✕` clears the anchor.
- **Composer icons:** mic and send are one family — mic ~10×15 at 1.2 stroke; send is a **filled cyan disc** (r12) with a void-colored drawn arrow at 1.9 stroke. Send disc brightens slightly when there's content.
- **Ignited path is a clean straight highlight** — gold chord + soft under-glow, nothing else. No ticks, no numerals, no ornament on edges. Etched instrument language (graduation ticks) exists **only** on the ridge's payoff axis.
- Onboarding is the flythrough video (produced from this same engine — script a camera path through a large generated tree); one line over it: `touch to begin`. Anywhere-tap starts OAuth.

## 5. Haptics map

light tick: node select · soft double: deselect · ramp: mark-hold filling · strong thud: mark complete · light: ribbon jump · medium: cluster lift · success pattern: scenario resolve · none: scrolling, zooming, chat.

## 6. Performance & correctness (encode as tests)

- 60fps orbit at 200 nodes on iPhone 12; reflow ≤1.2s without geometry-rebuild jank (pre-allocated buffers, vertex updates only).
- Picking is **screen-space nearest** among ray hits; gestures beginning on UI overlays never reach canvas logic.
- Ribbon: tap selects the tapped ancestor; overlap-free at any depth (measure rendered label gaps ≥3px in a snapshot test — this exact bug shipped in a mock once); edge fades at every scroll position.
- Capsule/ribbon are one stacked container — overlap structurally impossible.
- Text overflow audit on every screen (nothing outside safe area except the ribbon's intentional off-edge run).
- Depth verification test: render the reference tree, assert near/far node-size ratio ≥1.3 and DoF applied below the scale threshold — keep the mocks' measured feel from drifting.

*The generators in `shared/mocks/` are executable ground truth for layout math (sphere projection, orbital sectors, ridge geometry) — port constants from `generate.py`, not from eyeballing the PNGs.*
