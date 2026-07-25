/**
 * Pairing/auth + scenarios CRUD/sync — every worker test case ported
 * (worker/test/worker.test.ts), minus the OpenAI session-issuance suite and
 * account isolation, which have no equivalent in the single-user gateway
 * (auth is one device token; there are no accounts).
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { VERSION } from "../gateway/src/app.ts";
import { PURGE_AFTER_DAYS } from "../gateway/src/storage.ts";
import {
  authed,
  makeScenario,
  startHarness,
  DEVICE_TOKEN,
  SCENARIO_ID,
  type Harness,
} from "./helpers.ts";

let h: Harness;

beforeEach(async () => {
  h = await startHarness();
});
afterEach(async () => {
  await h.close();
});

async function putScenario(scenario: Record<string, unknown>): Promise<Response> {
  return fetch(
    `${h.baseUrl}/v1/scenarios/${scenario.id as string}`,
    authed({ method: "PUT", body: JSON.stringify(scenario) }),
  );
}

describe("health", () => {
  it("responds without auth", async () => {
    const res = await fetch(`${h.baseUrl}/v1/health`);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      ok: true,
      version: VERSION,
      paired: true,
      agentReady: true,
      budget: "ok",
    });
  });
});

describe("pairing", () => {
  it("hand-installed flow: code → device token; code is one-time", async () => {
    const unpaired = await startHarness({ deviceToken: undefined });
    try {
      expect(((await (await fetch(`${unpaired.baseUrl}/v1/health`)).json()) as { paired: boolean }).paired).toBe(false);

      const code = unpaired.gateway.enablePairing();
      expect(code).toMatch(/^\d{6}$/);

      const wrong = await fetch(`${unpaired.baseUrl}/v1/pair`, {
        method: "POST",
        body: JSON.stringify({ code: "000000" === code ? "111111" : "000000" }),
      });
      expect(wrong.status).toBe(401);

      const res = await fetch(`${unpaired.baseUrl}/v1/pair`, {
        method: "POST",
        body: JSON.stringify({ code }),
      });
      expect(res.status).toBe(200);
      const { deviceToken } = (await res.json()) as { deviceToken: string };
      expect(deviceToken).toMatch(/^[0-9a-f]{64}$/);
      expect(unpaired.mintedTokens).toEqual([deviceToken]);

      // Token is live against an authed route; the code cannot be replayed.
      const list = await fetch(`${unpaired.baseUrl}/v1/scenarios`, authed({}, deviceToken));
      expect(list.status).toBe(200);
      const replay = await fetch(`${unpaired.baseUrl}/v1/pair`, {
        method: "POST",
        body: JSON.stringify({ code }),
      });
      expect(replay.status).toBe(403);
    } finally {
      await unpaired.close();
    }
  });

  it("provisioned installs never open the pairing path", async () => {
    const res = await fetch(`${h.baseUrl}/v1/pair`, {
      method: "POST",
      body: JSON.stringify({ code: "123456" }),
    });
    expect(res.status).toBe(403);
  });
});

describe("auth middleware", () => {
  it.each([
    ["no header", {}],
    ["bad token", { headers: { Authorization: "Bearer bogus" } }],
    ["non-bearer", { headers: { Authorization: "Basic abc" } }],
  ])("rejects %s with 401", async (_name, init) => {
    const res = await fetch(`${h.baseUrl}/v1/scenarios`, init as RequestInit);
    expect(res.status).toBe(401);
  });
});

describe("scenario CRUD + sync", () => {
  it("upserts and reads back a scenario", async () => {
    const scenario = makeScenario();
    const put = await putScenario(scenario);
    expect(put.status).toBe(200);

    const get = await fetch(`${h.baseUrl}/v1/scenarios/${SCENARIO_ID}`, authed());
    expect(get.status).toBe(200);
    expect(await get.json()).toEqual(scenario);

    const list = await fetch(`${h.baseUrl}/v1/scenarios`, authed());
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
    await putScenario(makeScenario());
    const newer = await putScenario(
      makeScenario({ title: "renegotiated", updatedAt: "2026-07-03T00:00:00.000Z" }),
    );
    expect(newer.status).toBe(200);

    const stale = await putScenario(
      makeScenario({ title: "old edit", updatedAt: "2026-07-01T12:00:00.000Z" }),
    );
    expect(stale.status).toBe(409);
    expect(await stale.json()).toEqual({
      error: "stale write",
      serverUpdatedAt: "2026-07-03T00:00:00.000Z",
    });

    // Server copy unchanged by the stale write.
    const get = await fetch(`${h.baseUrl}/v1/scenarios/${SCENARIO_ID}`, authed());
    expect(((await get.json()) as { title: string }).title).toBe("renegotiated");
  });

  it("rejects a malformed scenario body with 400", async () => {
    const res = await putScenario(makeScenario({ status: "bogus" }));
    expect(res.status).toBe(400);
  });

  it("rejects a non-ULID id with 400", async () => {
    const res = await fetch(
      `${h.baseUrl}/v1/scenarios/not-a-ulid`,
      authed({ method: "PUT", body: JSON.stringify(makeScenario({ id: "not-a-ulid" })) }),
    );
    expect(res.status).toBe(400);
  });

  it("rejects an oversized scenario with 413", async () => {
    const res = await putScenario(makeScenario({ padding: "x".repeat(1_000_001) }));
    expect(res.status).toBe(413);
  });

  it("soft delete hides the scenario; restore brings it back", async () => {
    await putScenario(makeScenario());

    const del = await fetch(`${h.baseUrl}/v1/scenarios/${SCENARIO_ID}`, authed({ method: "DELETE" }));
    expect(del.status).toBe(200);
    expect(await del.json()).toMatchObject({ ok: true, purgeAfterDays: 30 });

    expect((await fetch(`${h.baseUrl}/v1/scenarios/${SCENARIO_ID}`, authed())).status).toBe(404);
    const list = (await (await fetch(`${h.baseUrl}/v1/scenarios`, authed())).json()) as {
      scenarios: unknown[];
    };
    expect(list.scenarios).toEqual([]);

    const restore = await fetch(
      `${h.baseUrl}/v1/scenarios/${SCENARIO_ID}/restore`,
      authed({ method: "POST" }),
    );
    expect(restore.status).toBe(200);
    expect((await fetch(`${h.baseUrl}/v1/scenarios/${SCENARIO_ID}`, authed())).status).toBe(200);
  });

  it("delete is idempotent and keeps the original deletedAt", async () => {
    await putScenario(makeScenario());
    const first = (await (
      await fetch(`${h.baseUrl}/v1/scenarios/${SCENARIO_ID}`, authed({ method: "DELETE" }))
    ).json()) as { deletedAt: string };
    const second = (await (
      await fetch(`${h.baseUrl}/v1/scenarios/${SCENARIO_ID}`, authed({ method: "DELETE" }))
    ).json()) as { deletedAt: string };
    expect(second.deletedAt).toBe(first.deletedAt);
  });

  it("upsert revives a soft-deleted scenario (LWW over the delete)", async () => {
    await putScenario(makeScenario());
    await fetch(`${h.baseUrl}/v1/scenarios/${SCENARIO_ID}`, authed({ method: "DELETE" }));
    const revive = await putScenario(makeScenario({ updatedAt: "2026-07-05T00:00:00.000Z" }));
    expect(revive.status).toBe(200);
    expect((await fetch(`${h.baseUrl}/v1/scenarios/${SCENARIO_ID}`, authed())).status).toBe(200);
  });

  it("restore of a never-deleted or unknown scenario is 404", async () => {
    await putScenario(makeScenario());
    const notDeleted = await fetch(
      `${h.baseUrl}/v1/scenarios/${SCENARIO_ID}/restore`,
      authed({ method: "POST" }),
    );
    expect(notDeleted.status).toBe(404);
    const unknown = await fetch(
      `${h.baseUrl}/v1/scenarios/01ARZ3NDEKTSV4RRFFQ69G5FB9/restore`,
      authed({ method: "POST" }),
    );
    expect(unknown.status).toBe(404);
  });

  it("purge removes soft-deleted rows older than 30 days only", async () => {
    const now = new Date("2026-07-24T00:00:00.000Z");
    const old = new Date("2026-06-01T00:00:00.000Z").toISOString(); // 53 days
    const recent = new Date("2026-07-20T00:00:00.000Z").toISOString(); // 4 days
    const insert = (id: string, deletedAt: string | null) =>
      h.store.upsert({
        id,
        title: "t",
        status: "modeling",
        createdAt: recent,
        updatedAt: recent,
        deletedAt: null,
        body: "{}",
      });
    const oldId = "01ARZ3NDEKTSV4RRFFQ69G5FB1";
    const recentId = "01ARZ3NDEKTSV4RRFFQ69G5FB2";
    const liveId = "01ARZ3NDEKTSV4RRFFQ69G5FB3";
    insert(oldId, null);
    h.store.softDelete(oldId, old);
    insert(recentId, null);
    h.store.softDelete(recentId, recent);
    insert(liveId, null);

    expect(h.store.purgeSoftDeleted(now)).toBe(1);
    expect(h.store.get(oldId)).toBeNull();
    expect(h.store.get(recentId)).not.toBeNull();
    expect(h.store.get(liveId)).not.toBeNull();
    expect(PURGE_AFTER_DAYS).toBe(30);
  });

  it("unknown routes 404", async () => {
    expect((await fetch(`${h.baseUrl}/v1/nope`, authed())).status).toBe(404);
    expect((await fetch(`${h.baseUrl}/other`)).status).toBe(404);
  });
});
