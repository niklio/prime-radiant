/**
 * Per-account rate limiting — v1 choice: in-memory, per-isolate fixed window.
 *
 * Documented tradeoff (docs/handoff.md §6 "rate-limit per account"): counters
 * live in isolate memory, so the effective global limit is (limit × number of
 * live isolates) and counters reset on isolate eviction. That is acceptable
 * for v1: this Worker serves low-volume scenario sync for a single-user app,
 * and the limiter's job is abuse/bug containment, not precise quotas. If
 * precise limits are ever needed, swap for Durable Objects or Cloudflare's
 * native rate-limiting binding — the call site is this one function.
 */
const WINDOW_MS = 60_000;
export const DEFAULT_LIMIT_PER_MINUTE = 120;

interface Bucket {
  windowStart: number;
  count: number;
}

const buckets = new Map<string, Bucket>();

/** Returns true if the request is allowed. */
export function checkRateLimit(
  accountId: string,
  limit: number = DEFAULT_LIMIT_PER_MINUTE,
  now: number = Date.now(),
): boolean {
  const bucket = buckets.get(accountId);
  if (!bucket || now - bucket.windowStart >= WINDOW_MS) {
    buckets.set(accountId, { windowStart: now, count: 1 });
    return true;
  }
  bucket.count += 1;
  return bucket.count <= limit;
}

/** Test hook. */
export function resetRateLimiter(): void {
  buckets.clear();
}
