import type { Env, OpenAIIdentityVerifier, SessionRecord } from "./types";

/** Session lifetime: 30 days. KV TTL enforces expiry server-side. */
export const SESSION_TTL_SECONDS = 30 * 24 * 60 * 60;

export class VerifierNotConfiguredError extends Error {
  constructor() {
    super("OpenAI identity verification is not configured");
    this.name = "VerifierNotConfiguredError";
  }
}

export class IdentityVerificationError extends Error {
  constructor(message = "identity token rejected") {
    super(message);
    this.name = "IdentityVerificationError";
  }
}

/**
 * Production verifier — deliberately a rejecting stub.
 *
 * TODO(M2): replace with real verification of the OpenAI identity token using
 * OpenAI's current user-facing OAuth identity/userinfo mechanism, verified
 * against current official OpenAI documentation (docs/handoff.md §2.1/§6).
 * Endpoints/claims are intentionally NOT guessed here: shipping an invented
 * endpoint would be worse than rejecting. Until configured, /v1/auth/session
 * returns 503 in production; tests exercise the flow with a fake verifier.
 */
export const productionVerifier: OpenAIIdentityVerifier = async (
  _identityToken,
  _env,
) => {
  throw new VerifierNotConfiguredError();
};

export function sessionKey(token: string): string {
  return `session:${token}`;
}

/** 256-bit random, hex-encoded, URL-safe opaque bearer token. */
export function generateSessionToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

export async function createSession(
  env: Env,
  accountId: string,
): Promise<{ token: string; record: SessionRecord }> {
  const token = generateSessionToken();
  const now = Date.now();
  const record: SessionRecord = {
    accountId,
    issuedAt: new Date(now).toISOString(),
    expiresAt: new Date(now + SESSION_TTL_SECONDS * 1000).toISOString(),
  };
  await env.SESSIONS.put(sessionKey(token), JSON.stringify(record), {
    expirationTtl: SESSION_TTL_SECONDS,
  });
  return { token, record };
}

export async function lookupSession(
  env: Env,
  token: string,
): Promise<SessionRecord | null> {
  const raw = await env.SESSIONS.get(sessionKey(token));
  if (raw === null) return null;
  try {
    return JSON.parse(raw) as SessionRecord;
  } catch {
    return null;
  }
}
