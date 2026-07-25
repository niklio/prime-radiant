/**
 * Prime Radiant gateway — plain node:http, zero runtime dependencies.
 *
 * Scope (pivot §4 as amended by the hybrid posture): /v1/health, /v1/pair,
 * /v1/chat (SSE over one warm claude process), /v1/scenarios CRUD + sync
 * ported from the Worker (single user, no accounts). SSH remains the
 * repair/upgrade channel; this server exists for latency and connection
 * suspension.
 *
 * Privacy: request/response bodies are NEVER logged anywhere in this file —
 * do not add logging of scenario content, prompts, or tokens. Structured
 * operational lines only (ts, route, status, ms).
 */
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import type { IncomingMessage, ServerResponse } from "node:http";
import { BudgetRestingError, type TurnRunner } from "./claude.ts";
import type { GatewayConfig } from "./config.ts";
import { logRequest } from "./log.ts";
import { assemblePrompt, retryFeedback, retryPrompt, type ContextItem } from "./prompt.ts";
import { parseTurn } from "./validate.ts";
import { PURGE_AFTER_DAYS, type ScenarioStore } from "./storage.ts";

export const VERSION = "0.1.0";

const ULID_RE = /^[0-7][0-9A-HJKMNP-TV-Z]{25}$/;
const STATUSES = new Set(["modeling", "in_progress", "resolved"]);
/** Cap on a serialized scenario (tree + transcript blob) — worker parity. */
const MAX_BODY_BYTES = 1_000_000;
const SSE_KEEPALIVE_MS = 15_000;
/** Validation retries with the validator error in-context (handoff §5.1). */
const MAX_TURN_RETRIES = 2;

export interface GatewayDeps {
  store: ScenarioStore;
  runner: TurnRunner;
  config: GatewayConfig;
  /** Persists a token minted by /v1/pair (hand-installed servers only). */
  onTokenMinted?: (token: string) => void;
  /** Startup probe result: claude CLI reachable through the login shell. */
  agentReady?: () => boolean;
}

export interface Gateway {
  handler: (req: IncomingMessage, res: ServerResponse) => void;
  /** Arms the pairing-code path (hand-installed + unpaired only). */
  enablePairing(): string;
  setBudget(state: "ok" | "resting"): void;
  readonly paired: boolean;
}

interface ScenarioBody {
  title: string;
  status: string;
  createdAt: string;
  updatedAt: string;
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

interface ChatRequest {
  scenarioId: string;
  context: ContextItem[];
  mode: "interactive" | "restructure";
  systemPrompt?: string;
  focusedNodeId?: string;
}

function validateChat(body: unknown): ChatRequest | null {
  if (typeof body !== "object" || body === null) return null;
  const b = body as Record<string, unknown>;
  if (typeof b.scenarioId !== "string" || b.scenarioId.length === 0) return null;
  if (b.mode !== "interactive" && b.mode !== "restructure") return null;
  if (!Array.isArray(b.context) || b.context.length === 0) return null;
  for (const item of b.context) {
    const i = item as Record<string, unknown>;
    if (i.role !== "system" && i.role !== "user" && i.role !== "assistant") return null;
    if (typeof i.text !== "string") return null;
  }
  if (b.systemPrompt !== undefined && typeof b.systemPrompt !== "string") return null;
  if (b.focusedNodeId !== undefined && typeof b.focusedNodeId !== "string") return null;
  return b as unknown as ChatRequest;
}

function constantTimeEquals(a: string, b: string): boolean {
  const ha = createHash("sha256").update(a).digest();
  const hb = createHash("sha256").update(b).digest();
  return timingSafeEqual(ha, hb);
}

function readBody(req: IncomingMessage, limit: number): Promise<string | null> {
  return new Promise((resolve) => {
    const chunks: Buffer[] = [];
    let size = 0;
    let over = false;
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      // Keep draining so the client still gets the error response.
      if (size > limit) over = true;
      else chunks.push(chunk);
    });
    req.on("end", () => resolve(over ? null : Buffer.concat(chunks).toString()));
    req.on("error", () => resolve(null));
  });
}

export function createGateway(deps: GatewayDeps): Gateway {
  const { store, runner, config } = deps;
  let deviceToken = config.deviceToken ?? null;
  let pairingCode: string | null = null;
  let budget: "ok" | "resting" = "ok";
  /** Serializes chat turns: one claude turn at a time, FIFO. */
  let chatQueue: Promise<void> = Promise.resolve();

  function json(res: ServerResponse, status: number, body: unknown): number {
    res.writeHead(status, { "Content-Type": "application/json" });
    res.end(JSON.stringify(body));
    return status;
  }

  function metadata(row: { id: string; title: string; status: string; createdAt: string; updatedAt: string }) {
    return {
      id: row.id,
      title: row.title,
      status: row.status,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    };
  }

  function authorized(req: IncomingMessage): boolean {
    if (deviceToken === null) return false;
    const authz = req.headers.authorization ?? "";
    if (!authz.startsWith("Bearer ")) return false;
    return constantTimeEquals(authz.slice("Bearer ".length), deviceToken);
  }

  // ---- Chat (SSE over the warm claude process) -----------------------------

  async function runChatTurn(
    chat: ChatRequest,
    send: (event: string, data: unknown) => void,
  ): Promise<void> {
    const model =
      chat.mode === "restructure" ? config.restructureModel : config.interactiveModel;
    const prompt = assemblePrompt(chat.context, chat.systemPrompt);
    const onDelta = (text: string) => send("say", { text });
    try {
      let reply = await runner.turn(model, prompt, onDelta);
      for (let attempt = 0; ; attempt += 1) {
        const parsed = parseTurn(reply);
        if (parsed.ok) {
          send("turn", parsed.turn);
          return;
        }
        if (attempt >= MAX_TURN_RETRIES) {
          send("error", { error: "invalid_turn", message: parsed.error });
          return;
        }
        reply = await runner.retry(
          model,
          retryFeedback(parsed.error),
          retryPrompt(prompt, reply, parsed.error),
          onDelta,
        );
      }
    } catch (err) {
      if (err instanceof BudgetRestingError) {
        budget = "resting";
        send("error", { error: "budget_resting" });
      } else {
        send("error", { error: "turn_failed", message: (err as Error).message });
      }
    }
  }

  function handleChat(req: IncomingMessage, res: ServerResponse, startedAt: number): void {
    void readBody(req, MAX_BODY_BYTES).then((raw) => {
      let parsed: unknown;
      try {
        parsed = JSON.parse(raw ?? "");
      } catch {
        logRequest("POST /v1/chat", json(res, 400, { error: "invalid JSON" }), startedAt);
        return;
      }
      const chat = validateChat(parsed);
      if (chat === null) {
        logRequest("POST /v1/chat", json(res, 400, { error: "invalid chat request" }), startedAt);
        return;
      }

      res.writeHead(200, {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        Connection: "keep-alive",
      });
      res.socket?.setTimeout(0);
      const send = (event: string, data: unknown) => {
        if (!res.writableEnded && !res.destroyed) {
          res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
        }
      };
      const keepalive = setInterval(() => {
        if (!res.writableEnded && !res.destroyed) res.write(": ping\n\n");
      }, SSE_KEEPALIVE_MS);

      chatQueue = chatQueue
        .then(() => runChatTurn(chat, send))
        .catch(() => send("error", { error: "turn_failed", message: "internal error" }))
        .finally(() => {
          clearInterval(keepalive);
          send("done", {});
          res.end();
          logRequest("POST /v1/chat", 200, startedAt);
        });
    });
  }

  // ---- Scenarios (ported from worker/src/app.ts; single user) --------------

  function handleScenarios(
    req: IncomingMessage,
    res: ServerResponse,
    segments: string[],
    startedAt: number,
  ): void {
    const route = `${req.method ?? ""} /v1/scenarios`;
    const done = (status: number) => logRequest(route, status, startedAt);

    if (segments.length === 0) {
      if (req.method === "GET") {
        return done(json(res, 200, { scenarios: store.list().map(metadata) }));
      }
      return done(json(res, 404, { error: "not found" }));
    }

    const id = segments[0] as string;
    const action = segments[1];

    if (segments.length === 2 && action === "restore" && req.method === "POST") {
      if (!store.restore(id)) return done(json(res, 404, { error: "not found" }));
      const row = store.get(id);
      return done(json(res, 200, { ok: true, scenario: row === null ? null : metadata(row) }));
    }
    if (segments.length !== 1) return done(json(res, 404, { error: "not found" }));

    switch (req.method) {
      case "GET": {
        const row = store.get(id);
        if (row === null || row.deletedAt !== null) {
          return done(json(res, 404, { error: "not found" }));
        }
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(row.body);
        return done(200);
      }
      case "PUT": {
        if (!ULID_RE.test(id)) return done(json(res, 400, { error: "id must be a ULID" }));
        void readBody(req, MAX_BODY_BYTES).then((raw) => {
          if (raw === null) return done(json(res, 413, { error: "scenario too large" }));
          let scenario: unknown;
          try {
            scenario = JSON.parse(raw);
          } catch {
            return done(json(res, 400, { error: "invalid JSON" }));
          }
          const invalid = validateScenario(scenario, id);
          if (invalid !== null) return done(json(res, 400, { error: invalid }));
          const s = scenario as ScenarioBody;

          // Last-write-wins: stale writes → 409 with the server copy's
          // updatedAt so the client can pull and re-merge.
          const existing = store.get(id);
          if (existing !== null && Date.parse(s.updatedAt) < Date.parse(existing.updatedAt)) {
            return done(
              json(res, 409, { error: "stale write", serverUpdatedAt: existing.updatedAt }),
            );
          }
          // A successful upsert always revives a soft-deleted row (the write
          // is newer than the delete under last-write-wins).
          store.upsert({
            id,
            title: s.title,
            status: s.status,
            createdAt: s.createdAt,
            updatedAt: s.updatedAt,
            deletedAt: null,
            body: raw,
          });
          return done(json(res, 200, { ok: true, id, updatedAt: s.updatedAt }));
        });
        return;
      }
      case "DELETE": {
        // Soft delete; purged by the timer job after 30 days. Idempotent.
        const row = store.get(id);
        if (row === null) return done(json(res, 404, { error: "not found" }));
        const deletedAt = row.deletedAt ?? new Date().toISOString();
        if (row.deletedAt === null) store.softDelete(id, deletedAt);
        return done(json(res, 200, { ok: true, deletedAt, purgeAfterDays: PURGE_AFTER_DAYS }));
      }
      default:
        return done(json(res, 404, { error: "not found" }));
    }
  }

  // ---- Router --------------------------------------------------------------

  function handler(req: IncomingMessage, res: ServerResponse): void {
    const startedAt = Date.now();
    const url = new URL(req.url ?? "/", "http://gateway");
    const route = `${req.method ?? ""} ${url.pathname}`;

    if (url.pathname === "/v1/health" && req.method === "GET") {
      return void logRequest(
        route,
        json(res, 200, {
          ok: true,
          version: VERSION,
          paired: deviceToken !== null,
          agentReady: deps.agentReady?.() ?? false,
          budget,
        }),
        startedAt,
      );
    }

    if (url.pathname === "/v1/pair" && req.method === "POST") {
      void readBody(req, 4096).then((raw) => {
        let code: unknown;
        try {
          code = (JSON.parse(raw ?? "") as Record<string, unknown>).code;
        } catch {
          return logRequest(route, json(res, 400, { error: "invalid JSON" }), startedAt);
        }
        // Codes exist only on hand-installed, unpaired servers; provisioned
        // installs carry a token in config and never open this path.
        if (pairingCode === null || deviceToken !== null) {
          return logRequest(route, json(res, 403, { error: "pairing not available" }), startedAt);
        }
        if (typeof code !== "string" || !constantTimeEquals(code, pairingCode)) {
          return logRequest(route, json(res, 401, { error: "invalid code" }), startedAt);
        }
        deviceToken = randomBytes(32).toString("hex");
        pairingCode = null;
        deps.onTokenMinted?.(deviceToken);
        return logRequest(route, json(res, 200, { deviceToken }), startedAt);
      });
      return;
    }

    if (!url.pathname.startsWith("/v1/")) {
      return void logRequest(route, json(res, 404, { error: "not found" }), startedAt);
    }
    if (!authorized(req)) {
      return void logRequest(route, json(res, 401, { error: "unauthorized" }), startedAt);
    }

    if (url.pathname === "/v1/chat" && req.method === "POST") {
      return handleChat(req, res, startedAt);
    }
    if (url.pathname === "/v1/scenarios" || url.pathname.startsWith("/v1/scenarios/")) {
      const segments = url.pathname.split("/").filter((s) => s !== "").slice(2);
      return handleScenarios(req, res, segments, startedAt);
    }
    return void logRequest(route, json(res, 404, { error: "not found" }), startedAt);
  }

  return {
    handler,
    enablePairing(): string {
      pairingCode = String(randomBytes(4).readUInt32BE() % 1_000_000).padStart(6, "0");
      return pairingCode;
    },
    setBudget(state: "ok" | "resting"): void {
      budget = state;
    },
    get paired(): boolean {
      return deviceToken !== null;
    },
  };
}
