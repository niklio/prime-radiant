/**
 * The claude CLI process wrapper: ONE warm stream-json process, multiplexed
 * serially (the chat queue upstream guarantees one turn at a time), respawned
 * on death or model change, with a per-turn one-shot fallback — the same
 * invocations and stream shapes the app proved over SSH (ClaudeSSHBackend,
 * claude CLI 2.1.178):
 *
 * - `stream_event` / `content_block_delta` / `text_delta` → say deltas
 *   (`thinking_delta`, `signature_delta` are filtered out)
 * - `rate_limit_event` → budget state (informational; never aborts a turn)
 * - `result` → turn end (`subtype:"success"` + full text, or an error we map
 *   to budget-resting vs plain failure)
 *
 * Privacy: prompts and replies never touch the log.
 */
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import {
  isBudgetError,
  oneShotCommand,
  userMessageLine,
  warmCommand,
} from "./prompt.ts";

export type DeltaSink = (text: string) => void;

/** Usage/rate-limit exhaustion → the app's quiet rest state (pivot §3). */
export class BudgetRestingError extends Error {
  constructor() {
    super("budget_resting");
    this.name = "BudgetRestingError";
  }
}

export class TurnFailedError extends Error {
  constructor(message: string) {
    super(message.trim() === "" ? "no result from claude" : message.trim());
    this.name = "TurnFailedError";
  }
}

/** The turn engine the HTTP layer depends on; tests inject a mock. */
export interface TurnRunner {
  /** Runs one turn; resolves the final result text. */
  turn(model: string, prompt: string, onDelta: DeltaSink): Promise<string>;
  /**
   * Validation retry: a short in-context feedback message when the warm
   * session that produced the reply is still alive, else a one-shot carrying
   * `fullRetryPrompt` (original prompt + failed reply + feedback).
   */
  retry(
    model: string,
    feedback: string,
    fullRetryPrompt: string,
    onDelta: DeltaSink,
  ): Promise<string>;
  dispose(): void;
}

export interface ClaudeRunnerOptions {
  /** Login shell prefix, e.g. ["zsh", "-lc"] — PATH does not resolve on bare exec. */
  loginShell: string[];
  turnTimeoutMs: number;
  /** Budget-state observer (drives /v1/health `budget`). */
  onBudget?: (state: "ok" | "resting") => void;
}

class WarmDied extends Error {}

interface Pending {
  resolve: (text: string) => void;
  reject: (err: Error) => void;
  onDelta: DeltaSink;
}

/** Parses one stream-json stdout line; mirrors ClaudeSSHBackend.handle(line:). */
type LineOutcome =
  | { kind: "ignored" }
  | { kind: "delta"; text: string }
  | { kind: "rateLimited" }
  | { kind: "done"; text: string }
  | { kind: "error"; error: Error };

export function parseStreamLine(line: string, stderr: string): LineOutcome {
  let object: Record<string, unknown>;
  try {
    const parsed: unknown = JSON.parse(line);
    if (typeof parsed !== "object" || parsed === null) return { kind: "ignored" };
    object = parsed as Record<string, unknown>;
  } catch {
    return { kind: "ignored" };
  }
  switch (object.type) {
    case "stream_event": {
      const event = object.event as Record<string, unknown> | undefined;
      if (event?.type !== "content_block_delta") return { kind: "ignored" };
      const delta = event.delta as Record<string, unknown> | undefined;
      if (delta?.type !== "text_delta" || typeof delta.text !== "string") {
        return { kind: "ignored" }; // thinking_delta / signature_delta filtered
      }
      return { kind: "delta", text: delta.text };
    }
    case "rate_limit_event": {
      const flat = JSON.stringify(object).toLowerCase();
      return /exceeded|exhausted|limit_reached|rejected/.test(flat)
        ? { kind: "rateLimited" }
        : { kind: "ignored" };
    }
    case "result": {
      const isError = object.is_error === true;
      const subtype = typeof object.subtype === "string" ? object.subtype : "";
      const text = typeof object.result === "string" ? object.result : "";
      if (isError || subtype !== "success") {
        const combined = [text, subtype, stderr].join(" ");
        return {
          kind: "error",
          error: isBudgetError(combined)
            ? new BudgetRestingError()
            : new TurnFailedError(combined),
        };
      }
      return { kind: "done", text };
    }
    default:
      return { kind: "ignored" };
  }
}

class Warm {
  readonly proc: ChildProcessWithoutNullStreams;
  readonly model: string;
  stderr = "";
  private buffer = "";
  pending: Pending | null = null;
  alive = true;

  constructor(proc: ChildProcessWithoutNullStreams, model: string, runner: ClaudeRunner) {
    this.proc = proc;
    this.model = model;
    proc.stderr.on("data", (chunk: Buffer) => {
      this.stderr += chunk.toString();
    });
    proc.stdout.on("data", (chunk: Buffer) => {
      this.buffer += chunk.toString();
      let newline: number;
      while ((newline = this.buffer.indexOf("\n")) !== -1) {
        const line = this.buffer.slice(0, newline);
        this.buffer = this.buffer.slice(newline + 1);
        this.handle(line, runner);
      }
    });
    const onExit = () => {
      this.alive = false;
      runner.warmEnded(this);
    };
    proc.on("exit", onExit);
    proc.on("error", onExit);
  }

  private handle(line: string, runner: ClaudeRunner): void {
    const active = this.pending;
    if (active === null) return;
    const outcome = parseStreamLine(line, this.stderr);
    switch (outcome.kind) {
      case "delta":
        active.onDelta(outcome.text);
        return;
      case "rateLimited":
        runner.reportBudget("resting");
        return;
      case "done":
        this.pending = null;
        runner.reportBudget("ok");
        active.resolve(outcome.text);
        return;
      case "error":
        this.pending = null;
        if (outcome.error instanceof BudgetRestingError) runner.reportBudget("resting");
        active.reject(outcome.error);
        return;
      case "ignored":
        return;
    }
  }

  failPending(err: Error): void {
    const active = this.pending;
    this.pending = null;
    active?.reject(err);
  }

  close(): void {
    this.alive = false;
    this.pending = null;
    this.proc.kill();
  }
}

export class ClaudeRunner implements TurnRunner {
  private readonly options: ClaudeRunnerOptions;
  private warm: Warm | null = null;
  private lastVia: "warm" | "oneshot" = "oneshot";

  constructor(options: ClaudeRunnerOptions) {
    this.options = options;
  }

  reportBudget(state: "ok" | "resting"): void {
    this.options.onBudget?.(state);
  }

  warmEnded(warm: Warm): void {
    if (this.warm === warm) this.warm = null;
    warm.failPending(new WarmDied());
  }

  private spawnShell(command: string): ChildProcessWithoutNullStreams {
    const [shell, ...args] = this.options.loginShell;
    return spawn(shell as string, [...args, command], { stdio: ["pipe", "pipe", "pipe"] });
  }

  private withTimeout(work: Promise<string>, onTimeout: () => void): Promise<string> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        onTimeout();
        reject(new TurnFailedError("turn timed out"));
      }, this.options.turnTimeoutMs);
      work.then(
        (text) => {
          clearTimeout(timer);
          resolve(text);
        },
        (err: Error) => {
          clearTimeout(timer);
          reject(err);
        },
      );
    });
  }

  async turn(model: string, prompt: string, onDelta: DeltaSink): Promise<string> {
    try {
      const text = await this.warmSend(model, userMessageLine(prompt), onDelta);
      this.lastVia = "warm";
      return text;
    } catch (err) {
      if (!(err instanceof WarmDied)) throw err;
    }
    return this.oneShot(model, prompt, onDelta);
  }

  async retry(
    model: string,
    feedback: string,
    fullRetryPrompt: string,
    onDelta: DeltaSink,
  ): Promise<string> {
    if (this.lastVia === "warm" && this.warm?.alive === true && this.warm.model === model) {
      try {
        return await this.warmSend(model, userMessageLine(feedback), onDelta);
      } catch (err) {
        if (!(err instanceof WarmDied)) throw err;
      }
    }
    return this.oneShot(model, fullRetryPrompt, onDelta);
  }

  /** Sends one user message on the warm session, (re)spawning as needed. */
  private warmSend(model: string, message: string, onDelta: DeltaSink): Promise<string> {
    if (this.warm === null || !this.warm.alive || this.warm.model !== model) {
      this.warm?.close();
      this.warm = new Warm(this.spawnShell(warmCommand(model)), model, this);
    }
    const warm = this.warm;
    const work = new Promise<string>((resolve, reject) => {
      warm.pending = { resolve, reject, onDelta };
      warm.proc.stdin.write(message, (err) => {
        if (err) warm.failPending(new WarmDied());
      });
    });
    return this.withTimeout(work, () => warm.close());
  }

  private oneShot(model: string, prompt: string, onDelta: DeltaSink): Promise<string> {
    this.lastVia = "oneshot";
    const proc = this.spawnShell(oneShotCommand(model, prompt));
    proc.stdin.end();
    let stderr = "";
    let buffer = "";
    const work = new Promise<string>((resolve, reject) => {
      let settled = false;
      const settle = (fn: () => void) => {
        if (settled) return;
        settled = true;
        fn();
      };
      proc.stderr.on("data", (chunk: Buffer) => {
        stderr += chunk.toString();
      });
      proc.stdout.on("data", (chunk: Buffer) => {
        buffer += chunk.toString();
        let newline: number;
        while ((newline = buffer.indexOf("\n")) !== -1) {
          const line = buffer.slice(0, newline);
          buffer = buffer.slice(newline + 1);
          const outcome = parseStreamLine(line, stderr);
          if (outcome.kind === "delta") onDelta(outcome.text);
          else if (outcome.kind === "rateLimited") this.reportBudget("resting");
          else if (outcome.kind === "done") {
            this.reportBudget("ok");
            settle(() => resolve(outcome.text));
          } else if (outcome.kind === "error") {
            if (outcome.error instanceof BudgetRestingError) this.reportBudget("resting");
            settle(() => reject(outcome.error));
          }
        }
      });
      const fail = (detail: string) =>
        settle(() =>
          reject(
            isBudgetError(detail) ? new BudgetRestingError() : new TurnFailedError(detail),
          ),
        );
      proc.on("exit", (code) => fail(stderr === "" ? `claude exited ${code ?? -1}` : stderr));
      proc.on("error", (err) => fail(err.message));
    });
    return this.withTimeout(work, () => proc.kill());
  }

  dispose(): void {
    this.warm?.close();
    this.warm = null;
  }
}
