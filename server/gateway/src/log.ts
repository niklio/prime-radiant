/**
 * Structured line log to stdout (launchd redirects to gateway.log).
 *
 * Privacy rule (worker/src/app.ts, pivot §4): request/response bodies,
 * prompts, transcripts, and tokens are NEVER logged — operational fields only.
 */
export function logLine(fields: Record<string, unknown>): void {
  process.stdout.write(`${JSON.stringify({ ts: new Date().toISOString(), ...fields })}\n`);
}

export function logRequest(route: string, status: number, startedAt: number): void {
  logLine({ route, status, ms: Date.now() - startedAt });
}
