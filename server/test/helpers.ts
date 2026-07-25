/**
 * Test harness: a real node:http server around the gateway handler, a
 * JSON-file store in a temp dir, and a scripted TurnRunner in place of the
 * claude process wrapper.
 */
import http from "node:http";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { createGateway, type Gateway, type GatewayDeps } from "../gateway/src/app.ts";
import { BudgetRestingError, TurnFailedError, type DeltaSink, type TurnRunner } from "../gateway/src/claude.ts";
import { DEFAULT_CONFIG, type GatewayConfig } from "../gateway/src/config.ts";
import { JsonFileStore } from "../gateway/src/storage.ts";

export const DEVICE_TOKEN = "a".repeat(64);

export type ScriptedReply =
  | { kind: "reply"; deltas: string[]; text: string }
  | { kind: "budget" }
  | { kind: "fail"; message: string };

export interface RecordedCall {
  via: "turn" | "retry";
  model: string;
  prompt: string;
  feedback?: string;
}

/** Mocks gateway/src/claude.ts — the only thing not under test here. */
export class MockRunner implements TurnRunner {
  readonly calls: RecordedCall[] = [];
  private script: ScriptedReply[] = [];

  enqueue(...replies: ScriptedReply[]): void {
    this.script.push(...replies);
  }

  private next(onDelta: DeltaSink): Promise<string> {
    const reply = this.script.shift();
    if (reply === undefined) throw new Error("MockRunner script exhausted");
    if (reply.kind === "budget") return Promise.reject(new BudgetRestingError());
    if (reply.kind === "fail") return Promise.reject(new TurnFailedError(reply.message));
    for (const delta of reply.deltas) onDelta(delta);
    return Promise.resolve(reply.text);
  }

  turn(model: string, prompt: string, onDelta: DeltaSink): Promise<string> {
    this.calls.push({ via: "turn", model, prompt });
    return this.next(onDelta);
  }

  retry(model: string, feedback: string, fullRetryPrompt: string, onDelta: DeltaSink): Promise<string> {
    this.calls.push({ via: "retry", model, prompt: fullRetryPrompt, feedback });
    return this.next(onDelta);
  }

  dispose(): void {}
}

export interface Harness {
  baseUrl: string;
  gateway: Gateway;
  store: JsonFileStore;
  runner: MockRunner;
  mintedTokens: string[];
  close(): Promise<void>;
}

export async function startHarness(overrides: Partial<GatewayConfig> = {}): Promise<Harness> {
  const dir = mkdtempSync(path.join(tmpdir(), "radiant-gateway-test-"));
  const store = new JsonFileStore(path.join(dir, "data.json"));
  const runner = new MockRunner();
  const mintedTokens: string[] = [];
  const config: GatewayConfig = { ...DEFAULT_CONFIG, deviceToken: DEVICE_TOKEN, ...overrides };
  const deps: GatewayDeps = {
    store,
    runner,
    config,
    agentReady: () => true,
    onTokenMinted: (token) => mintedTokens.push(token),
  };
  const gateway = createGateway(deps);
  const server = http.createServer(gateway.handler);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as { port: number }).port;
  return {
    baseUrl: `http://127.0.0.1:${port}`,
    gateway,
    store,
    runner,
    mintedTokens,
    close: () => new Promise((resolve) => server.close(() => resolve())),
  };
}

export function authed(init: RequestInit = {}, token: string = DEVICE_TOKEN): RequestInit {
  return { ...init, headers: { Authorization: `Bearer ${token}`, ...(init.headers ?? {}) } };
}

export const SCENARIO_ID = "01ARZ3NDEKTSV4RRFFQ69G5FAV";
export const NODE_ID = "01ARZ3NDEKTSV4RRFFQ69G5FA0";

/** Worker test fixture, verbatim (worker/test/worker.test.ts). */
export function makeScenario(overrides: Record<string, unknown> = {}) {
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

export interface SSEEvent {
  event: string;
  data: unknown;
}

/** Parses a complete SSE body (the gateway always ends the stream). */
export function parseSSE(body: string): SSEEvent[] {
  const events: SSEEvent[] = [];
  for (const block of body.split("\n\n")) {
    const lines = block.split("\n").filter((l) => l !== "" && !l.startsWith(":"));
    if (lines.length === 0) continue;
    const event = lines.find((l) => l.startsWith("event: "))?.slice("event: ".length);
    const data = lines.find((l) => l.startsWith("data: "))?.slice("data: ".length);
    if (event !== undefined && data !== undefined) {
      events.push({ event, data: JSON.parse(data) });
    }
  }
  return events;
}
