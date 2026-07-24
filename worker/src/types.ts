export interface Env {
  /** D1: scenario persistence (database_name: prime-radiant). */
  DB: D1Database;
  /** KV: session tokens — `session:<token>` -> SessionRecord JSON, with TTL. */
  SESSIONS: KVNamespace;
  /** Optional override for the per-account rate limit (requests/minute). */
  RATE_LIMIT_PER_MINUTE?: string;
}

/** Result of verifying an OpenAI identity token at account-link time. */
export interface VerifiedIdentity {
  /** Stable OpenAI account identifier; sole tenancy key for sync data. */
  accountId: string;
}

/**
 * Pluggable verifier for the OpenAI identity token presented at link time.
 *
 * TODO(M2): implement the production verifier against OpenAI's *current* OAuth
 * identity/userinfo mechanism, verified against official OpenAI docs at build
 * time (docs/handoff.md §2.1/§6 — "docs win over this paragraph"). Do NOT
 * assume endpoint URLs, token formats, or claim names from memory; this repo
 * deliberately ships only a rejecting stub until that verification happens.
 */
export type OpenAIIdentityVerifier = (
  identityToken: string,
  env: Env,
) => Promise<VerifiedIdentity>;

/** Stored in KV under `session:<token>`. */
export interface SessionRecord {
  accountId: string;
  issuedAt: string;
  expiresAt: string;
}

export interface ScenarioMetadata {
  id: string;
  title: string;
  status: string;
  createdAt: string;
  updatedAt: string;
}
