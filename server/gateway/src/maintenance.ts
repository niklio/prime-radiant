/**
 * In-process housekeeping, driven by an hourly timer in index.ts:
 * - nightly snapshot into backups/ (one per calendar day, 14-day rotation)
 * - soft-delete purge (30-day; storage.PURGE_AFTER_DAYS)
 */
import { existsSync, mkdirSync, readdirSync, unlinkSync } from "node:fs";
import path from "node:path";
import type { ScenarioStore } from "./storage.ts";

export const BACKUP_KEEP_DAYS = 14;

const BACKUP_RE = /^scenarios-(\d{4}-\d{2}-\d{2})\.(sqlite|json)$/;

function dayStamp(date: Date): string {
  return date.toISOString().slice(0, 10);
}

/** Idempotent per day: backs up once, rotates, purges. Returns what it did. */
export function runMaintenance(
  store: ScenarioStore,
  backupsDir: string,
  now: Date = new Date(),
): { backedUp: boolean; rotated: number; purged: number } {
  mkdirSync(backupsDir, { recursive: true });
  const ext = store.kind === "sqlite" ? "sqlite" : "json";
  const dest = path.join(backupsDir, `scenarios-${dayStamp(now)}.${ext}`);
  let backedUp = false;
  if (!existsSync(dest)) {
    store.backup(dest);
    backedUp = true;
  }

  const cutoff = dayStamp(new Date(now.getTime() - BACKUP_KEEP_DAYS * 24 * 60 * 60 * 1000));
  let rotated = 0;
  for (const name of readdirSync(backupsDir)) {
    const match = BACKUP_RE.exec(name);
    if (match !== null && (match[1] as string) < cutoff) {
      unlinkSync(path.join(backupsDir, name));
      rotated += 1;
    }
  }

  return { backedUp, rotated, purged: store.purgeSoftDeleted(now) };
}
