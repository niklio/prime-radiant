# Changelog

Release notes for TestFlight builds are cut from the Unreleased section on tag.

## Unreleased

- Monorepo skeleton: shared JSON Schemas (Node/Scenario/PatchOp/ModelTurn), design tokens,
  system prompt, sample scenario, screen mocks.
- Cloudflare Worker sync backend deployed (scenarios CRUD, LWW sync, soft-delete + purge
  cron, session auth scaffold) — chat traffic never touches it.
- PrimeRadiantCore: tree analytics (EV, distributions, conditioning), backward-induction
  policy annotation, transactional patching, model-turn validation. 55 tests.
