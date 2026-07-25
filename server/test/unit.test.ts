/**
 * Unit coverage for the pieces the HTTP tests exercise only indirectly:
 * stream-json line parsing (the proven CLI shapes), both storage backends,
 * and the nightly backup / purge maintenance job.
 */
import { existsSync, mkdtempSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { BudgetRestingError, TurnFailedError, parseStreamLine } from "../gateway/src/claude.ts";
import { runMaintenance, BACKUP_KEEP_DAYS } from "../gateway/src/maintenance.ts";
import {
  isBudgetError,
  oneShotCommand,
  shellQuoted,
  stripFences,
  userMessageLine,
  warmCommand,
} from "../gateway/src/prompt.ts";
import { createStore, JsonFileStore, type ScenarioRecord } from "../gateway/src/storage.ts";

describe("stream-json parsing (claude CLI 2.1.178 shapes)", () => {
  it("yields text deltas and filters thinking deltas", () => {
    const text = parseStreamLine(
      '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}}',
      "",
    );
    expect(text).toEqual({ kind: "delta", text: "hi" });
    const thinking = parseStreamLine(
      '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hmm"}}}',
      "",
    );
    expect(thinking).toEqual({ kind: "ignored" });
  });

  it("ignores the system/init preamble and unparseable lines", () => {
    expect(parseStreamLine('{"type":"system","subtype":"init"}', "").kind).toBe("ignored");
    expect(parseStreamLine("not json", "").kind).toBe("ignored");
  });

  it("completes on a success result", () => {
    const done = parseStreamLine(
      '{"type":"result","subtype":"success","is_error":false,"result":"{\\"say\\":\\"ok\\"}"}',
      "",
    );
    expect(done).toEqual({ kind: "done", text: '{"say":"ok"}' });
  });

  it("maps usage-limit results to budget rest, others to failure", () => {
    const budget = parseStreamLine(
      '{"type":"result","subtype":"error","is_error":true,"result":"5-hour usage limit reached, resets at 6pm"}',
      "",
    );
    expect(budget.kind).toBe("error");
    expect((budget as { error: Error }).error).toBeInstanceOf(BudgetRestingError);

    const failed = parseStreamLine(
      '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"boom"}',
      "",
    );
    expect((failed as { error: Error }).error).toBeInstanceOf(TurnFailedError);
  });

  it("flags exhausted rate_limit_events, ignores healthy ones", () => {
    expect(
      parseStreamLine('{"type":"rate_limit_event","rate_limit":{"status":"exceeded"}}', "").kind,
    ).toBe("rateLimited");
    expect(
      parseStreamLine('{"type":"rate_limit_event","rate_limit":{"status":"allowed"}}', "").kind,
    ).toBe("ignored");
  });
});

describe("invocations mirror ClaudeSSHBackend", () => {
  it("warm command", () => {
    expect(warmCommand("sonnet")).toBe(
      'claude -p --input-format stream-json --output-format stream-json --include-partial-messages --verbose --model sonnet --disallowed-tools "*"',
    );
  });
  it("one-shot command quotes the prompt", () => {
    expect(oneShotCommand("opus", "it's here")).toBe(
      "claude -p --output-format stream-json --include-partial-messages --verbose --model opus --disallowed-tools \"*\" 'it'\\''s here'",
    );
  });
  it("stdin user message line", () => {
    expect(JSON.parse(userMessageLine("hello"))).toEqual({
      type: "user",
      message: { role: "user", content: [{ type: "text", text: "hello" }] },
    });
    expect(userMessageLine("hello").endsWith("\n")).toBe(true);
  });
  it("strip fences / budget markers / shell quoting", () => {
    expect(stripFences('```json\n{"say":"x"}\n```')).toBe('{"say":"x"}');
    expect(isBudgetError("Rate limit reached")).toBe(true);
    expect(isBudgetError("segfault")).toBe(false);
    expect(shellQuoted("a'b")).toBe("'a'\\''b'");
  });
});

function record(id: string, updatedAt: string): ScenarioRecord {
  return {
    id,
    title: "t",
    status: "modeling",
    createdAt: updatedAt,
    updatedAt,
    deletedAt: null,
    body: `{"id":"${id}"}`,
  };
}

describe("storage backends", () => {
  it("sqlite and json stores share semantics (list order, revive, purge)", async () => {
    for (const flavor of ["sqlite", "json"] as const) {
      const dir = mkdtempSync(path.join(tmpdir(), `radiant-store-${flavor}-`));
      if (flavor === "json") writeFileSync(path.join(dir, "data.json"), '{"scenarios":[]}');
      const store = await createStore(dir);
      expect(store.kind).toBe(flavor); // node:sqlite present on this box (node 25)

      store.upsert(record("01ARZ3NDEKTSV4RRFFQ69G5FB1", "2026-07-01T00:00:00.000Z"));
      store.upsert(record("01ARZ3NDEKTSV4RRFFQ69G5FB2", "2026-07-03T00:00:00.000Z"));
      expect(store.list().map((r) => r.id)).toEqual([
        "01ARZ3NDEKTSV4RRFFQ69G5FB2",
        "01ARZ3NDEKTSV4RRFFQ69G5FB1",
      ]);

      store.softDelete("01ARZ3NDEKTSV4RRFFQ69G5FB1", "2026-07-04T00:00:00.000Z");
      expect(store.list()).toHaveLength(1);
      expect(store.get("01ARZ3NDEKTSV4RRFFQ69G5FB1")?.deletedAt).not.toBeNull();
      expect(store.restore("01ARZ3NDEKTSV4RRFFQ69G5FB1")).toBe(true);
      expect(store.restore("01ARZ3NDEKTSV4RRFFQ69G5FB1")).toBe(false);

      store.softDelete("01ARZ3NDEKTSV4RRFFQ69G5FB1", "2026-06-01T00:00:00.000Z");
      expect(store.purgeSoftDeleted(new Date("2026-07-24T00:00:00.000Z"))).toBe(1);
      expect(store.get("01ARZ3NDEKTSV4RRFFQ69G5FB1")).toBeNull();
      store.close();
    }
  });

  it("an existing data.json wins over sqlite (post-upgrade continuity)", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "radiant-store-upgrade-"));
    writeFileSync(
      path.join(dir, "data.json"),
      JSON.stringify({ scenarios: [record("01ARZ3NDEKTSV4RRFFQ69G5FB7", "2026-07-01T00:00:00.000Z")] }),
    );
    const store = await createStore(dir);
    expect(store.kind).toBe("json");
    expect(store.list()).toHaveLength(1);
    store.close();
  });
});

describe("maintenance", () => {
  it("backs up once per day, rotates after 14 days, purges soft-deletes", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "radiant-maint-"));
    const store = new JsonFileStore(path.join(dir, "data.json"));

    const backups = path.join(dir, "backups");
    const now = new Date("2026-07-24T12:00:00.000Z");
    // One backup that will fall outside the 14-day window by `now`, one inside.
    runMaintenance(store, backups, new Date("2026-07-08T12:00:00.000Z"));
    runMaintenance(store, backups, new Date("2026-07-20T12:00:00.000Z"));
    store.upsert(record("01ARZ3NDEKTSV4RRFFQ69G5FB1", "2026-06-01T00:00:00.000Z"));
    store.softDelete("01ARZ3NDEKTSV4RRFFQ69G5FB1", "2026-06-01T00:00:00.000Z");

    const result = runMaintenance(store, backups, now);
    expect(result.backedUp).toBe(true);
    expect(result.rotated).toBe(1); // only the 07-08 backup fell outside 14 days
    expect(result.purged).toBe(1);
    expect(existsSync(path.join(backups, "scenarios-2026-07-24.json"))).toBe(true);
    expect(existsSync(path.join(backups, "scenarios-2026-07-08.json"))).toBe(false);
    expect(existsSync(path.join(backups, "scenarios-2026-07-20.json"))).toBe(true);

    // Same-day rerun is a no-op backup.
    expect(runMaintenance(store, backups, now).backedUp).toBe(false);
    expect(BACKUP_KEEP_DAYS).toBe(14);
  });
});
