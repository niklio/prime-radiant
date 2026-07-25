/**
 * Prompt assembly + claude CLI invocations, mirroring the app's proven
 * SSH path exactly (ios/PrimeRadiant/Chat/ClaudeSSHBackend.swift, verified
 * against claude CLI 2.1.178). The CLI carries no schema enforcement, so the
 * turn contract is spelled out in-prompt and ajv holds the line server-side.
 */
import { SYSTEM_PROMPT } from "./generated.ts";

export interface ContextItem {
  role: "system" | "user" | "assistant";
  text: string;
}

/** ClaudeSSHBackend.turnContract, verbatim (handoff §5.1). */
export const TURN_CONTRACT = `## turn contract

Respond with exactly one JSON object and nothing else — no code fences, no prose outside it:
{"say": string, "patch": PatchOp[] | null}

PatchOp is one of:
{"op":"replace_tree","tree":Node}
{"op":"upsert_node","parentId":string,"node":Node}
{"op":"update_node","id":string,"fields":{"label"?,"sub"?,"p"?,"actor"?,"move"?,"note"?,"payoff"?,"confidence"?}}
{"op":"remove_node","id":string}
{"op":"mark_reached","id":string}
{"op":"set_unit","payoffUnit":{"kind":"currency"|"utils"|"scale","label":string,"components"?:[{"name":string,"weight":number}]}}
{"op":"retitle_scenario","title":string}

Node: {"id":string,"label":string,"sub"?:string,"p":number,"actor":"user"|"counterpart"|"chance","move"?:string,"note"?:string,"payoff"?:number,"confidence"?:"estimated"|"user_set"|"assumed","children"?:Node[]}`;

/** ClaudeSSHBackend.prompt(for:): instructions + conversation + contract. */
export function assemblePrompt(context: ContextItem[], systemPrompt?: string): string {
  const conversation = context.map((item) => `${item.role}: ${item.text}`).join("\n\n");
  return [systemPrompt ?? SYSTEM_PROMPT, `## conversation\n\n${conversation}`, TURN_CONTRACT].join(
    "\n\n",
  );
}

/** In-context retry message after a validation failure (≤2 retries). */
export function retryFeedback(validatorError: string): string {
  return (
    `Your previous reply was not a valid turn: ${validatorError}. ` +
    "Respond again with exactly one JSON object matching the turn contract — " +
    "no code fences, no prose outside it."
  );
}

/** One-shot retries carry the failed reply + feedback appended to the prompt. */
export function retryPrompt(prompt: string, previousReply: string, validatorError: string): string {
  return `${prompt}\n\n## previous reply (invalid)\n\n${previousReply}\n\n${retryFeedback(validatorError)}`;
}

// ---- Shell invocations (login shell required for PATH; pivot v3) -----------

/** shellQuoted(_:) — single-quote for embedding in a shell command line. */
export function shellQuoted(text: string): string {
  return `'${text.replaceAll("'", "'\\''")}'`;
}

/** ClaudeSSHBackend.warmCommand(model:) — long-lived stream-json session. */
export function warmCommand(model: string): string {
  return (
    "claude -p --input-format stream-json --output-format stream-json " +
    `--include-partial-messages --verbose --model ${model} ` +
    '--disallowed-tools "*"'
  );
}

/** ClaudeSSHBackend.oneShotCommand(model:prompt:) — per-turn fallback. */
export function oneShotCommand(model: string, prompt: string): string {
  return (
    "claude -p --output-format stream-json --include-partial-messages " +
    `--verbose --model ${model} --disallowed-tools "*" ` +
    shellQuoted(prompt)
  );
}

/** ClaudeSSHBackend.userMessageLine(_:) — one stream-json stdin user message. */
export function userMessageLine(prompt: string): string {
  return `${JSON.stringify({
    type: "user",
    message: { role: "user", content: [{ type: "text", text: prompt }] },
  })}\n`;
}

/** ClaudeSSHBackend.stripFences(_:). */
export function stripFences(text: string): string {
  let trimmed = text.trim();
  if (trimmed.startsWith("```")) {
    const newline = trimmed.indexOf("\n");
    if (newline !== -1) trimmed = trimmed.slice(newline + 1);
    if (trimmed.endsWith("```")) trimmed = trimmed.slice(0, -3);
    trimmed = trimmed.trim();
  }
  return trimmed;
}

/** ClaudeSSHBackend.mapErrorText(_:) markers → the quiet rest state. */
const REST_MARKERS = [
  "usage limit",
  "rate limit",
  "rate_limit",
  "out of extra usage",
  "credit balance",
  "limit reached",
  "resets at",
];

export function isBudgetError(text: string): boolean {
  const lowered = text.toLowerCase();
  return REST_MARKERS.some((marker) => lowered.includes(marker));
}
