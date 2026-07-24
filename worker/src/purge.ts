import type { Env } from "./types";

/** Soft-deleted scenarios are purged after 30 days (docs/handoff.md §2.2/§6). */
export const PURGE_AFTER_DAYS = 30;

/**
 * Hard-deletes rows soft-deleted more than 30 days ago. Runs from the cron
 * trigger; safe to run any number of times.
 */
export async function purgeSoftDeleted(
  env: Env,
  now: Date = new Date(),
): Promise<number> {
  const cutoff = new Date(
    now.getTime() - PURGE_AFTER_DAYS * 24 * 60 * 60 * 1000,
  ).toISOString();
  const result = await env.DB.prepare(
    "DELETE FROM scenarios WHERE deleted_at IS NOT NULL AND deleted_at <= ?",
  )
    .bind(cutoff)
    .run();
  return result.meta.changes ?? 0;
}
