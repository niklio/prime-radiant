/**
 * /v1/chat SSE: happy path, validation retries (≤2, in-context), budget rest
 * events, and turn-contract enforcement against the shared schemas. The
 * claude process wrapper is mocked (MockRunner); everything above it is real.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { SYSTEM_PROMPT } from "../gateway/src/generated.ts";
import { TURN_CONTRACT } from "../gateway/src/prompt.ts";
import { authed, parseSSE, startHarness, type Harness } from "./helpers.ts";

let h: Harness;

beforeEach(async () => {
  h = await startHarness();
});
afterEach(async () => {
  await h.close();
});

const NODE_ID = "01ARZ3NDEKTSV4RRFFQ69G5FA0";

function chatRequest(overrides: Record<string, unknown> = {}): RequestInit {
  return authed({
    method: "POST",
    body: JSON.stringify({
      scenarioId: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
      context: [{ role: "user", text: "should I take the offer?" }],
      mode: "interactive",
      ...overrides,
    }),
  });
}

const VALID_TURN = JSON.stringify({
  say: "counter at 190; they accept 60% of the time.",
  patch: [
    {
      op: "upsert_node",
      parentId: NODE_ID,
      node: { id: "01ARZ3NDEKTSV4RRFFQ69G5FA1", label: "counter 190", p: 0.6, actor: "counterpart" },
    },
  ],
});

describe("chat SSE", () => {
  it("streams say deltas, then a validated turn, then done", async () => {
    h.runner.enqueue({ kind: "reply", deltas: ["counter ", "at 190"], text: VALID_TURN });

    const res = await fetch(`${h.baseUrl}/v1/chat`, chatRequest());
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/event-stream");

    const events = parseSSE(await res.text());
    expect(events.map((e) => e.event)).toEqual(["say", "say", "turn", "done"]);
    expect(events[0]?.data).toEqual({ text: "counter " });
    expect(events[2]?.data).toEqual(JSON.parse(VALID_TURN));

    // Prompt mirrors ClaudeSSHBackend.prompt(for:): system.md + conversation
    // + turn contract; interactive mode uses the interactive model alias.
    const call = h.runner.calls[0];
    expect(call?.via).toBe("turn");
    expect(call?.model).toBe("sonnet");
    expect(call?.prompt.startsWith(SYSTEM_PROMPT)).toBe(true);
    expect(call?.prompt).toContain("## conversation\n\nuser: should I take the offer?");
    expect(call?.prompt.endsWith(TURN_CONTRACT)).toBe(true);
  });

  it("normalizes an explicit patch:null and picks the restructure model", async () => {
    h.runner.enqueue({ kind: "reply", deltas: [], text: '{"say":"noted.","patch":null}' });
    const res = await fetch(`${h.baseUrl}/v1/chat`, chatRequest({ mode: "restructure" }));
    const events = parseSSE(await res.text());
    expect(events.find((e) => e.event === "turn")?.data).toEqual({ say: "noted.", patch: null });
    expect(h.runner.calls[0]?.model).toBe("opus");
  });

  it("strips code fences before validation", async () => {
    h.runner.enqueue({ kind: "reply", deltas: [], text: "```json\n" + VALID_TURN + "\n```" });
    const events = parseSSE(await (await fetch(`${h.baseUrl}/v1/chat`, chatRequest())).text());
    expect(events.find((e) => e.event === "turn")?.data).toEqual(JSON.parse(VALID_TURN));
  });

  it("retries with the validator error in-context, then succeeds", async () => {
    h.runner.enqueue(
      { kind: "reply", deltas: [], text: "not json at all" },
      { kind: "reply", deltas: [], text: VALID_TURN },
    );

    const events = parseSSE(await (await fetch(`${h.baseUrl}/v1/chat`, chatRequest())).text());
    expect(events.map((e) => e.event)).toEqual(["turn", "done"]);

    expect(h.runner.calls).toHaveLength(2);
    const retry = h.runner.calls[1];
    expect(retry?.via).toBe("retry");
    expect(retry?.feedback).toContain("not a valid turn");
    // One-shot fallback prompt carries the failed reply for context.
    expect(retry?.prompt).toContain("not json at all");
  });

  it("rejects schema-invalid patches and gives up after 2 retries", async () => {
    const badTurn = '{"say":"hm","patch":[{"op":"upsert_node"}]}';
    h.runner.enqueue(
      { kind: "reply", deltas: [], text: badTurn },
      { kind: "reply", deltas: [], text: badTurn },
      { kind: "reply", deltas: [], text: badTurn },
    );

    const events = parseSSE(await (await fetch(`${h.baseUrl}/v1/chat`, chatRequest())).text());
    expect(events.map((e) => e.event)).toEqual(["error", "done"]);
    expect((events[0]?.data as { error: string }).error).toBe("invalid_turn");
    expect(h.runner.calls).toHaveLength(3); // 1 turn + 2 retries, never more
  });

  it("maps budget exhaustion to a machine-readable rest event + health state", async () => {
    h.runner.enqueue({ kind: "budget" });

    const events = parseSSE(await (await fetch(`${h.baseUrl}/v1/chat`, chatRequest())).text());
    expect(events.map((e) => e.event)).toEqual(["error", "done"]);
    expect(events[0]?.data).toEqual({ error: "budget_resting" });

    const health = (await (await fetch(`${h.baseUrl}/v1/health`)).json()) as { budget: string };
    expect(health.budget).toBe("resting");
  });

  it("reports plain turn failures without leaking the prompt", async () => {
    h.runner.enqueue({ kind: "fail", message: "claude exited 1" });
    const events = parseSSE(await (await fetch(`${h.baseUrl}/v1/chat`, chatRequest())).text());
    expect(events[0]?.data).toEqual({ error: "turn_failed", message: "claude exited 1" });
  });

  it("serializes concurrent turns through the single warm process", async () => {
    h.runner.enqueue(
      { kind: "reply", deltas: [], text: '{"say":"first"}' },
      { kind: "reply", deltas: [], text: '{"say":"second"}' },
    );
    const [a, b] = await Promise.all([
      fetch(`${h.baseUrl}/v1/chat`, chatRequest()).then((r) => r.text()),
      fetch(`${h.baseUrl}/v1/chat`, chatRequest()).then((r) => r.text()),
    ]);
    const says = [a, b]
      .map((body) => parseSSE(body).find((e) => e.event === "turn")?.data as { say: string })
      .map((turn) => turn.say)
      .sort();
    expect(says).toEqual(["first", "second"]);
    expect(h.runner.calls.map((c) => c.via)).toEqual(["turn", "turn"]);
  });

  it("rejects malformed chat requests with 400", async () => {
    const missing = await fetch(`${h.baseUrl}/v1/chat`, chatRequest({ context: [] }));
    expect(missing.status).toBe(400);
    const badMode = await fetch(`${h.baseUrl}/v1/chat`, chatRequest({ mode: "yolo" }));
    expect(badMode.status).toBe(400);
    const notJson = await fetch(`${h.baseUrl}/v1/chat`, authed({ method: "POST", body: "{" }));
    expect(notJson.status).toBe(400);
  });

  it("requires auth", async () => {
    const res = await fetch(`${h.baseUrl}/v1/chat`, {
      method: "POST",
      body: JSON.stringify({}),
    });
    expect(res.status).toBe(401);
  });
});
