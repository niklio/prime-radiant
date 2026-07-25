/**
 * Scenario persistence behind one interface, two backends:
 *
 * - `SqliteStore` — `node:sqlite` (WAL), the default wherever the module
 *   loads. Cutoff: `node:sqlite` ships flag-free from Node 22.13 / 23.4;
 *   on Node 20.x (and 22.x before 22.13) the import throws.
 * - `JsonFileStore` — dependency-free fallback for those older Nodes: one
 *   atomically-rewritten JSON file. Same semantics, fine at single-user scale.
 *
 * `createStore` picks sqlite when available, but sticks with an existing
 * data.json (a box whose Node was upgraded keeps its data without migration).
 *
 * Privacy: scenario bodies are stored, never logged (worker/src/app.ts rule).
 */
import { copyFileSync, existsSync, mkdirSync, renameSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";

/** Soft-deleted scenarios are purged after 30 days (docs/handoff.md §2.2/§6). */
export const PURGE_AFTER_DAYS = 30;

export interface ScenarioRecord {
  id: string;
  title: string;
  status: string;
  createdAt: string;
  updatedAt: string;
  deletedAt: string | null;
  /** Full serialized scenario JSON, returned verbatim on GET. */
  body: string;
}

export interface ScenarioStore {
  readonly kind: "sqlite" | "json";
  /** Lookup by id, soft-deleted rows included (delete/restore need them). */
  get(id: string): ScenarioRecord | null;
  /** Live rows only, newest `updatedAt` first. */
  list(): ScenarioRecord[];
  /** Insert or overwrite; always revives a soft-deleted row (LWW). */
  upsert(record: ScenarioRecord): void;
  softDelete(id: string, deletedAt: string): void;
  /** Returns false when the row is missing or not deleted. */
  restore(id: string): boolean;
  /** Hard-deletes rows soft-deleted more than PURGE_AFTER_DAYS ago. */
  purgeSoftDeleted(now?: Date): number;
  /** Consistent snapshot to `destPath` (nightly backups). */
  backup(destPath: string): void;
  close(): void;
}

function purgeCutoff(now: Date): string {
  return new Date(now.getTime() - PURGE_AFTER_DAYS * 24 * 60 * 60 * 1000).toISOString();
}

// ---- SQLite backend --------------------------------------------------------

interface SqliteDatabase {
  exec(sql: string): void;
  prepare(sql: string): {
    get(...params: unknown[]): unknown;
    all(...params: unknown[]): unknown[];
    run(...params: unknown[]): { changes: number | bigint };
  };
  close(): void;
}

interface SqliteRow {
  id: string;
  title: string;
  status: string;
  updated_at: string;
  created_at: string;
  deleted_at: string | null;
  body: string;
}

function fromRow(row: SqliteRow): ScenarioRecord {
  return {
    id: row.id,
    title: row.title,
    status: row.status,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    deletedAt: row.deleted_at,
    body: row.body,
  };
}

export class SqliteStore implements ScenarioStore {
  readonly kind = "sqlite";
  private readonly db: SqliteDatabase;
  private readonly path: string;

  constructor(db: SqliteDatabase, filePath: string) {
    this.db = db;
    this.path = filePath;
    this.db.exec("PRAGMA journal_mode = WAL");
    // Mirrors worker/migrations/0001_init.sql minus account_id (single user).
    this.db.exec(`CREATE TABLE IF NOT EXISTS scenarios (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      status TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      created_at TEXT NOT NULL,
      deleted_at TEXT,
      body TEXT NOT NULL
    )`);
    this.db.exec(`CREATE INDEX IF NOT EXISTS idx_scenarios_deleted
      ON scenarios (deleted_at) WHERE deleted_at IS NOT NULL`);
  }

  get(id: string): ScenarioRecord | null {
    const row = this.db
      .prepare("SELECT id, title, status, updated_at, created_at, deleted_at, body FROM scenarios WHERE id = ?")
      .get(id) as SqliteRow | undefined;
    return row === undefined ? null : fromRow(row);
  }

  list(): ScenarioRecord[] {
    const rows = this.db
      .prepare(
        `SELECT id, title, status, updated_at, created_at, deleted_at, body
           FROM scenarios WHERE deleted_at IS NULL ORDER BY updated_at DESC`,
      )
      .all() as SqliteRow[];
    return rows.map(fromRow);
  }

  upsert(record: ScenarioRecord): void {
    this.db
      .prepare(
        `INSERT INTO scenarios (id, title, status, updated_at, created_at, deleted_at, body)
         VALUES (?, ?, ?, ?, ?, NULL, ?)
         ON CONFLICT(id) DO UPDATE SET
           title = excluded.title,
           status = excluded.status,
           updated_at = excluded.updated_at,
           deleted_at = NULL,
           body = excluded.body`,
      )
      .run(record.id, record.title, record.status, record.updatedAt, record.createdAt, record.body);
  }

  softDelete(id: string, deletedAt: string): void {
    this.db.prepare("UPDATE scenarios SET deleted_at = ? WHERE id = ?").run(deletedAt, id);
  }

  restore(id: string): boolean {
    const result = this.db
      .prepare("UPDATE scenarios SET deleted_at = NULL WHERE id = ? AND deleted_at IS NOT NULL")
      .run(id);
    return Number(result.changes) > 0;
  }

  purgeSoftDeleted(now: Date = new Date()): number {
    const result = this.db
      .prepare("DELETE FROM scenarios WHERE deleted_at IS NOT NULL AND deleted_at <= ?")
      .run(purgeCutoff(now));
    return Number(result.changes);
  }

  backup(destPath: string): void {
    // Checkpoint + copy is a consistent snapshot for this single-writer
    // process (the async `sqlite.backup()` API is newer than our Node floor).
    this.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    copyFileSync(this.path, destPath);
  }

  close(): void {
    this.db.close();
  }
}

// ---- JSON-file backend -----------------------------------------------------

export class JsonFileStore implements ScenarioStore {
  readonly kind = "json";
  private readonly path: string;
  private rows = new Map<string, ScenarioRecord>();

  constructor(filePath: string) {
    this.path = filePath;
    if (existsSync(filePath)) {
      const parsed = JSON.parse(readFileSync(filePath, "utf8")) as { scenarios: ScenarioRecord[] };
      for (const row of parsed.scenarios) this.rows.set(row.id, row);
    }
  }

  private persist(): void {
    const tmp = `${this.path}.tmp`;
    writeFileSync(tmp, JSON.stringify({ scenarios: [...this.rows.values()] }));
    renameSync(tmp, this.path);
  }

  get(id: string): ScenarioRecord | null {
    return this.rows.get(id) ?? null;
  }

  list(): ScenarioRecord[] {
    return [...this.rows.values()]
      .filter((row) => row.deletedAt === null)
      .sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : a.updatedAt > b.updatedAt ? -1 : 0));
  }

  upsert(record: ScenarioRecord): void {
    this.rows.set(record.id, { ...record, deletedAt: null });
    this.persist();
  }

  softDelete(id: string, deletedAt: string): void {
    const row = this.rows.get(id);
    if (row === undefined) return;
    this.rows.set(id, { ...row, deletedAt });
    this.persist();
  }

  restore(id: string): boolean {
    const row = this.rows.get(id);
    if (row === undefined || row.deletedAt === null) return false;
    this.rows.set(id, { ...row, deletedAt: null });
    this.persist();
    return true;
  }

  purgeSoftDeleted(now: Date = new Date()): number {
    const cutoff = purgeCutoff(now);
    let purged = 0;
    for (const [id, row] of this.rows) {
      if (row.deletedAt !== null && row.deletedAt <= cutoff) {
        this.rows.delete(id);
        purged += 1;
      }
    }
    if (purged > 0) this.persist();
    return purged;
  }

  backup(destPath: string): void {
    if (existsSync(this.path)) copyFileSync(this.path, destPath);
    else writeFileSync(destPath, JSON.stringify({ scenarios: [] }));
  }

  close(): void {}
}

// ---- Factory ---------------------------------------------------------------

/**
 * Opens the store under `dataDir`: sqlite when `node:sqlite` loads, JSON
 * otherwise — but an existing data.json always wins so upgraded Nodes keep
 * their data.
 */
export async function createStore(dataDir: string): Promise<ScenarioStore> {
  mkdirSync(dataDir, { recursive: true });
  const jsonPath = path.join(dataDir, "data.json");
  const sqlitePath = path.join(dataDir, "data.sqlite");
  if (!existsSync(jsonPath)) {
    try {
      const sqlite = (await import("node:sqlite")) as {
        DatabaseSync: new (p: string) => SqliteDatabase;
      };
      return new SqliteStore(new sqlite.DatabaseSync(sqlitePath), sqlitePath);
    } catch {
      // Node < 22.13: no built-in sqlite — fall through to the JSON store.
    }
  }
  return new JsonFileStore(jsonPath);
}
