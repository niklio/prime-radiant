/**
 * Turn validation against the shared JSON Schemas (bundled into the dist at
 * build time — ajv is a devDependency, never a runtime install on the box).
 * Mirrors the app's ModelTurnValidation: parse → schema-check → ≤2 retries
 * with the validator error in-context (driven by the caller).
 */
import { Ajv2020 } from "ajv/dist/2020.js";
import { SCHEMAS } from "./generated.ts";
import { stripFences } from "./prompt.ts";

export interface ModelTurn {
  say: string;
  patch: unknown[] | null;
}

const ajv = new Ajv2020({
  strict: false,
  // scenario.schema.json uses `format: date-time`; formats are advisory here
  // (the worker's structural checks are the enforced layer for scenarios).
  validateFormats: false,
});
for (const [name, schema] of Object.entries(SCHEMAS)) {
  ajv.addSchema(schema, `https://primeradiant.app/schema/${name}`);
}
const compiled = ajv.getSchema("https://primeradiant.app/schema/model-turn.schema.json");
if (compiled === undefined) throw new Error("model-turn schema failed to compile");
const validateTurn = compiled;

export type TurnParseResult =
  | { ok: true; turn: ModelTurn }
  | { ok: false; error: string };

/**
 * Parses a raw model reply (fences stripped) into a validated turn. The
 * contract advertises `patch: PatchOp[] | null`; the schema expresses null as
 * key absence, so an explicit null is normalized before validation (matching
 * the schema's own note about strict-mode nullability).
 */
export function parseTurn(raw: string): TurnParseResult {
  let parsed: unknown;
  try {
    parsed = JSON.parse(stripFences(raw));
  } catch (err) {
    return { ok: false, error: `reply is not valid JSON (${(err as Error).message})` };
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return { ok: false, error: "reply must be a single JSON object" };
  }
  const candidate = { ...(parsed as Record<string, unknown>) };
  if (candidate.patch === null) delete candidate.patch;
  if (!validateTurn(candidate)) {
    const detail = (validateTurn.errors ?? [])
      .map((e) => `${e.instancePath || "/"} ${e.message ?? "invalid"}`)
      .join("; ");
    return { ok: false, error: detail || "schema validation failed" };
  }
  return {
    ok: true,
    turn: { say: candidate.say as string, patch: (candidate.patch as unknown[] | undefined) ?? null },
  };
}
