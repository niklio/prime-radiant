/**
 * Prime Radiant sync backend.
 *
 * Scope: /v1/scenarios CRUD + sync and /v1/auth/session ONLY. Chat traffic
 * never touches this Worker (device → OpenAI directly; docs/handoff.md §2.1).
 *
 * Privacy: request/response bodies are NEVER logged anywhere in this file —
 * do not add console.log of scenario content or tokens. Operational metrics
 * only (Workers observability captures status/latency, not bodies).
 */
import { Hono } from "hono";
import type { MiddlewareHandler } from "hono";
import {
  IdentityVerificationError,
  VerifierNotConfiguredError,
  createSession,
  lookupSession,
} from "./auth";
import { DEFAULT_LIMIT_PER_MINUTE, checkRateLimit } from "./ratelimit";
import { PURGE_AFTER_DAYS } from "./purge";
import type { Env, OpenAIIdentityVerifier, ScenarioMetadata } from "./types";

export const VERSION = "0.1.0";

const ULID_RE = /^[0-7][0-9A-HJKMNP-TV-Z]{25}$/;
const STATUSES = new Set(["modeling", "in_progress", "resolved"]);
/** Cap on a serialized scenario (tree + transcript blob). */
const MAX_BODY_BYTES = 1_000_000;

type AppEnv = { Bindings: Env; Variables: { accountId: string } };

interface ScenarioRow {
  id: string;
  account_id: string;
  title: string;
  status: string;
  updated_at: string;
  created_at: string;
  deleted_at: string | null;
  body: string;
}

function metadata(row: ScenarioRow): ScenarioMetadata {
  return {
    id: row.id,
    title: row.title,
    status: row.status,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

/** Minimal structural validation; full schema validation is the client's job. */
function validateScenario(s: unknown, expectedId: string): string | null {
  if (typeof s !== "object" || s === null || Array.isArray(s)) {
    return "body must be a scenario object";
  }
  const sc = s as Record<string, unknown>;
  if (sc.id !== expectedId) return "body id must match URL id";
  if (typeof sc.title !== "string" || sc.title.length === 0) {
    return "title required";
  }
  if (typeof sc.status !== "string" || !STATUSES.has(sc.status)) {
    return "status must be one of modeling|in_progress|resolved";
  }
  for (const field of ["createdAt", "updatedAt"] as const) {
    const v = sc[field];
    if (typeof v !== "string" || Number.isNaN(Date.parse(v))) {
      return `${field} must be an ISO-8601 timestamp`;
    }
  }
  if (typeof sc.tree !== "object" || sc.tree === null) return "tree required";
  return null;
}

export function createApp(verifier: OpenAIIdentityVerifier): Hono<AppEnv> {
  const app = new Hono<AppEnv>();

  // ---- Unauthenticated routes (the only two). -------------------------------

  app.get("/v1/health", (c) => c.json({ ok: true, version: VERSION }));

  /**
   * Issues the app's own lightweight session token for sync, derived from a
   * verified OpenAI identity token presented at account-link time.
   * Verification is pluggable (see OpenAIIdentityVerifier in types.ts); the
   * production stub rejects with 503 until the mechanism is verified against
   * current OpenAI docs at M2.
   */
  app.post("/v1/auth/session", async (c) => {
    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      return c.json({ error: "invalid JSON" }, 400);
    }
    const identityToken = (body as Record<string, unknown> | null)
      ?.identityToken;
    if (typeof identityToken !== "string" || identityToken.length === 0) {
      return c.json({ error: "identityToken required" }, 400);
    }
    try {
      const { accountId } = await verifier(identityToken, c.env);
      const { token, record } = await createSession(c.env, accountId);
      return c.json({ token, expiresAt: record.expiresAt });
    } catch (err) {
      if (err instanceof VerifierNotConfiguredError) {
        return c.json({ error: "identity verification not configured" }, 503);
      }
      if (err instanceof IdentityVerificationError) {
        return c.json({ error: "identity token rejected" }, 401);
      }
      throw err;
    }
  });

  // ---- Session auth + per-account rate limit for everything else. -----------

  const requireSession: MiddlewareHandler<AppEnv> = async (c, next) => {
    const authz = c.req.header("Authorization") ?? "";
    if (!authz.startsWith("Bearer ")) {
      return c.json({ error: "unauthorized" }, 401);
    }
    const session = await lookupSession(c.env, authz.slice("Bearer ".length));
    if (session === null) {
      return c.json({ error: "unauthorized" }, 401);
    }
    const limit = Number(c.env.RATE_LIMIT_PER_MINUTE) || DEFAULT_LIMIT_PER_MINUTE;
    if (!checkRateLimit(session.accountId, limit)) {
      return c.json({ error: "rate limit exceeded" }, 429);
    }
    c.set("accountId", session.accountId);
    await next();
  };
  app.use("/v1/scenarios", requireSession);
  app.use("/v1/scenarios/*", requireSession);

  // ---- Scenario CRUD + sync, all scoped to the authenticated account. -------

  app.get("/v1/scenarios", async (c) => {
    const { results } = await c.env.DB.prepare(
      `SELECT id, account_id, title, status, updated_at, created_at, deleted_at, body
         FROM scenarios
        WHERE account_id = ? AND deleted_at IS NULL
        ORDER BY updated_at DESC`,
    )
      .bind(c.get("accountId"))
      .all<ScenarioRow>();
    return c.json({ scenarios: results.map(metadata) });
  });

  app.get("/v1/scenarios/:id", async (c) => {
    const row = await c.env.DB.prepare(
      "SELECT body FROM scenarios WHERE id = ? AND account_id = ? AND deleted_at IS NULL",
    )
      .bind(c.req.param("id"), c.get("accountId"))
      .first<{ body: string }>();
    if (row === null) return c.json({ error: "not found" }, 404);
    return c.newResponse(row.body, 200, {
      "Content-Type": "application/json",
    });
  });

  // Upsert; last-write-wins on updatedAt. Stale writes → 409 with the server
  // copy's updatedAt so the client can pull and re-merge.
  app.put("/v1/scenarios/:id", async (c) => {
    const id = c.req.param("id");
    if (!ULID_RE.test(id)) return c.json({ error: "id must be a ULID" }, 400);

    const raw = await c.req.text();
    if (raw.length > MAX_BODY_BYTES) {
      return c.json({ error: "scenario too large" }, 413);
    }
    let scenario: unknown;
    try {
      scenario = JSON.parse(raw);
    } catch {
      return c.json({ error: "invalid JSON" }, 400);
    }
    const invalid = validateScenario(scenario, id);
    if (invalid !== null) return c.json({ error: invalid }, 400);
    const s = scenario as {
      title: string;
      status: string;
      createdAt: string;
      updatedAt: string;
    };

    const accountId = c.get("accountId");
    const existing = await c.env.DB.prepare(
      "SELECT account_id, updated_at, deleted_at FROM scenarios WHERE id = ?",
    )
      .bind(id)
      .first<Pick<ScenarioRow, "account_id" | "updated_at" | "deleted_at">>();

    if (existing !== null) {
      // ULIDs are client-minted; a cross-account id collision is either a bug
      // or hostile. Never allow one account to overwrite another's row.
      if (existing.account_id !== accountId) {
        return c.json({ error: "forbidden" }, 403);
      }
      if (Date.parse(s.updatedAt) < Date.parse(existing.updated_at)) {
        return c.json(
          { error: "stale write", serverUpdatedAt: existing.updated_at },
          409,
        );
      }
    }

    // A successful upsert always revives a soft-deleted row (the write is
    // newer than the delete under last-write-wins).
    await c.env.DB.prepare(
      `INSERT INTO scenarios (id, account_id, title, status, updated_at, created_at, deleted_at, body)
       VALUES (?, ?, ?, ?, ?, ?, NULL, ?)
       ON CONFLICT(id) DO UPDATE SET
         title = excluded.title,
         status = excluded.status,
         updated_at = excluded.updated_at,
         deleted_at = NULL,
         body = excluded.body`,
    )
      .bind(id, accountId, s.title, s.status, s.updatedAt, s.createdAt, raw)
      .run();
    return c.json({ ok: true, id, updatedAt: s.updatedAt });
  });

  // Soft delete; purged by cron after 30 days. Idempotent.
  app.delete("/v1/scenarios/:id", async (c) => {
    const id = c.req.param("id");
    const accountId = c.get("accountId");
    const row = await c.env.DB.prepare(
      "SELECT deleted_at FROM scenarios WHERE id = ? AND account_id = ?",
    )
      .bind(id, accountId)
      .first<{ deleted_at: string | null }>();
    if (row === null) return c.json({ error: "not found" }, 404);

    const deletedAt = row.deleted_at ?? new Date().toISOString();
    if (row.deleted_at === null) {
      await c.env.DB.prepare(
        "UPDATE scenarios SET deleted_at = ? WHERE id = ? AND account_id = ?",
      )
        .bind(deletedAt, id, accountId)
        .run();
    }
    return c.json({ ok: true, deletedAt, purgeAfterDays: PURGE_AFTER_DAYS });
  });

  // Undo for the delete toast.
  app.post("/v1/scenarios/:id/restore", async (c) => {
    const id = c.req.param("id");
    const accountId = c.get("accountId");
    const result = await c.env.DB.prepare(
      "UPDATE scenarios SET deleted_at = NULL WHERE id = ? AND account_id = ? AND deleted_at IS NOT NULL",
    )
      .bind(id, accountId)
      .run();
    if ((result.meta.changes ?? 0) === 0) {
      return c.json({ error: "not found" }, 404);
    }
    const row = await c.env.DB.prepare(
      "SELECT id, account_id, title, status, updated_at, created_at, deleted_at, body FROM scenarios WHERE id = ?",
    )
      .bind(id)
      .first<ScenarioRow>();
    return c.json({ ok: true, scenario: row === null ? null : metadata(row) });
  });

  app.notFound((c) => c.json({ error: "not found" }, 404));

  return app;
}
