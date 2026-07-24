import {
  createExecutionContext,
  env,
  waitOnExecutionContext,
} from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { createApp, VERSION } from "../src/app";
import {
  IdentityVerificationError,
  productionVerifier,
  sessionKey,
} from "../src/auth";
import { purgeSoftDeleted } from "../src/purge";
import { resetRateLimiter } from "../src/ratelimit";
import type { OpenAIIdentityVerifier } from "../src/types";

// ---- Harness ---------------------------------------------------------------

const fakeVerifier: OpenAIIdentityVerifier = async (token) => {
  if (token === "valid-openai-identity-token") {
    return { accountId: "acct_fake_123" };
  }
  throw new IdentityVerificationError();
};

const app = createApp(fakeVerifier);

async function request(
  path: string,
  init: RequestInit = {},
): Promise<Response> {
  const ctx = createExecutionContext();
  const res = await app.fetch(
    new Request(`https://sync.test${path}`, init),
    env,
    ctx,
  );
  await waitOnExecutionContext(ctx);
  return res;
}

const TOKEN_A = "session-token-account-a";
const TOKEN_B = "session-token-account-b";
const ACCOUNT_A = "acct_a";
const ACCOUNT_B = "acct_b";

async function seedSessions(): Promise<void> {
  const now = new Date().toISOString();
  for (const [token, accountId] of [
    [TOKEN_A, ACCOUNT_A],
    [TOKEN_B, ACCOUNT_B],
  ] as const) {
    await env.SESSIONS.put(
      sessionKey(token),
      JSON.stringify({ accountId, issuedAt: now, expiresAt: now }),
    );
  }
}

const SCENARIO_ID = "01ARZ3NDEKTSV4RRFFQ69G5FAV";
const NODE_ID = "01ARZ3NDEKTSV4RRFFQ69G5FA0";

function makeScenario(overrides: Record<string, unknown> = {}) {
  return {
    id: SCENARIO_ID,
    title: "job offer negotiation",
    createdAt: "2026-07-01T00:00:00.000Z",
    updatedAt: "2026-07-02T00:00:00.000Z",
    payoffUnit: { kind: "currency", label: "USD" },
    status: "modeling",
    tree: { id: NODE_ID, label: "accept or counter", p: 1, actor: "user" },
    realizedPath: [],
    transcript: [],
    ...overrides,
  };
}

function authed(token: string, init: RequestInit = {}): RequestInit {
  return {
    ...init,
    headers: { Authorization: `Bearer ${token}`, ...(init.headers ?? {}) },
  };
}

async function putScenario(
  token: string,
  scenario: Record<string, unknown>,
): Promise<Response> {
  return request(
    `/v1/scenarios/${scenario.id as string}`,
    authed(token, { method: "PUT", body: JSON.stringify(scenario) }),
  );
}

beforeEach(async () => {
  resetRateLimiter();
  await seedSessions();
  // Storage is not isolated per-test in this pool config; start each test
  // from an empty scenarios table.
  await env.DB.prepare("DELETE FROM scenarios").run();
});

// ---- Tests -----------------------------------------------------------------

describe("health", () => {
  it("responds without auth", async () => {
    const res = await request("/v1/health");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, version: VERSION });
  });
});

describe("session issuance", () => {
  it("issues a session token for a verified identity token", async () => {
    const res = await request("/v1/auth/session", {
      method: "POST",
      body: JSON.stringify({ identityToken: "valid-openai-identity-token" }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { token: string; expiresAt: string };
    expect(body.token).toMatch(/^[0-9a-f]{64}$/);

    // Token is live in KV and usable against an authed route.
    const stored = await env.SESSIONS.get(sessionKey(body.token));
    expect(JSON.parse(stored!)).toMatchObject({ accountId: "acct_fake_123" });
    const list = await request("/v1/scenarios", authed(body.token));
    expect(list.status).toBe(200);
  });

  it("rejects an invalid identity token with 401", async () => {
    const res = await request("/v1/auth/session", {
      method: "POST",
      body: JSON.stringify({ identityToken: "nope" }),
    });
    expect(res.status).toBe(401);
  });

  it("rejects missing identityToken with 400", async () => {
    const res = await request("/v1/auth/session", {
      method: "POST",
      body: JSON.stringify({}),
    });
    expect(res.status).toBe(400);
  });

  it("production verifier stub rejects with 503 until configured", async () => {
    const prodApp = createApp(productionVerifier);
    const ctx = createExecutionContext();
    const res = await prodApp.fetch(
      new Request("https://sync.test/v1/auth/session", {
        method: "POST",
        body: JSON.stringify({ identityToken: "anything" }),
      }),
      env,
      ctx,
    );
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(503);
  });
});

describe("auth middleware", () => {
  it.each([
    ["no header", {}],
    ["bad token", { headers: { Authorization: "Bearer bogus" } }],
    ["non-bearer", { headers: { Authorization: "Basic abc" } }],
  ])("rejects %s with 401", async (_name, init) => {
    const res = await request("/v1/scenarios", init as RequestInit);
    expect(res.status).toBe(401);
  });
});

describe("scenario CRUD + sync", () => {
  it("upserts and reads back a scenario", async () => {
    const scenario = makeScenario();
    const put = await putScenario(TOKEN_A, scenario);
    expect(put.status).toBe(200);

    const get = await request(`/v1/scenarios/${SCENARIO_ID}`, authed(TOKEN_A));
    expect(get.status).toBe(200);
    expect(await get.json()).toEqual(scenario);

    const list = await request("/v1/scenarios", authed(TOKEN_A));
    const { scenarios } = (await list.json()) as { scenarios: unknown[] };
    expect(scenarios).toEqual([
      {
        id: SCENARIO_ID,
        title: "job offer negotiation",
        status: "modeling",
        createdAt: "2026-07-01T00:00:00.000Z",
        updatedAt: "2026-07-02T00:00:00.000Z",
      },
    ]);
  });

  it("last-write-wins: newer write lands, stale write gets 409 + server updatedAt", async () => {
    await putScenario(TOKEN_A, makeScenario());
    const newer = await putScenario(
      TOKEN_A,
      makeScenario({ title: "renegotiated", updatedAt: "2026-07-03T00:00:00.000Z" }),
    );
    expect(newer.status).toBe(200);

    const stale = await putScenario(
      TOKEN_A,
      makeScenario({ title: "old edit", updatedAt: "2026-07-01T12:00:00.000Z" }),
    );
    expect(stale.status).toBe(409);
    expect(await stale.json()).toEqual({
      error: "stale write",
      serverUpdatedAt: "2026-07-03T00:00:00.000Z",
    });

    // Server copy unchanged by the stale write.
    const get = await request(`/v1/scenarios/${SCENARIO_ID}`, authed(TOKEN_A));
    expect(((await get.json()) as { title: string }).title).toBe("renegotiated");
  });

  it("rejects a malformed scenario body with 400", async () => {
    const res = await putScenario(TOKEN_A, makeScenario({ status: "bogus" }));
    expect(res.status).toBe(400);
  });

  it("soft delete hides the scenario; restore brings it back", async () => {
    await putScenario(TOKEN_A, makeScenario());

    const del = await request(
      `/v1/scenarios/${SCENARIO_ID}`,
      authed(TOKEN_A, { method: "DELETE" }),
    );
    expect(del.status).toBe(200);
    expect(await del.json()).toMatchObject({ ok: true, purgeAfterDays: 30 });

    expect(
      (await request(`/v1/scenarios/${SCENARIO_ID}`, authed(TOKEN_A))).status,
    ).toBe(404);
    const list = (await (
      await request("/v1/scenarios", authed(TOKEN_A))
    ).json()) as { scenarios: unknown[] };
    expect(list.scenarios).toEqual([]);

    const restore = await request(
      `/v1/scenarios/${SCENARIO_ID}/restore`,
      authed(TOKEN_A, { method: "POST" }),
    );
    expect(restore.status).toBe(200);
    expect(
      (await request(`/v1/scenarios/${SCENARIO_ID}`, authed(TOKEN_A))).status,
    ).toBe(200);
  });

  it("restore of a never-deleted or unknown scenario is 404", async () => {
    await putScenario(TOKEN_A, makeScenario());
    const notDeleted = await request(
      `/v1/scenarios/${SCENARIO_ID}/restore`,
      authed(TOKEN_A, { method: "POST" }),
    );
    expect(notDeleted.status).toBe(404);
  });

  it("purge cron removes soft-deleted rows older than 30 days only", async () => {
    const now = new Date("2026-07-24T00:00:00.000Z");
    const old = new Date("2026-06-01T00:00:00.000Z").toISOString(); // 53 days
    const recent = new Date("2026-07-20T00:00:00.000Z").toISOString(); // 4 days
    const insert = env.DB.prepare(
      `INSERT INTO scenarios (id, account_id, title, status, updated_at, created_at, deleted_at, body)
       VALUES (?, ?, 't', 'modeling', ?, ?, ?, '{}')`,
    );
    const oldId = "01ARZ3NDEKTSV4RRFFQ69G5FB1";
    const recentId = "01ARZ3NDEKTSV4RRFFQ69G5FB2";
    const liveId = "01ARZ3NDEKTSV4RRFFQ69G5FB3";
    await insert.bind(oldId, ACCOUNT_A, old, old, old).run();
    await insert.bind(recentId, ACCOUNT_A, recent, recent, recent).run();
    await insert.bind(liveId, ACCOUNT_A, recent, recent, null).run();

    const purged = await purgeSoftDeleted(env, now);
    expect(purged).toBe(1);

    const remaining = await env.DB.prepare(
      "SELECT id FROM scenarios ORDER BY id",
    ).all<{ id: string }>();
    expect(remaining.results.map((r) => r.id)).toEqual([recentId, liveId].sort());
  });

  it("account isolation: account B cannot see or touch account A's scenario", async () => {
    await putScenario(TOKEN_A, makeScenario());

    const get = await request(`/v1/scenarios/${SCENARIO_ID}`, authed(TOKEN_B));
    expect(get.status).toBe(404);

    const list = (await (
      await request("/v1/scenarios", authed(TOKEN_B))
    ).json()) as { scenarios: unknown[] };
    expect(list.scenarios).toEqual([]);

    const del = await request(
      `/v1/scenarios/${SCENARIO_ID}`,
      authed(TOKEN_B, { method: "DELETE" }),
    );
    expect(del.status).toBe(404);

    // B cannot overwrite A's row by claiming the same id.
    const overwrite = await putScenario(
      TOKEN_B,
      makeScenario({ updatedAt: "2027-01-01T00:00:00.000Z" }),
    );
    expect(overwrite.status).toBe(403);
    const stillA = await request(
      `/v1/scenarios/${SCENARIO_ID}`,
      authed(TOKEN_A),
    );
    expect(stillA.status).toBe(200);
  });
});
